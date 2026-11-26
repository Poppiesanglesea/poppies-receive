-- STATUS: STAGED FOR REVIEW. NOT APPLIED. (revision 2, 26 Nov 2026 — addresses review of 656e9db)
-- Owner-approved policy (26 Nov 2026): a new invoice calculates a PROPOSED selling price and creates a shelf-tag job;
-- the register (Square) price changes only when staff confirm "Tag changed — update register". Cost and stock
-- booking are unaffected (they happen in invoice ingestion, which this file does not touch).
--
-- Design
--  * One serialisation point per item: price_item_lock(item) (transaction advisory lock) is taken FIRST by every path
--    that proposes, decides, keeps, confirms or resolves a price for that item, before any task/proposal/operation row
--    is locked. Batch paths visit items in stock_item_id order. The confirm "apply" step holds the item lock across its
--    Square calls, so no proposal for that item can interleave with a register write.
--  * Chronology + replay: every proposal carries a basis (invoice date, processed-invoice id; nightly rules = today, 0).
--    A proposal whose basis is older than the item's latest live/applied/kept decision is recorded 'skipped' and creates
--    no job. A second run for the same (item, source) is a replay: no new proposal, job or operation.
--  * Supersede: a newer proposal — authorised OR pending (over the owner ceiling) — supersedes the item's authorised and
--    pending proposals, their open tag/hold jobs and their not-yet-attempted operations. Owner Keep withdraws any older
--    authorised tag change for the item too. Operations that may already have reached Square ('applying'/'ambiguous')
--    are never discarded; they stay as in-doubt evidence and are settled from what Square shows on the next attempt.
--  * Operation identity is persisted BEFORE any external write: price_propose creates one price_apply_op per variation
--    (main + each half/quarter) in the same transaction as the proposal. Its Square idempotency key is
--    'poppies-op-<op id>-g<generation>'; the generation only increases after a definite rejection, so a retry after a
--    timeout, crash or rollback reuses the same key and Square cannot apply it twice.
--  * Two-phase confirm (Edge calls them as two RPCs = two transactions):
--      delivery_tag_claim  — lock item, check the job/proposal are current, claim the unresolved operations, write a
--                            'claimed' audit row per operation with its key. Commits before any Square call.
--      delivery_tag_apply  — lock item, re-check the claim + proposal, then per operation: read Square; already at the
--                            new price -> done; at the frozen expected price -> versioned write with the persisted key,
--                            read back; anything else -> conflict for Josh. Main first; halves/quarters only after the
--                            main price is in the register. Each operation's Square I/O is isolated so an error after a
--                            write is recorded as 'ambiguous' (retry reconciles by reading), not lost.
--    If the apply transaction is lost after Square accepted a write, the claim and its audit row survive; after the
--    2-minute claim window the next confirm reads Square, sees the new price and completes without writing again.
--  * Halves/quarters: frozen on the proposal with their RECORDED current price as the expected 'from'. A part with no
--    recorded price is 'blocked' and never written until Josh confirms the current register price (price_op_resolve).
--  * Job result: done only when the main price and every half/quarter are applied (or skipped by Josh). Otherwise the
--    job stays open: 'partial' (main applied; some halves/quarters need a retry or Josh), 'failed' (retry), 'conflict'
--    (Josh). Proposal becomes 'applied' only when the job is done.
--  * Transition: existing tag jobs become 'tag_only' (never write). When a newer AUTHORISED proposal is created for an
--    item, its older open tag-only reminders are superseded so staff are not told to put an old label back. (A newer
--    PENDING proposal leaves them: the register still shows that price until Josh decides.)
--  * Staff never see Square ids: the list gives each half/quarter's name, unit, old and new price and its state.
--  * Test isolation: price_square_get/put call pg_temp.square_mock_get/put when the session defines them (the test
--    harness does); otherwise they call Square through square_api.
--
-- EXACT INTENDED MUTATIONS
--   function_backup: +6 rows (label 'pre-tag-confirm-2026-11-26').
--   retail_price_proposal: status check gains 'authorised'; ADD columns source, authorised_by, authorised_at, parts,
--     basis_date, basis_seq; partial unique index (one 'authorised' per item); index (stock_item_id, source). No row changes.
--   delivery_tasks: status check gains 'superseded'; ADD columns price_mode, proposal_id, apply_state, claim_token,
--     claimed_at, attempts, apply_result; UPDATE price_mode = 'tag_only' on all existing kind='tag' rows.
--   CREATE tables price_apply_op, price_apply_audit (RLS on, service_role only).
--   REPLACE functions: produce_price_items, delivery_price_decide, price_rules_scan, price_proposal_apply,
--     delivery_task_tick (wrapper), delivery_tasks_list (adds price fields + named half/quarter rows).
--   CREATE functions: price_item_lock, price_op_key, price_square_get, price_square_put, price_propose, price_op_run,
--     price_task_settle, delivery_tag_claim, delivery_tag_apply, delivery_tag_confirm, price_op_resolve.
--   No Square writes, no price changes and no stock changes happen when this file is applied.
-- Apply as ONE transaction. Rollback: db/rollback/20261126_pricing_03_tag_confirm_rollback.sql (keeps audit evidence).

-- 0) rollback point
insert into public.function_backup (label, fn_name, signature, definition)
select 'pre-tag-confirm-2026-11-26', p.proname, p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
   and p.proname in ('produce_price_items','delivery_price_decide','price_rules_scan','price_proposal_apply',
                     'delivery_task_tick','delivery_tasks_list');

-- 1) schema
alter table public.retail_price_proposal drop constraint if exists retail_price_proposal_status_check;
alter table public.retail_price_proposal add constraint retail_price_proposal_status_check
  check (status = any (array['pending','approved','authorised','rejected','applied','skipped','superseded']));
alter table public.retail_price_proposal
  add column if not exists source text,
  add column if not exists authorised_by text,
  add column if not exists authorised_at timestamptz,
  add column if not exists parts jsonb not null default '[]'::jsonb,
  add column if not exists basis_date date,
  add column if not exists basis_seq bigint not null default 0;
create unique index if not exists retail_price_proposal_authorised_uniq
  on public.retail_price_proposal (stock_item_id) where status = 'authorised';
create index if not exists retail_price_proposal_item_source_idx on public.retail_price_proposal (stock_item_id, source);

alter table public.delivery_tasks drop constraint if exists delivery_tasks_status_check;
alter table public.delivery_tasks add constraint delivery_tasks_status_check
  check (status = any (array['open','done','approved','kept','escalated','closed','superseded']));
alter table public.delivery_tasks
  add column if not exists price_mode text check (price_mode in ('tag_only','apply_on_confirm')),
  add column if not exists proposal_id bigint references public.retail_price_proposal(id),
  add column if not exists apply_state text check (apply_state in ('ready','applying','applied','partial','failed','conflict','superseded','kept')),
  add column if not exists claim_token uuid,
  add column if not exists claimed_at timestamptz,
  add column if not exists attempts integer not null default 0,
  add column if not exists apply_result jsonb;
update public.delivery_tasks set price_mode = 'tag_only' where kind = 'tag' and price_mode is null;

create table if not exists public.price_apply_op (
  id bigserial primary key,
  proposal_id bigint not null references public.retail_price_proposal(id),
  task_id bigint references public.delivery_tasks(id),
  stock_item_id bigint not null,
  square_variation_id text not null,
  role text not null check (role in ('main', 'part')),
  label jsonb not null default '{}'::jsonb,          -- staff-facing name/unit only
  expected_cents integer,                            -- frozen price the register must show before we write
  expect_unpriced boolean not null default false,    -- main only: the variation is expected to have no price
  target_cents integer not null,
  gen integer not null default 0,                    -- idempotency generation; +1 only after a definite rejection
  state text not null default 'ready'
    check (state in ('ready','blocked','applying','applied','ambiguous','failed','conflict','skipped','superseded')),
  claim_token uuid,
  claimed_at timestamptz,
  attempts integer not null default 0,
  last_result jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (proposal_id, square_variation_id),
  check (state = 'blocked' or expected_cents is not null or expect_unpriced)
);
create index if not exists price_apply_op_task_idx on public.price_apply_op (task_id);
create index if not exists price_apply_op_var_idx on public.price_apply_op (square_variation_id) where state in ('applying', 'ambiguous');
alter table public.price_apply_op enable row level security;
revoke all on public.price_apply_op from public, anon, authenticated;
grant select on public.price_apply_op to service_role;

create table if not exists public.price_apply_audit (
  id bigserial primary key,
  task_id bigint references public.delivery_tasks(id),
  proposal_id bigint references public.retail_price_proposal(id),
  op_id bigint references public.price_apply_op(id),
  idem_key text,
  source_id text,
  stock_item_id bigint,
  square_variation_id text,
  expected_old numeric,
  new_price numeric,
  square_before jsonb,
  square_after jsonb,
  outcome text not null,
  by text,
  at timestamptz not null default now()
);
alter table public.price_apply_audit enable row level security;
revoke all on public.price_apply_audit from public, anon, authenticated;
grant select on public.price_apply_audit to service_role;

-- 2) helpers
create or replace function public.price_item_lock(p_stock_item_id bigint)
returns void language sql set search_path to 'public' as $$
  select pg_advisory_xact_lock(726101, (p_stock_item_id % 2147483647)::int) $$;

create or replace function public.price_op_key(p_op_id bigint, p_gen integer)
returns text language sql immutable as $$ select 'poppies-op-' || p_op_id || '-g' || p_gen $$;

-- 3) Square I/O
create or replace function public.price_square_get(p_var text)
returns jsonb language plpgsql set search_path to 'public', 'extensions', 'pg_temp' as $$
declare r jsonb;
begin
  if to_regprocedure('pg_temp.square_mock_get(text)') is not null then
    execute 'select pg_temp.square_mock_get($1)' into r using p_var;
    return r;
  end if;
  r := square_api('GET', '/v2/catalog/object/' || p_var || '?include_related_objects=false', null);
  if coalesce((r->>'status')::int, 0) <> 200 then return jsonb_build_object('ok', false, 'error', 'GET ' || coalesce(r->>'status', 'no response')); end if;
  return jsonb_build_object('ok', true,
    'cents', (r->'body'->'object'->'item_variation_data'->'price_money'->>'amount')::int,
    'version', (r->'body'->'object'->>'version')::bigint,
    'object', r->'body'->'object');
end $$;

-- Writes p_cents only if the variation is still at p_version (Square rejects a stale version). p_idem is the persisted
-- operation key. Returns {ok} | {ok:false, conflict} | {ok:false, ambiguous} | {ok:false} (definite rejection).
create or replace function public.price_square_put(p_var text, p_version bigint, p_cents int, p_idem text)
returns jsonb language plpgsql set search_path to 'public', 'extensions', 'pg_temp' as $$
declare g jsonb; obj jsonb; r jsonb; v_status int;
begin
  if to_regprocedure('pg_temp.square_mock_put(text,bigint,integer,text)') is not null then
    execute 'select pg_temp.square_mock_put($1, $2, $3, $4)' into r using p_var, p_version, p_cents, p_idem;
    return r;
  end if;
  g := square_api('GET', '/v2/catalog/object/' || p_var || '?include_related_objects=false', null);
  if coalesce((g->>'status')::int, 0) <> 200 then return jsonb_build_object('ok', false, 'error', 'GET ' || coalesce(g->>'status', 'no response')); end if;
  obj := g->'body'->'object';
  if (obj->>'version')::bigint <> p_version then return jsonb_build_object('ok', false, 'conflict', true, 'error', 'version changed'); end if;
  obj := jsonb_set(obj, '{item_variation_data,price_money}', jsonb_build_object('amount', p_cents, 'currency', 'AUD'));
  r := square_api('POST', '/v2/catalog/object', jsonb_build_object('idempotency_key', p_idem, 'object', obj));
  v_status := coalesce((r->>'status')::int, 0);
  if v_status = 200 then return jsonb_build_object('ok', true, 'version', (r->'body'->'catalog_object'->>'version')::bigint); end if;
  return jsonb_build_object('ok', false, 'conflict', coalesce(r::text ~* 'VERSION_MISMATCH', false),
                            'ambiguous', v_status = 0 or v_status >= 500 or v_status = 429,
                            'error', 'POST ' || coalesce(r->>'status', 'no response'), 'body', r->'body');
end $$;

-- 4) proposals. p: item, variation, old, new, mode ('authorised'|'pending'), source (replay identity), task_source
--    (delivery card; default source), basis_date, basis_seq, lane, method, old_cost, new_cost, cost_pct, price_pct,
--    cogs_after, below_floor, supplier, invoice_number, invoice_date, department, authorised_by, label.
create or replace function public.price_propose(p jsonb)
returns jsonb language plpgsql set search_path to 'public', 'extensions', 'pg_temp' as $$
declare
  v_item bigint := (p->>'item')::bigint; v_var text := p->>'variation'; v_mode text := coalesce(p->>'mode', 'authorised');
  v_src text := p->>'source'; v_tsrc text := coalesce(p->>'task_source', p->>'source');
  v_bd date := coalesce((p->>'basis_date')::date, current_date); v_bs bigint := coalesce((p->>'basis_seq')::bigint, 0);
  v_old numeric := round((p->>'old')::numeric, 2); v_new numeric := round((p->>'new')::numeric, 2);
  v_prior record; v_ids bigint[]; v_prop bigint; v_task bigint; x jsonb; v_parts jsonb := '[]'::jsonb; v_lbl jsonb;
begin
  if v_item is null or v_src is null or v_new is null or v_new <= 0 then raise exception 'price_propose: item, source and a positive new price are required'; end if;
  if v_mode not in ('authorised', 'pending') then raise exception 'price_propose: unknown mode %', v_mode; end if;
  if v_mode = 'authorised' and coalesce(v_var, '') !~ '^[A-Z0-9]{20,}$' then raise exception 'price_propose: a real Square variation id is required'; end if;
  perform price_item_lock(v_item);

  -- replay: this source already decided this item
  select q.id, q.status into v_prior from retail_price_proposal q where q.stock_item_id = v_item and q.source = v_src order by q.id desc limit 1;
  if found then
    return jsonb_build_object('outcome', 'replay', 'proposal', v_prior.id, 'status', v_prior.status,
      'task', (select t.id from delivery_tasks t where t.proposal_id = v_prior.id order by t.id desc limit 1),
      'task_open', exists (select 1 from delivery_tasks t where t.proposal_id = v_prior.id and t.status = 'open'));
  end if;

  -- chronology: an older basis never replaces a newer decision (live, applied or kept)
  if exists (select 1 from retail_price_proposal q where q.stock_item_id = v_item and q.basis_date is not null
               and q.status in ('authorised', 'pending', 'applied', 'rejected') and (q.basis_date, q.basis_seq) > (v_bd, v_bs)) then
    insert into retail_price_proposal (stock_item_id, lane, method, old_cost, new_cost, cost_pct, old_price, proposed_price, price_pct,
                                       cogs_pct_after, below_floor, status, skip_reason, source, basis_date, basis_seq)
    values (v_item, coalesce(p->>'lane', 'auto'), coalesce(p->>'method', 'band'), (p->>'old_cost')::numeric, (p->>'new_cost')::numeric,
            (p->>'cost_pct')::numeric, v_old, v_new, (p->>'price_pct')::numeric, (p->>'cogs_after')::numeric, coalesce((p->>'below_floor')::boolean, false),
            'skipped', 'older than the current price decision for this item', v_src, v_bd, v_bs)
    returning id into v_prop;
    return jsonb_build_object('outcome', 'stale', 'proposal', v_prop);
  end if;

  -- supersede the item's live proposals, their open jobs and their not-yet-attempted operations
  with s as (update retail_price_proposal set status = 'superseded', decided_at = now(), decided_by = left('superseded by ' || v_src, 120)
              where stock_item_id = v_item and status in ('authorised', 'pending') returning id)
  select coalesce(array_agg(id), '{}') into v_ids from s;
  update price_apply_op set state = 'superseded', claim_token = null, updated_at = now()
   where proposal_id = any (v_ids) and state in ('ready', 'blocked', 'failed', 'conflict');
  -- (a claim token is left in place so an apply already claimed can record that it stopped before writing)
  update delivery_tasks set status = 'superseded', apply_state = case when price_mode = 'apply_on_confirm' then 'superseded' else apply_state end,
         done_by = 'system', done_at = now(), answer = coalesce(answer, '{}'::jsonb) || jsonb_build_object('superseded_by', v_src)
   where status = 'open' and (proposal_id = any (v_ids) or (kind = 'hold' and stock_item_id = v_item));

  if v_mode = 'pending' then
    insert into retail_price_proposal (stock_item_id, lane, method, old_cost, new_cost, cost_pct, old_price, proposed_price, price_pct,
                                       cogs_pct_after, below_floor, status, source, basis_date, basis_seq)
    values (v_item, coalesce(p->>'lane', 'approve'), coalesce(p->>'method', 'band'), (p->>'old_cost')::numeric, (p->>'new_cost')::numeric,
            (p->>'cost_pct')::numeric, v_old, v_new, (p->>'price_pct')::numeric, (p->>'cogs_after')::numeric, coalesce((p->>'below_floor')::boolean, false),
            'pending', v_src, v_bd, v_bs)
    returning id into v_prop;
    return jsonb_build_object('outcome', 'pending', 'proposal', v_prop, 'superseded', to_jsonb(v_ids));
  end if;

  -- transition: an older open tag-only reminder for this item would tell staff to put a superseded label back up.
  -- Close it (no register write ever happens from tag-only jobs); the new job carries the current tag.
  update delivery_tasks set status = 'superseded', done_by = 'system', done_at = now(),
         answer = coalesce(answer, '{}'::jsonb) || jsonb_build_object('superseded_by', v_src)
   where status = 'open' and kind = 'tag' and stock_item_id = v_item and coalesce(price_mode, 'tag_only') = 'tag_only';

  -- freeze halves/quarters now: recorded current price ('from', null = never recorded) and new price, with staff labels
  for x in select * from jsonb_array_elements(coalesce(sync_part_variation_prices(v_item, true), '[]'::jsonb)) loop
    v_lbl := produce_price_label(v_item, x->>'variation');
    v_parts := v_parts || jsonb_build_object('variation', x->>'variation', 'from', (x->>'from')::numeric, 'to', (x->>'to')::numeric,
                                             'name', v_lbl->>'name', 'per', v_lbl->>'per');
  end loop;

  insert into retail_price_proposal (stock_item_id, lane, method, old_cost, new_cost, cost_pct, old_price, proposed_price, price_pct, cogs_pct_after,
                                     below_floor, status, source, authorised_by, authorised_at, parts, basis_date, basis_seq)
  values (v_item, coalesce(p->>'lane', 'auto'), coalesce(p->>'method', 'band'), (p->>'old_cost')::numeric, (p->>'new_cost')::numeric,
          (p->>'cost_pct')::numeric, v_old, v_new, (p->>'price_pct')::numeric, (p->>'cogs_after')::numeric, coalesce((p->>'below_floor')::boolean, false),
          'authorised', v_src, left(coalesce(p->>'authorised_by', 'auto'), 120), now(), v_parts, v_bd, v_bs)
  returning id into v_prop;

  insert into delivery_tasks (source_id, supplier, invoice_number, invoice_date, department, kind, stock_item_id, square_variation_id, info,
                              price_mode, proposal_id, apply_state)
  values (v_tsrc, p->>'supplier', p->>'invoice_number', (p->>'invoice_date')::date, coalesce(p->>'department', 'Grocer'), 'tag', v_item, v_var,
          coalesce(p->'label', '{}'::jsonb) || jsonb_build_object('old', v_old, 'new', v_new), 'apply_on_confirm', v_prop, 'ready')
  on conflict (source_id, kind, coalesce(stock_item_id, 0), coalesce(unmatched_id, 0)) do update
     set info = excluded.info, price_mode = 'apply_on_confirm', proposal_id = excluded.proposal_id, apply_state = 'ready', status = 'open',
         done_by = null, done_at = null, claim_token = null, claimed_at = null, apply_result = null, attempts = 0
   where delivery_tasks.status in ('superseded', 'closed')
      or (delivery_tasks.status = 'open' and delivery_tasks.price_mode is distinct from 'apply_on_confirm')
  returning id into v_task;
  if v_task is null then raise exception 'price_propose: the shelf-tag job for item % on % is already completed', v_item, v_tsrc; end if;

  insert into price_apply_op (proposal_id, task_id, stock_item_id, square_variation_id, role, label, expected_cents, expect_unpriced, target_cents, state)
  values (v_prop, v_task, v_item, v_var, 'main', jsonb_build_object('name', p->'label'->>'name', 'per', p->'label'->>'per'),
          round(v_old * 100)::int, v_old is null, round(v_new * 100)::int, 'ready');
  insert into price_apply_op (proposal_id, task_id, stock_item_id, square_variation_id, role, label, expected_cents, target_cents, state)
  select v_prop, v_task, v_item, e->>'variation', 'part', jsonb_build_object('name', e->>'name', 'per', e->>'per'),
         round((e->>'from')::numeric * 100)::int, round((e->>'to')::numeric * 100)::int,
         case when e->>'from' is null then 'blocked' else 'ready' end
    from jsonb_array_elements(v_parts) e;

  return jsonb_build_object('outcome', 'authorised', 'proposal', v_prop, 'task', v_task, 'superseded', to_jsonb(v_ids));
end $$;

-- 5) one operation's Square I/O. Caller holds the item lock and has claimed the operation.
create or replace function public.price_op_run(p_op_id bigint, p_by text)
returns jsonb language plpgsql set search_path to 'public', 'extensions', 'pg_temp' as $$
declare
  o price_apply_op%rowtype; t record; g jsonb; w jsonb; a jsonb; d record;
  v_cur int; v_state text; v_outcome text; v_res jsonb := '{}'::jsonb; v_gen int; v_key text; v_late boolean := false;
begin
  select * into o from price_apply_op where id = p_op_id for update;
  select id, source_id, invoice_number into t from delivery_tasks where id = o.task_id;
  v_gen := o.gen; v_key := price_op_key(o.id, o.gen);
  begin
    g := price_square_get(o.square_variation_id);
    if not coalesce((g->>'ok')::boolean, false) then
      v_state := 'failed'; v_outcome := 'failed_read'; v_res := jsonb_build_object('stage', 'read', 'error', g->>'error');
    else
      v_cur := (g->>'cents')::int;
      -- settle older in-doubt operations on this variation (other proposals) from what Square shows now
      for d in select * from price_apply_op x
                where x.square_variation_id = o.square_variation_id and x.proposal_id <> o.proposal_id
                  and (x.state = 'ambiguous' or (x.state = 'applying' and x.claimed_at < now() - interval '2 minutes'))
                for update loop
        if v_cur is not distinct from d.target_cents then
          update price_apply_op set state = 'applied', claim_token = null, updated_at = now(),
                 last_result = coalesce(last_result, '{}') || jsonb_build_object('reconciled_by_op', o.id) where id = d.id;
          insert into price_apply_audit (task_id, proposal_id, op_id, idem_key, stock_item_id, square_variation_id, expected_old, new_price, square_before, outcome, by)
          values (d.task_id, d.proposal_id, d.id, price_op_key(d.id, d.gen), d.stock_item_id, d.square_variation_id, d.expected_cents / 100.0, d.target_cents / 100.0,
                  g - 'object', 'reconciled_applied', p_by);
          v_late := true;
        elsif v_cur is not distinct from d.expected_cents then
          update price_apply_op set state = 'superseded', claim_token = null, updated_at = now(),
                 last_result = coalesce(last_result, '{}') || jsonb_build_object('reconciled_not_applied_by_op', o.id) where id = d.id;
          insert into price_apply_audit (task_id, proposal_id, op_id, idem_key, stock_item_id, square_variation_id, expected_old, new_price, square_before, outcome, by)
          values (d.task_id, d.proposal_id, d.id, price_op_key(d.id, d.gen), d.stock_item_id, d.square_variation_id, d.expected_cents / 100.0, d.target_cents / 100.0,
                  g - 'object', 'reconciled_not_applied', p_by);
        end if;
      end loop;

      if v_cur is not distinct from o.target_cents then
        v_state := 'applied'; v_outcome := 'applied_already';
      elsif not (v_cur is not distinct from o.expected_cents or (o.expect_unpriced and v_cur is null) or v_late) then
        v_state := 'conflict'; v_outcome := 'conflict';
        v_res := jsonb_build_object('stage', 'compare', 'square_cents', v_cur, 'expected_cents', o.expected_cents);
      else
        w := price_square_put(o.square_variation_id, (g->>'version')::bigint, o.target_cents, v_key);
        if coalesce((w->>'ok')::boolean, false) then
          a := price_square_get(o.square_variation_id);
          if not coalesce((a->>'ok')::boolean, false) then v_state := 'ambiguous'; v_outcome := 'unconfirmed_readback';
          elsif (a->>'cents')::int is not distinct from o.target_cents then v_state := 'applied'; v_outcome := 'applied';
          else v_state := 'conflict'; v_outcome := 'conflict_after_write'; end if;
        elsif coalesce((w->>'conflict')::boolean, false) then
          v_state := 'conflict'; v_outcome := 'conflict';
        elsif coalesce((w->>'ambiguous')::boolean, false) then
          v_state := 'ambiguous'; v_outcome := 'ambiguous_write';
        else
          v_state := 'failed'; v_outcome := 'failed_write'; v_gen := o.gen + 1;   -- definite rejection: next attempt is a new operation
        end if;
        v_res := jsonb_build_object('stage', 'write', 'error', w->>'error');
      end if;
    end if;
  exception when others then
    -- anything after the read may have reached Square: keep the key and settle by reading next time
    v_state := 'ambiguous'; v_outcome := 'error'; v_res := jsonb_build_object('stage', 'error', 'error', left(sqlerrm, 300));
  end;

  update price_apply_op set state = v_state, gen = v_gen, claim_token = null, updated_at = now(),
         last_result = v_res || jsonb_build_object('outcome', v_outcome, 'square_cents', v_cur)
   where id = o.id;
  if v_state = 'applied' then
    if o.role = 'main' then
      perform set_config('poppies.price_source', left('tag:' || coalesce(t.invoice_number, t.source_id, '') || ' by ' || p_by, 120), true);
      update stock_items set retail_sell_price = round(o.target_cents / 100.0, 2) where id = o.stock_item_id;
      update retail_price_history set pushed_to_square_at = now(), shelf_label_updated_at = now()
       where id = (select max(id) from retail_price_history where stock_item_id = o.stock_item_id);
    else
      insert into retail_part_variation_price (square_variation_id, stock_item_id, price, updated_at, last_push)
      values (o.square_variation_id, o.stock_item_id, round(o.target_cents / 100.0, 2), now(), jsonb_build_object('op', o.id, 'outcome', v_outcome))
      on conflict (square_variation_id) do update set price = excluded.price, updated_at = now(), last_push = excluded.last_push;
    end if;
  end if;
  insert into price_apply_audit (task_id, proposal_id, op_id, idem_key, source_id, stock_item_id, square_variation_id, expected_old, new_price,
                                 square_before, square_after, outcome, by)
  values (o.task_id, o.proposal_id, o.id, v_key, t.source_id, o.stock_item_id, o.square_variation_id, o.expected_cents / 100.0, o.target_cents / 100.0,
          g - 'object', coalesce(a - 'object', w - 'body'), v_outcome, p_by);
  return jsonb_build_object('op', o.id, 'role', o.role, 'state', v_state, 'outcome', v_outcome);
end $$;

-- 6) job state from its operations
create or replace function public.price_task_settle(p_task_id bigint, p_by text)
returns jsonb language plpgsql set search_path to 'public', 'pg_temp' as $$
declare t delivery_tasks%rowtype; v_main text; v_done boolean; v_josh boolean; v_retry boolean; v_sum jsonb;
begin
  select * into t from delivery_tasks where id = p_task_id;
  select state into v_main from price_apply_op where task_id = t.id and role = 'main';
  select coalesce(bool_and(state in ('applied', 'skipped')), true), coalesce(bool_or(state in ('conflict', 'blocked')), false),
         coalesce(bool_or(state in ('failed', 'ambiguous', 'ready')), false)
    into v_done, v_josh, v_retry from price_apply_op where task_id = t.id and role = 'part';
  select jsonb_build_object('ops', coalesce(jsonb_agg(jsonb_build_object('role', role, 'name', label->>'name', 'state', state) order by role, id), '[]'))
    into v_sum from price_apply_op where task_id = t.id;

  if t.status <> 'open' then
    return jsonb_build_object('ok', t.status = 'done', 'status', t.status, 'register', case when t.status = 'done' then 'updated' end);
  end if;
  if v_main = 'applied' and v_done then
    update retail_price_proposal set status = 'applied', applied_at = now(), square_result = v_sum where id = t.proposal_id and status = 'authorised';
    update delivery_tasks set status = 'done', apply_state = 'applied', claim_token = null, done_by = p_by, done_at = now(), apply_result = v_sum where id = t.id;
    return jsonb_build_object('ok', true, 'status', 'done', 'register', 'updated');
  elsif v_main = 'applied' then
    update delivery_tasks set apply_state = 'partial', claim_token = null, apply_result = v_sum || jsonb_build_object('needs_josh', v_josh, 'can_retry', v_retry) where id = t.id;
    return jsonb_build_object('ok', false, 'status', 'partial', 'register', 'partly updated', 'needs_josh', v_josh, 'can_retry', v_retry,
      'error', case when v_retry then 'The main price is in the register, but a half/quarter price didn''t go through. Try again.'
                    else 'The main price is in the register. Josh needs to check a half/quarter price.' end);
  elsif v_main = 'conflict' then
    update delivery_tasks set apply_state = 'conflict', claim_token = null, apply_result = v_sum where id = t.id;
    return jsonb_build_object('ok', false, 'status', 'conflict', 'error', 'The register price was changed elsewhere. Josh needs to check this one.');
  elsif v_main in ('failed', 'ambiguous') then
    update delivery_tasks set apply_state = 'failed', claim_token = null, apply_result = v_sum where id = t.id;
    return jsonb_build_object('ok', false, 'status', 'failed', 'error', 'The register didn''t take the new price. Try again.');
  elsif v_main = 'applying' then
    return jsonb_build_object('ok', false, 'status', 'busy', 'error', 'Already being updated. Wait a moment, then check again.');
  end if;
  update delivery_tasks set apply_state = 'ready', claim_token = null where id = t.id;
  return jsonb_build_object('ok', false, 'status', 'ready', 'error', 'Nothing was changed. Try again.');
end $$;

-- 7) staff confirmation, phase 1: claim (commits before any Square call)
create or replace function public.delivery_tag_claim(p_task_id bigint, p_by text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp' as $$
declare
  v_item bigint; v_kind text; v_mode text; t delivery_tasks%rowtype; q retail_price_proposal%rowtype;
  v_token uuid := gen_random_uuid(); v_by text := left(btrim(coalesce(p_by, '')), 40); v_main text; v_n int;
begin
  select stock_item_id, kind, coalesce(price_mode, 'tag_only') into v_item, v_kind, v_mode from delivery_tasks where id = p_task_id;
  if not found or v_kind <> 'tag' then return jsonb_build_object('ok', false, 'error', 'Not a shelf-tag job.'); end if;
  if v_mode = 'tag_only' then   -- legacy / tag-only: no register write, ever
    update delivery_tasks set status = 'done', done_by = v_by, done_at = now() where id = p_task_id and status = 'open';
    if not found and exists (select 1 from delivery_tasks where id = p_task_id and status = 'superseded') then
      return jsonb_build_object('ok', false, 'status', 'superseded', 'error', 'A newer price replaced this tag. Use the newer tag job.');
    end if;
    return jsonb_build_object('ok', true, 'status', 'done', 'register', 'unchanged');
  end if;

  perform price_item_lock(v_item);
  select * into t from delivery_tasks where id = p_task_id for update;
  if t.status = 'superseded' or t.apply_state = 'superseded' then
    return jsonb_build_object('ok', false, 'status', 'superseded', 'error', 'A newer price replaced this one. Use the newer tag job.');
  end if;
  if t.status = 'done' then return jsonb_build_object('ok', true, 'status', 'done', 'register', 'updated', 'already', true); end if;
  if t.status <> 'open' then return jsonb_build_object('ok', false, 'status', t.status, 'error', 'This job is closed.'); end if;
  if t.apply_state = 'applying' and t.claimed_at > now() - interval '2 minutes' then
    return jsonb_build_object('ok', false, 'status', 'busy', 'error', 'Already being updated. Wait a moment, then check again.');
  end if;
  select * into q from retail_price_proposal where id = t.proposal_id;
  if not found or q.status <> 'authorised' then
    update price_apply_op set state = 'superseded', updated_at = now() where task_id = t.id and state in ('ready', 'blocked', 'failed', 'conflict');
    update delivery_tasks set status = 'superseded', apply_state = 'superseded', done_by = 'system', done_at = now() where id = t.id;
    return jsonb_build_object('ok', false, 'status', 'superseded', 'error', 'This price is no longer current. Use the newer tag job.');
  end if;
  select state into v_main from price_apply_op where task_id = t.id and role = 'main';
  if v_main in ('conflict', 'blocked') then
    return price_task_settle(t.id, v_by);
  end if;

  with c as (
    update price_apply_op set state = 'applying', claim_token = v_token, claimed_at = now(), attempts = attempts + 1, updated_at = now()
     where task_id = t.id and (state in ('ready', 'failed', 'ambiguous') or (state = 'applying' and claimed_at < now() - interval '2 minutes'))
    returning *)
  insert into price_apply_audit (task_id, proposal_id, op_id, idem_key, source_id, stock_item_id, square_variation_id, expected_old, new_price, outcome, by)
  select t.id, q.id, c.id, price_op_key(c.id, c.gen), t.source_id, c.stock_item_id, c.square_variation_id, c.expected_cents / 100.0, c.target_cents / 100.0, 'claimed', v_by
    from c;
  get diagnostics v_n = row_count;
  if v_n = 0 then return price_task_settle(t.id, v_by); end if;
  update delivery_tasks set apply_state = 'applying', claim_token = v_token, claimed_at = now(), attempts = attempts + 1 where id = t.id;
  return jsonb_build_object('ok', true, 'phase', 'apply', 'token', v_token, 'claimed', v_n);
end $$;

-- 8) staff confirmation, phase 2: Square writes for the claimed operations
create or replace function public.delivery_tag_apply(p_task_id bigint, p_token uuid, p_by text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp' as $$
declare
  v_item bigint; t delivery_tasks%rowtype; q retail_price_proposal%rowtype; o record; v_ops jsonb := '[]'::jsonb;
  v_by text := left(btrim(coalesce(p_by, '')), 40);
begin
  select stock_item_id into v_item from delivery_tasks where id = p_task_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'Not a shelf-tag job.'); end if;
  perform price_item_lock(v_item);
  select * into t from delivery_tasks where id = p_task_id for update;
  if p_token is null or t.claim_token is distinct from p_token then
    return jsonb_build_object('ok', false, 'status', 'busy', 'error', 'Another attempt took over. Check again in a moment.');
  end if;
  select * into q from retail_price_proposal where id = t.proposal_id;
  if not found or q.status <> 'authorised' or t.status <> 'open' then   -- a newer price arrived after the claim: nothing has been written for this claim
    insert into price_apply_audit (task_id, proposal_id, op_id, idem_key, source_id, stock_item_id, square_variation_id, expected_old, new_price, outcome, by)
    select t.id, o2.proposal_id, o2.id, price_op_key(o2.id, o2.gen), t.source_id, o2.stock_item_id, o2.square_variation_id,
           o2.expected_cents / 100.0, o2.target_cents / 100.0, 'superseded_before_write', v_by
      from price_apply_op o2 where o2.task_id = t.id and o2.claim_token = p_token and o2.state = 'applying';
    update price_apply_op set state = 'superseded', claim_token = null, updated_at = now() where task_id = t.id and claim_token = p_token and state = 'applying';
    update delivery_tasks set status = case when status = 'open' then 'superseded' else status end, apply_state = 'superseded', claim_token = null,
           done_by = coalesce(done_by, 'system'), done_at = coalesce(done_at, now()) where id = t.id;
    return jsonb_build_object('ok', false, 'status', 'superseded', 'error', 'A newer price replaced this one. Use the newer tag job.');
  end if;
  if t.apply_state is distinct from 'applying' then
    return jsonb_build_object('ok', false, 'status', 'busy', 'error', 'Another attempt took over. Check again in a moment.');
  end if;

  for o in select id, role from price_apply_op where task_id = t.id and claim_token = p_token and state = 'applying' order by (role <> 'main'), id loop
    if o.role = 'part' and not exists (select 1 from price_apply_op where task_id = t.id and role = 'main' and state = 'applied') then
      update price_apply_op set state = 'ready', claim_token = null, updated_at = now() where id = o.id;   -- not attempted
      continue;
    end if;
    v_ops := v_ops || price_op_run(o.id, v_by);
  end loop;
  return price_task_settle(t.id, v_by) || jsonb_build_object('ops', v_ops);
end $$;

-- Single-call form (one transaction). The Edge function uses claim + apply as two calls; this remains for the legacy
-- route and for tests. In this form a lost transaction also loses the claim row, but the persisted operation key and
-- the read-before-write still prevent a second Square write on retry.
create or replace function public.delivery_tag_confirm(p_task_id bigint, p_by text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp' as $$
declare r jsonb;
begin
  r := delivery_tag_claim(p_task_id, p_by);
  if r->>'phase' = 'apply' then return delivery_tag_apply(p_task_id, (r->>'token')::uuid, p_by); end if;
  return r;
end $$;

create or replace function public.delivery_task_tick(p_task_id bigint, p_by text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  return delivery_tag_confirm(p_task_id, p_by);
end $$;

-- 9) Josh resolves a conflicting or blocked operation. 'overwrite' + the price the register shows now (cents) -> the
--    operation becomes retryable against that price (new generation); 'skip' -> leave that register price as it is
--    (for the main price this withdraws the whole tag change: proposal rejected, job kept).
create or replace function public.price_op_resolve(p_op_id bigint, p_action text, p_expected_cents integer DEFAULT NULL, p_by text DEFAULT 'Josh')
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp' as $$
declare v_item bigint; o price_apply_op%rowtype; q retail_price_proposal%rowtype; v_by text := left(btrim(coalesce(p_by, 'Josh')), 40);
begin
  select stock_item_id into v_item from price_apply_op where id = p_op_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'Not found.'); end if;
  perform price_item_lock(v_item);
  select * into o from price_apply_op where id = p_op_id for update;
  select * into q from retail_price_proposal where id = o.proposal_id;
  if o.state not in ('conflict', 'blocked') then return jsonb_build_object('ok', false, 'error', 'Nothing to resolve for this price.'); end if;
  if q.status <> 'authorised' then return jsonb_build_object('ok', false, 'error', 'A newer price replaced this one.'); end if;
  if p_action = 'overwrite' then
    if p_expected_cents is null or p_expected_cents < 0 then return jsonb_build_object('ok', false, 'error', 'Enter the price the register shows now.'); end if;
    update price_apply_op set state = 'ready', expected_cents = p_expected_cents, expect_unpriced = false, gen = gen + 1, updated_at = now(),
           last_result = coalesce(last_result, '{}') || jsonb_build_object('resolved', 'overwrite', 'by', v_by)
     where id = o.id;
  elsif p_action = 'skip' then
    if o.role = 'main' then
      update price_apply_op set state = 'skipped', claim_token = null, updated_at = now()
       where task_id = o.task_id and state in ('ready', 'blocked', 'failed', 'conflict');
      update retail_price_proposal set status = 'rejected', decided_at = now(), decided_by = v_by, skip_reason = 'register price kept at confirm' where id = q.id;
      update delivery_tasks set status = 'kept', apply_state = 'kept', claim_token = null, done_by = v_by, done_at = now() where id = o.task_id;
    else
      update price_apply_op set state = 'skipped', updated_at = now(), last_result = coalesce(last_result, '{}') || jsonb_build_object('resolved', 'skip', 'by', v_by)
       where id = o.id;
    end if;
  else
    return jsonb_build_object('ok', false, 'error', 'Unknown action.');
  end if;
  insert into price_apply_audit (task_id, proposal_id, op_id, idem_key, stock_item_id, square_variation_id, expected_old, new_price, outcome, by)
  values (o.task_id, o.proposal_id, o.id, price_op_key(o.id, o.gen), o.stock_item_id, o.square_variation_id,
          coalesce(p_expected_cents, o.expected_cents) / 100.0, o.target_cents / 100.0, 'owner_' || p_action, v_by);
  return price_task_settle(o.task_id, v_by);
end $$;

-- 10) invoice arrival: propose + tag job (or owner hold) instead of pushing
create or replace function public.produce_price_items(p_source_id text, p_item_ids bigint[], p_dry_run boolean DEFAULT true)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp' as $$
declare
  pi record; r record; v_lbl jsonb; res jsonb; p jsonb;
  v_applied jsonb := '[]'; v_held jsonb := '[]'; v_failed jsonb := '[]'; v_noprice jsonb := '[]'; v_skipped jsonb := '[]';
begin
  select * into pi from processed_invoices where source_id = p_source_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'invoice not booked'); end if;

  for r in
    select c.* from v_price_rule_candidates c
     where c.stock_item_id = any (coalesce(p_item_ids, '{}'))
       and c.retail_category = 'Produce' and c.policy_source = 'retail_category' and c.method = 'band'
       and c.lane <> 'never' and c.skip_reason is null
     order by c.stock_item_id
  loop
    v_lbl := produce_price_label(r.stock_item_id, r.square_variation_id)
             || jsonb_build_object('stock_item_id', r.stock_item_id, 'square_variation_id', r.square_variation_id,
                                   'old', r.old_price, 'new', r.proposed_price, 'pct', r.price_pct);
    if p_dry_run then
      if r.exceeds_max_pct then v_held := v_held || v_lbl; else v_applied := v_applied || v_lbl; end if;
      continue;
    end if;
    p := jsonb_build_object('item', r.stock_item_id, 'variation', r.square_variation_id, 'old', r.old_price, 'new', r.proposed_price,
           'method', r.method, 'old_cost', r.anchor_cost, 'new_cost', r.new_cost, 'cost_pct', r.cost_pct, 'price_pct', r.price_pct,
           'cogs_after', r.cogs_pct_after, 'below_floor', r.below_floor, 'source', p_source_id,
           'basis_date', coalesce(pi.invoice_date, pi.processed_at::date), 'basis_seq', pi.id);
    if r.exceeds_max_pct then
      res := price_propose(p || jsonb_build_object('mode', 'pending', 'lane', 'approve'));
      if res->>'outcome' = 'pending' or (res->>'outcome' = 'replay' and res->>'status' = 'pending') then v_held := v_held || v_lbl;
      else v_skipped := v_skipped || (v_lbl || jsonb_build_object('outcome', res->>'outcome', 'status', res->>'status')); end if;
    elsif r.square_variation_id !~ '^[A-Z0-9]{20,}$' then
      v_failed := v_failed || (v_lbl || jsonb_build_object('error', 'no real Square variation id'));
    else
      res := price_propose(p || jsonb_build_object('mode', 'authorised', 'lane', 'auto', 'label', v_lbl,
               'supplier', canonical_supplier(pi.supplier), 'invoice_number', pi.invoice_number, 'invoice_date', pi.invoice_date,
               'department', canonical_department(pi.department), 'authorised_by', 'auto: invoice ' || coalesce(pi.invoice_number, p_source_id)));
      if res->>'outcome' = 'authorised' or (res->>'outcome' = 'replay' and coalesce((res->>'task_open')::boolean, false)) then
        v_applied := v_applied || v_lbl;   -- "applied" here means: tag job exists; register changes on staff confirm
      else
        v_skipped := v_skipped || (v_lbl || jsonb_build_object('outcome', res->>'outcome', 'status', res->>'status'));
      end if;
    end if;
  end loop;

  select coalesce(jsonb_agg(produce_price_label(c.stock_item_id, c.square_variation_id)
                            || jsonb_build_object('stock_item_id', c.stock_item_id, 'square_variation_id', c.square_variation_id) order by c.name), '[]')
    into v_noprice
    from v_price_rule_candidates c
   where c.stock_item_id = any (coalesce(p_item_ids, '{}')) and c.skip_reason = 'item has no current shelf price';

  return jsonb_build_object('ok', true, 'applied', v_applied, 'held', v_held, 'failed', v_failed, 'no_price', v_noprice, 'skipped', v_skipped);
end $$;

-- 11) owner decisions: approve authorises (register waits for the tag), keep withdraws older tag changes
create or replace function public.delivery_price_decide(p_task_id bigint, p_decision text, p_price numeric DEFAULT NULL::numeric, p_by text DEFAULT 'Josh'::text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp' as $$
declare
  t record; v_item bigint; v_price numeric; v_var text; v_old numeric; v_test boolean; v_lbl jsonb; q record; pi record;
  v_ids bigint[]; res jsonb; v_src text; v_bd date; v_bs bigint; v_qid bigint;
begin
  select stock_item_id into v_item from delivery_tasks where id = p_task_id;
  if v_item is not null then perform price_item_lock(v_item); end if;
  select * into t from delivery_tasks where id = p_task_id for update;
  if not found or t.kind not in ('hold', 'noprice') then return jsonb_build_object('ok', false, 'error', 'Not a price job.'); end if;
  if t.status = 'superseded' then return jsonb_build_object('ok', false, 'error', 'A newer delivery replaced this price.', 'status', t.status); end if;
  if t.status <> 'open' then return jsonb_build_object('ok', false, 'error', 'Already decided.', 'status', t.status); end if;
  v_test := delivery_is_test(t.source_id);

  if p_decision = 'keep' then
    if t.kind <> 'hold' then return jsonb_build_object('ok', false, 'error', 'Enter a price.'); end if;
    if not v_test then
      update retail_price_proposal set status = 'rejected', decided_at = now(), decided_by = p_by,
             skip_reason = left(format('kept via app (%s %s)', t.supplier, coalesce(t.invoice_number, t.source_id)), 200)
       where stock_item_id = t.stock_item_id and status = 'pending';
      -- keep = the register stays as it is: withdraw any older authorised tag change for this item
      with s as (update retail_price_proposal set status = 'superseded', decided_at = now(), decided_by = left('kept by ' || p_by, 120)
                  where stock_item_id = t.stock_item_id and status = 'authorised' returning id)
      select coalesce(array_agg(id), '{}') into v_ids from s;
      update price_apply_op set state = 'superseded', claim_token = null, updated_at = now()
       where proposal_id = any (v_ids) and state in ('ready', 'blocked', 'failed', 'conflict');
      update delivery_tasks set status = 'superseded', apply_state = 'superseded', claim_token = null, done_by = 'system', done_at = now()
       where proposal_id = any (v_ids) and status = 'open';
    end if;
    update delivery_tasks set status = 'kept', done_by = p_by, done_at = now(), answer = jsonb_build_object('decision', 'keep', 'practice', v_test) where id = t.id;
    return jsonb_build_object('ok', true, 'status', 'kept');
  end if;
  if p_decision <> 'approve' then return jsonb_build_object('ok', false, 'error', 'Unknown decision.'); end if;

  v_price := round(coalesce(p_price, (t.info->>'new')::numeric), 2);
  if v_price is null or v_price <= 0 or v_price >= 10000 then return jsonb_build_object('ok', false, 'error', 'Enter a price above 0.'); end if;

  if v_test then
    v_lbl := t.info || jsonb_build_object('old', (t.info->>'old')::numeric, 'new', v_price, 'set_by', p_by);
    insert into delivery_tasks (source_id, supplier, invoice_number, invoice_date, department, kind, stock_item_id, square_variation_id, info, price_mode)
    values (t.source_id, t.supplier, t.invoice_number, t.invoice_date, t.department, 'tag', t.stock_item_id, null, v_lbl, 'tag_only')
    on conflict (source_id, kind, coalesce(stock_item_id, 0), coalesce(unmatched_id, 0)) do update set status = 'open', info = excluded.info, done_by = null, done_at = null;
  else
    v_var := coalesce(t.square_variation_id, (select m.square_variation_id from square_sync_map m where m.stock_item_id = t.stock_item_id limit 1));
    if v_var is null or v_var !~ '^[A-Z0-9]{20,}$' then return jsonb_build_object('ok', false, 'error', 'No Square item linked.'); end if;
    select retail_sell_price into v_old from stock_items where id = t.stock_item_id;
    select * into q from retail_price_proposal where stock_item_id = t.stock_item_id and status = 'pending' order by id desc limit 1;
    if found then
      v_qid := q.id; v_src := 'owner:' || q.id; v_bd := q.basis_date; v_bs := q.basis_seq;
    else
      select * into pi from processed_invoices where source_id = t.source_id;
      v_src := 'owner:task:' || t.id; v_bd := coalesce(pi.invoice_date, t.invoice_date, current_date); v_bs := coalesce(pi.id, 0);
    end if;
    v_lbl := produce_price_label(t.stock_item_id, v_var) || jsonb_build_object('stock_item_id', t.stock_item_id, 'square_variation_id', v_var,
             'old', v_old, 'new', v_price, 'pct', case when v_old > 0 then round((v_price - v_old) / v_old * 100, 2) end, 'set_by', p_by);
    res := price_propose(jsonb_build_object('mode', 'authorised', 'item', t.stock_item_id, 'variation', v_var, 'old', v_old, 'new', v_price,
             'lane', 'approve', 'method', 'owner', 'price_pct', case when v_old > 0 then round((v_price - v_old) / v_old * 100, 2) end,
             'source', v_src, 'task_source', t.source_id, 'basis_date', v_bd, 'basis_seq', v_bs, 'supplier', t.supplier,
             'invoice_number', t.invoice_number, 'invoice_date', t.invoice_date, 'department', t.department, 'authorised_by', p_by, 'label', v_lbl));
    if res->>'outcome' <> 'authorised' then
      return jsonb_build_object('ok', false, 'error', 'A newer delivery has changed this price. Refresh and check again.', 'outcome', res->>'outcome');
    end if;
    if v_qid is not null then
      update retail_price_proposal set decided_by = left(p_by || ' approved ' || v_price, 120) where id = v_qid;
    end if;
  end if;
  update delivery_tasks set status = 'approved', done_by = p_by, done_at = now(),
         answer = jsonb_build_object('decision', 'approve', 'price', v_price, 'practice', v_test, 'register', 'on tag confirm')
   where id = t.id;
  return jsonb_build_object('ok', true, 'status', 'approved', 'price', v_price, 'practice', v_test, 'register', 'on tag confirm');
end $$;

-- 12) nightly rules: auto lane proposes + tag job; approve lane queues for Josh. Items visited in id order.
create or replace function public.price_rules_scan(p_dry_run boolean DEFAULT true)
returns jsonb language plpgsql set search_path to 'public', 'extensions', 'pg_temp' as $$
declare r record; v_lane text; res jsonb; v_src text := 'rules:' || current_date;
        v_applied int := 0; v_queued int := 0; v_forced int := 0; v_failed int := 0; v_rows jsonb := '[]'::jsonb;
begin
  for r in select * from v_price_rule_candidates where skip_reason is null and lane <> 'never' order by stock_item_id loop
    v_lane := r.lane;
    if r.exceeds_max_pct and v_lane = 'auto' then v_lane := 'approve'; v_forced := v_forced + 1; end if;
    if v_lane = 'approve' then
      if not exists (select 1 from retail_price_proposal q where q.stock_item_id = r.stock_item_id and q.status in ('pending', 'authorised')) then
        if not p_dry_run then
          res := price_propose(jsonb_build_object('mode', 'pending', 'item', r.stock_item_id, 'variation', r.square_variation_id, 'old', r.old_price,
                   'new', r.proposed_price, 'lane', r.lane, 'method', r.method, 'old_cost', r.anchor_cost, 'new_cost', r.new_cost, 'cost_pct', r.cost_pct,
                   'price_pct', r.price_pct, 'cogs_after', r.cogs_pct_after, 'below_floor', r.below_floor, 'source', v_src, 'basis_date', current_date, 'basis_seq', 0));
          continue when res->>'outcome' <> 'pending';
        end if;
        v_queued := v_queued + 1;
        v_rows := v_rows || jsonb_build_object('item', r.name, 'action', 'queued', 'from', r.old_price, 'to', r.proposed_price, 'cost_pct', r.cost_pct);
      end if;
    elsif v_lane = 'auto' then
      continue when exists (select 1 from retail_price_proposal q where q.stock_item_id = r.stock_item_id and q.status = 'authorised' and q.proposed_price = r.proposed_price);
      if p_dry_run then
        v_applied := v_applied + 1;
        v_rows := v_rows || jsonb_build_object('item', r.name, 'action', 'would_propose', 'from', r.old_price, 'to', r.proposed_price);
      elsif r.square_variation_id !~ '^[A-Z0-9]{20,}$' then
        v_failed := v_failed + 1;
        v_rows := v_rows || jsonb_build_object('item', r.name, 'action', 'failed', 'detail', 'no real Square variation id');
      else
        res := price_propose(jsonb_build_object('mode', 'authorised', 'item', r.stock_item_id, 'variation', r.square_variation_id, 'old', r.old_price,
                 'new', r.proposed_price, 'lane', 'auto', 'method', r.method, 'old_cost', r.anchor_cost, 'new_cost', r.new_cost, 'cost_pct', r.cost_pct,
                 'price_pct', r.price_pct, 'cogs_after', r.cogs_pct_after, 'below_floor', r.below_floor, 'source', v_src, 'basis_date', current_date,
                 'basis_seq', 0, 'supplier', 'Price rules', 'invoice_date', current_date, 'authorised_by', 'auto: nightly rules',
                 'label', produce_price_label(r.stock_item_id, r.square_variation_id)
                          || jsonb_build_object('stock_item_id', r.stock_item_id, 'square_variation_id', r.square_variation_id)));
        continue when res->>'outcome' <> 'authorised';
        v_applied := v_applied + 1;
        v_rows := v_rows || jsonb_build_object('item', r.name, 'action', 'tag_job', 'from', r.old_price, 'to', r.proposed_price);
      end if;
    end if;
  end loop;
  return jsonb_build_object('dry_run', p_dry_run, 'applied', v_applied, 'queued', v_queued, 'forced_to_approval', v_forced,
                            'failed', v_failed, 'rows', v_rows, 'note', 'applied = tag jobs created; register changes on staff confirm');
end $$;

-- 13) approved queue: authorise + tag job (no push). Items visited in id order.
create or replace function public.price_proposal_apply(p_dry_run boolean DEFAULT true)
returns jsonb language plpgsql set search_path to 'public', 'extensions', 'pg_temp' as $$
declare r record; res jsonb; v_ok int := 0; v_rows jsonb := '[]'::jsonb;
begin
  for r in
    select q.*, si.name, ssm.square_variation_id
      from retail_price_proposal q join stock_items si on si.id = q.stock_item_id join square_sync_map ssm on ssm.stock_item_id = q.stock_item_id
     where q.status = 'approved' order by q.stock_item_id, q.id
  loop
    if not p_dry_run then
      res := price_propose(jsonb_build_object('mode', 'authorised', 'item', r.stock_item_id, 'variation', r.square_variation_id, 'old', r.old_price,
               'new', r.proposed_price, 'lane', r.lane, 'method', r.method, 'old_cost', r.old_cost, 'new_cost', r.new_cost, 'cost_pct', r.cost_pct,
               'price_pct', r.price_pct, 'cogs_after', r.cogs_pct_after, 'below_floor', r.below_floor, 'source', 'approved:' || r.id,
               'basis_date', r.detected_at::date, 'basis_seq', 0, 'supplier', 'Approved prices', 'invoice_date', current_date,
               'authorised_by', coalesce(r.decided_by, 'approved'),
               'label', produce_price_label(r.stock_item_id, r.square_variation_id)
                        || jsonb_build_object('stock_item_id', r.stock_item_id, 'square_variation_id', r.square_variation_id)));
      update retail_price_proposal set status = case when res->>'outcome' = 'authorised' then 'superseded' else 'skipped' end, decided_at = now(),
             decided_by = coalesce(decided_by, 'approved'),
             skip_reason = case when res->>'outcome' = 'authorised' then 'moved to tag confirm' else 'not applied: ' || (res->>'outcome') end
       where id = r.id;
      continue when res->>'outcome' <> 'authorised';
    end if;
    v_ok := v_ok + 1;
    v_rows := v_rows || jsonb_build_object('item', r.name, 'action', case when p_dry_run then 'would_create_tag_job' else 'tag_job' end, 'to', r.proposed_price);
  end loop;
  return jsonb_build_object('dry_run', p_dry_run, 'applied', v_ok, 'failed', 0, 'rows', v_rows);
end $$;

-- 14) staff list: price fields and each half/quarter as a named row (no Square ids)
do $m$
declare d text := pg_get_functiondef('public.delivery_tasks_list()'::regprocedure);
begin
  d := replace(d, $q$'id', t.id, 'kind', t.kind, 'status', t.status,$q$,
                  $q$'id', t.id, 'kind', t.kind, 'status', t.status, 'price_mode', coalesce(t.price_mode, case when t.kind = 'tag' then 'tag_only' end), 'apply_state', t.apply_state, 'apply_result', t.apply_result, 'parts', case when t.price_mode = 'apply_on_confirm' then (select coalesce(jsonb_agg(jsonb_build_object('name', o.label->>'name', 'per', o.label->>'per', 'old', round(o.expected_cents / 100.0, 2), 'new', round(o.target_cents / 100.0, 2), 'state', o.state) order by o.id), '[]'::jsonb) from price_apply_op o where o.task_id = t.id and o.role = 'part') end,$q$);
  if d not like '%''price_mode''%' then raise exception 'delivery_tasks_list patch did not apply'; end if;
  execute d;
end $m$;

-- 15) privileges: internal only
do $m$
declare f regprocedure;
begin
  foreach f in array array['public.price_item_lock(bigint)', 'public.price_op_key(bigint,integer)', 'public.price_square_get(text)',
    'public.price_square_put(text,bigint,integer,text)', 'public.price_propose(jsonb)', 'public.price_op_run(bigint,text)',
    'public.price_task_settle(bigint,text)', 'public.delivery_tag_claim(bigint,text)', 'public.delivery_tag_apply(bigint,uuid,text)',
    'public.delivery_tag_confirm(bigint,text)', 'public.delivery_task_tick(bigint,text)', 'public.price_op_resolve(bigint,text,integer,text)',
    'public.produce_price_items(text,bigint[],boolean)', 'public.delivery_price_decide(bigint,text,numeric,text)',
    'public.price_rules_scan(boolean)', 'public.price_proposal_apply(boolean)', 'public.delivery_tasks_list()']::regprocedure[] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $m$;
