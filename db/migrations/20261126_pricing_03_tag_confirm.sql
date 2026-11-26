-- STATUS: STAGED FOR REVIEW. NOT APPLIED.
-- Owner-approved policy (26 Nov 2026): a new invoice calculates a PROPOSED selling price and creates a shelf-tag job;
-- the register (Square) price changes only when staff confirm "Tag changed — update register". Cost and stock
-- booking are unaffected (they happen in invoice ingestion, which this file does not touch).
--
-- Rules implemented here
--  * Every path that used to push a selling price straight to Square now creates an AUTHORISED proposal + an
--    apply-on-confirm tag job instead: invoice arrival (produce_price_items, also reached from box counts),
--    owner approval (delivery_price_decide), nightly auto lane (price_rules_scan), approved queue (price_proposal_apply).
--  * Owner gates unchanged: moves over the policy ceiling still become PENDING proposals + owner 'hold' jobs. Staff
--    confirmation can only apply a proposal that is already 'authorised' (auto lane within policy, or owner-approved).
--  * One live authorised proposal per item. A newer one supersedes the older proposal and closes its open tag job
--    (state 'superseded'); an owner 'pending' proposal for the item is also superseded with its hold job closed.
--  * Transition: every EXISTING tag job becomes price_mode 'tag_only' (its price was already pushed). Tag-only jobs
--    never write to Square. Old Done jobs are not reinterpreted.
--  * Confirm is atomic and idempotent: a row claim (state 'applying' + token) blocks double clicks; a stale claim
--    (> 2 min) can be re-claimed. Before writing, Square is read: if it already shows the new price the job completes
--    without writing (covers a timeout after a successful write); if it shows neither the expected old price nor the
--    new price the job becomes 'conflict' for Josh. The write uses the version just read (Square rejects a stale
--    version) and an idempotency key per job+price, then Square is read back and must show the new price before the
--    job is completed. Any failure leaves state 'failed' with the reason; Try again is safe.
--  * Square idempotency: each apply job holds a durable op_key, reused across retries while the last write outcome is
--    ambiguous (no/5xx response, timeout) and replaced only after a definite failure (version conflict or 4xx). The
--    key is never derived from variation+price, so a price returning to an earlier value is a new operation.
--    (The legacy square_set_variation_price keeps its variation+cents key but has no remaining automatic caller.)
--  * Halves/quarters: their prices are FROZEN on the proposal when it is created (parts list shown on the same grouped
--    tag job). On confirm each part is checked against its own frozen old price: unchanged -> written with its own
--    op key and read back; already at new -> done; anything else -> that part is a conflict for Josh. Parts are
--    never recalculated from the latest cost at confirm time.
--  * Audit: price_apply_audit records each attempt (job, proposal, invoice source, item, variation, expected old,
--    new, Square before/after, outcome, staff, time).
--  * Test isolation: Square I/O goes through price_square_get/price_square_put. If the session has a temp table
--    pg_temp.square_mock they use it and never call Square (see db/tests/pricing_03_selftest.sql).
--
-- EXACT INTENDED MUTATIONS
--   function_backup: +6 rows (label 'pre-tag-confirm-2026-11-26').
--   retail_price_proposal: status check gains 'authorised'; ADD columns source, authorised_by, authorised_at, parts;
--     partial unique index one 'authorised' per item. No existing rows change.
--   delivery_tasks: status check gains 'superseded'; ADD columns price_mode, proposal_id, apply_state, claim_token,
--     claimed_at, attempts, apply_result, op_key; UPDATE price_mode = 'tag_only' on all existing kind='tag' rows
--     (count at apply time; nothing else changes on those rows).
--   CREATE table price_apply_audit (RLS on, service_role only).
--   REPLACE functions: produce_price_items, delivery_price_decide, price_rules_scan, price_proposal_apply,
--     delivery_task_tick (kept as a thin wrapper), delivery_tasks_list (adds price fields to each task).
--   CREATE functions: price_square_get, price_square_put, price_propose_for_tag, price_parts_apply, delivery_tag_confirm.
--   No Square writes, no price changes and no stock changes happen when this file is applied.
-- Rollback: db/rollback/20261126_pricing_03_tag_confirm_rollback.sql

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
  add column if not exists parts jsonb not null default '[]'::jsonb;
create unique index if not exists retail_price_proposal_authorised_uniq
  on public.retail_price_proposal (stock_item_id) where status = 'authorised';

alter table public.delivery_tasks drop constraint if exists delivery_tasks_status_check;
alter table public.delivery_tasks add constraint delivery_tasks_status_check
  check (status = any (array['open','done','approved','kept','escalated','closed','superseded']));
alter table public.delivery_tasks
  add column if not exists price_mode text check (price_mode in ('tag_only','apply_on_confirm')),
  add column if not exists proposal_id bigint references public.retail_price_proposal(id),
  add column if not exists apply_state text check (apply_state in ('ready','applying','applied','failed','conflict','superseded')),
  add column if not exists claim_token uuid,
  add column if not exists claimed_at timestamptz,
  add column if not exists attempts integer not null default 0,
  add column if not exists apply_result jsonb,
  add column if not exists op_key uuid;
update public.delivery_tasks set price_mode = 'tag_only' where kind = 'tag' and price_mode is null;

create table if not exists public.price_apply_audit (
  id bigserial primary key,
  task_id bigint references public.delivery_tasks(id),
  proposal_id bigint references public.retail_price_proposal(id),
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

-- 2) Square I/O (mockable)
create or replace function public.price_square_get(p_var text)
returns jsonb language plpgsql set search_path to 'public', 'extensions', 'pg_temp' as $$
declare r jsonb; m record;
begin
  if to_regclass('pg_temp.square_mock') is not null then
    execute 'select cents, version, fail_get from pg_temp.square_mock where variation_id = $1' into m using p_var;
    if m is null or m.fail_get then return jsonb_build_object('ok', false, 'error', 'mock get failure'); end if;
    return jsonb_build_object('ok', true, 'cents', m.cents, 'version', m.version, 'mock', true);
  end if;
  r := square_api('GET', '/v2/catalog/object/' || p_var || '?include_related_objects=false', null);
  if (r->>'status')::int <> 200 then return jsonb_build_object('ok', false, 'error', 'GET ' || (r->>'status'), 'body', r->'body'); end if;
  return jsonb_build_object('ok', true,
    'cents', (r->'body'->'object'->'item_variation_data'->'price_money'->>'amount')::int,
    'version', (r->'body'->'object'->>'version')::bigint,
    'object', r->'body'->'object');
end $$;

-- Writes p_cents only if the variation is still at p_version (Square rejects a stale version). Returns {ok, conflict?}.
create or replace function public.price_square_put(p_var text, p_version bigint, p_cents int, p_idem text)
returns jsonb language plpgsql set search_path to 'public', 'extensions', 'pg_temp' as $$
declare g jsonb; obj jsonb; r jsonb; m record;
begin
  if to_regclass('pg_temp.square_mock') is not null then
    execute 'select cents, version, fail_put, lose_response from pg_temp.square_mock where variation_id = $1' into m using p_var;
    if m is null or m.fail_put then return jsonb_build_object('ok', false, 'ambiguous', false, 'error', 'mock put failure'); end if;
    if m.version <> p_version then return jsonb_build_object('ok', false, 'conflict', true, 'error', 'version changed'); end if;
    execute 'update pg_temp.square_mock set cents = $2, version = version + 1, puts = puts + 1 where variation_id = $1' using p_var, p_cents;
    if m.lose_response then return jsonb_build_object('ok', false, 'ambiguous', true, 'error', 'mock timeout after write'); end if;
    return jsonb_build_object('ok', true, 'mock', true);
  end if;
  g := square_api('GET', '/v2/catalog/object/' || p_var || '?include_related_objects=false', null);
  if (g->>'status')::int <> 200 then return jsonb_build_object('ok', false, 'error', 'GET ' || (g->>'status')); end if;
  obj := g->'body'->'object';
  if (obj->>'version')::bigint <> p_version then return jsonb_build_object('ok', false, 'conflict', true, 'error', 'version changed'); end if;
  obj := jsonb_set(obj, '{item_variation_data,price_money}', jsonb_build_object('amount', p_cents, 'currency', 'AUD'));
  r := square_api('POST', '/v2/catalog/object', jsonb_build_object('idempotency_key', p_idem, 'object', obj));
  if (r->>'status')::int = 200 then return jsonb_build_object('ok', true, 'version', (r->'body'->'catalog_object'->>'version')::bigint); end if;
  return jsonb_build_object('ok', false, 'conflict', coalesce(r::text ~* 'VERSION_MISMATCH', false),
                            'ambiguous', coalesce((r->>'status')::int, 0) = 0 or (r->>'status')::int >= 500,
                            'error', 'POST ' || coalesce(r->>'status', 'no response'), 'body', r->'body');
end $$;

-- 3) proposal + tag job (no Square write)
create or replace function public.price_propose_for_tag(
  p_stock_item_id bigint, p_var text, p_old numeric, p_new numeric, p_lane text, p_method text,
  p_old_cost numeric, p_new_cost numeric, p_cost_pct numeric, p_price_pct numeric, p_cogs_after numeric, p_below_floor boolean,
  p_source_id text, p_supplier text, p_invoice_number text, p_invoice_date date, p_department text,
  p_authorised_by text, p_label jsonb)
returns bigint language plpgsql set search_path to 'public', 'pg_temp' as $$
declare v_prop bigint; v_task bigint; v_parts jsonb;
begin
  perform pg_advisory_xact_lock(hashtext('price-item:' || p_stock_item_id));
  -- supersede the older authorised/pending proposal for this item and close its open jobs
  with old as (
    update retail_price_proposal set status = 'superseded', decided_at = now(),
           decided_by = left('superseded by ' || coalesce(p_source_id, p_authorised_by), 120)
     where stock_item_id = p_stock_item_id and status in ('authorised', 'pending') returning id)
  update delivery_tasks t set status = 'superseded', apply_state = case when t.price_mode = 'apply_on_confirm' then 'superseded' else t.apply_state end,
         done_by = 'system', done_at = now()
    from old where t.status = 'open' and (t.proposal_id = old.id
           or (t.kind = 'hold' and t.stock_item_id = p_stock_item_id));
  -- freeze half/quarter prices now (from the same cost basis); they are applied with the parent tag, never recalculated
  select coalesce(jsonb_agg(jsonb_build_object('variation', x->>'variation', 'from', x->'from', 'to', x->'to')), '[]'::jsonb)
    into v_parts from jsonb_array_elements(coalesce(sync_part_variation_prices(p_stock_item_id, true), '[]'::jsonb)) x;
  insert into retail_price_proposal (stock_item_id, lane, method, old_cost, new_cost, cost_pct, old_price, proposed_price,
                                     price_pct, cogs_pct_after, below_floor, status, source, authorised_by, authorised_at, parts)
  values (p_stock_item_id, p_lane, p_method, p_old_cost, p_new_cost, p_cost_pct, p_old, p_new, p_price_pct, p_cogs_after,
          coalesce(p_below_floor, false), 'authorised', p_source_id, p_authorised_by, now(), v_parts)
  returning id into v_prop;
  insert into delivery_tasks (source_id, supplier, invoice_number, invoice_date, department, kind, stock_item_id,
                              square_variation_id, info, price_mode, proposal_id, apply_state)
  values (p_source_id, p_supplier, p_invoice_number, p_invoice_date, coalesce(p_department, 'Grocer'), 'tag', p_stock_item_id,
          p_var, coalesce(p_label, '{}'::jsonb) || jsonb_build_object('old', p_old, 'new', p_new, 'parts', v_parts), 'apply_on_confirm', v_prop, 'ready')
  on conflict (source_id, kind, coalesce(stock_item_id, 0), coalesce(unmatched_id, 0)) do update
     set info = excluded.info, price_mode = 'apply_on_confirm', proposal_id = excluded.proposal_id, apply_state = 'ready',
         status = 'open', done_by = null, done_at = null, claim_token = null, claimed_at = null, apply_result = null, op_key = null
   where delivery_tasks.apply_state is distinct from 'applied'
  returning id into v_task;
  return v_task;
end $$;

-- 4) halves/quarters: apply the FROZEN part prices from the proposal (each checked against its own frozen old price)
create or replace function public.price_parts_apply(p_parts jsonb, p_stock_item_id bigint, p_task_id bigint, p_op uuid)
returns jsonb language plpgsql set search_path to 'public', 'extensions', 'pg_temp' as $$
declare r jsonb; g jsonb; w jsonb; a jsonb; v_out jsonb := '[]'::jsonb; v_to int; v_from int; v_outcome text;
begin
  for r in select * from jsonb_array_elements(coalesce(p_parts, '[]'::jsonb)) loop
    v_to := round((r->>'to')::numeric * 100)::int;
    v_from := case when r->>'from' is null then null else round((r->>'from')::numeric * 100)::int end;
    g := price_square_get(r->>'variation');
    if not coalesce((g->>'ok')::boolean, false) then
      v_outcome := 'failed';
    elsif (g->>'cents')::int = v_to then
      v_outcome := 'applied_already';
    elsif v_from is not null and (g->>'cents')::int is distinct from v_from then
      v_outcome := 'conflict';
    else
      w := price_square_put(r->>'variation', (g->>'version')::bigint, v_to, 'poppies-tagpart-' || p_op || '-' || (r->>'variation'));
      a := price_square_get(r->>'variation');
      v_outcome := case when coalesce((a->>'ok')::boolean, false) and (a->>'cents')::int = v_to then 'applied'
                        when coalesce((w->>'conflict')::boolean, false) then 'conflict' else 'failed' end;
    end if;
    if v_outcome in ('applied', 'applied_already') then
      insert into retail_part_variation_price (square_variation_id, stock_item_id, price, updated_at, last_push)
      values (r->>'variation', p_stock_item_id, (r->>'to')::numeric, now(), jsonb_build_object('task', p_task_id, 'outcome', v_outcome))
      on conflict (square_variation_id) do update set price = excluded.price, updated_at = now(), last_push = excluded.last_push;
    end if;
    v_out := v_out || jsonb_build_object('variation', r->>'variation', 'from', r->'from', 'to', r->'to', 'outcome', v_outcome,
                                         'square_cents', g->'cents');
  end loop;
  return v_out;
end $$;

-- 5) staff confirmation
create or replace function public.delivery_tag_confirm(p_task_id bigint, p_by text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp' as $$
declare
  t delivery_tasks%rowtype; q retail_price_proposal%rowtype; v_token uuid := gen_random_uuid();
  g jsonb; w jsonb; a jsonb; v_new int; v_old int; v_parts jsonb; v_by text := left(btrim(coalesce(p_by, '')), 40);
begin
  select * into t from delivery_tasks where id = p_task_id;
  if not found or t.kind <> 'tag' then return jsonb_build_object('ok', false, 'error', 'Not a shelf-tag job.'); end if;

  -- legacy / tag-only: no register write, ever
  if coalesce(t.price_mode, 'tag_only') = 'tag_only' then
    update delivery_tasks set status = 'done', done_by = v_by, done_at = now() where id = p_task_id and status = 'open';
    return jsonb_build_object('ok', true, 'status', 'done', 'register', 'unchanged');
  end if;

  -- idempotent outcomes
  if t.apply_state = 'applied' then return jsonb_build_object('ok', true, 'status', 'done', 'register', 'updated', 'already', true); end if;
  if t.apply_state = 'superseded' or t.status = 'superseded' then
    return jsonb_build_object('ok', false, 'status', 'superseded', 'error', 'A newer price replaced this one. Use the newer tag job.');
  end if;
  if t.apply_state = 'conflict' then
    return jsonb_build_object('ok', false, 'status', 'conflict', 'error', 'The register price was changed elsewhere. Josh needs to check this one.');
  end if;

  -- atomic claim (double clicks / overlapping retries); a claim older than 2 minutes may be taken over
  update delivery_tasks set apply_state = 'applying', claim_token = v_token, claimed_at = now(), attempts = attempts + 1,
         op_key = coalesce(op_key, gen_random_uuid())
   where id = p_task_id and status = 'open'
     and (apply_state in ('ready', 'failed') or (apply_state = 'applying' and claimed_at < now() - interval '2 minutes'))
  returning * into t;
  if not found then
    return jsonb_build_object('ok', false, 'status', 'busy', 'error', 'Already being updated. Wait a moment, then check again.');
  end if;

  select * into q from retail_price_proposal where id = t.proposal_id for update;
  if not found or q.status <> 'authorised' then
    update delivery_tasks set apply_state = 'superseded', status = 'superseded', done_by = 'system', done_at = now() where id = p_task_id;
    return jsonb_build_object('ok', false, 'status', 'superseded', 'error', 'This price is no longer current. Use the newer tag job.');
  end if;

  v_new := round(q.proposed_price * 100)::int;
  v_old := round(q.old_price * 100)::int;
  g := price_square_get(t.square_variation_id);
  if not coalesce((g->>'ok')::boolean, false) then
    update delivery_tasks set apply_state = 'failed', apply_result = jsonb_build_object('stage', 'read', 'error', g->>'error') where id = p_task_id;
    insert into price_apply_audit (task_id, proposal_id, source_id, stock_item_id, square_variation_id, expected_old, new_price, square_before, outcome, by)
    values (t.id, q.id, t.source_id, t.stock_item_id, t.square_variation_id, q.old_price, q.proposed_price, g, 'failed_read', v_by);
    return jsonb_build_object('ok', false, 'status', 'failed', 'error', 'Couldn''t read the register price. Try again.');
  end if;

  if (g->>'cents')::int = v_new then
    w := jsonb_build_object('ok', true, 'already', true);           -- e.g. earlier attempt wrote but timed out
  elsif (g->>'cents')::int is distinct from v_old then
    update delivery_tasks set apply_state = 'conflict', apply_result = jsonb_build_object('stage', 'compare', 'square_cents', g->'cents', 'expected_old', v_old) where id = p_task_id;
    insert into price_apply_audit (task_id, proposal_id, source_id, stock_item_id, square_variation_id, expected_old, new_price, square_before, outcome, by)
    values (t.id, q.id, t.source_id, t.stock_item_id, t.square_variation_id, q.old_price, q.proposed_price, g - 'object', 'conflict', v_by);
    return jsonb_build_object('ok', false, 'status', 'conflict', 'error', 'The register price was changed elsewhere. Josh needs to check this one.');
  else
    w := price_square_put(t.square_variation_id, (g->>'version')::bigint, v_new, 'poppies-tag-' || t.op_key);
  end if;

  if not coalesce((w->>'ok')::boolean, false) then
    -- ambiguous outcome: keep op_key so a retry reuses it (and the read-before-write detects an applied price);
    -- definite failure: drop op_key so the next attempt is a new operation
    update delivery_tasks set apply_state = case when coalesce((w->>'conflict')::boolean, false) then 'conflict' else 'failed' end,
           op_key = case when coalesce((w->>'ambiguous')::boolean, false) then op_key else null end,
           apply_result = jsonb_build_object('stage', 'write', 'error', w->>'error', 'ambiguous', coalesce((w->>'ambiguous')::boolean, false))
     where id = p_task_id;
    insert into price_apply_audit (task_id, proposal_id, source_id, stock_item_id, square_variation_id, expected_old, new_price, square_before, square_after, outcome, by)
    values (t.id, q.id, t.source_id, t.stock_item_id, t.square_variation_id, q.old_price, q.proposed_price, g - 'object', w, 'failed_write', v_by);
    return jsonb_build_object('ok', false, 'status', 'failed', 'error', 'The register didn''t take the new price. Try again.');
  end if;

  a := price_square_get(t.square_variation_id);                     -- read back
  if not coalesce((a->>'ok')::boolean, false) or (a->>'cents')::int <> v_new then
    update delivery_tasks set apply_state = 'failed', apply_result = jsonb_build_object('stage', 'readback', 'after', a - 'object') where id = p_task_id;
    insert into price_apply_audit (task_id, proposal_id, source_id, stock_item_id, square_variation_id, expected_old, new_price, square_before, square_after, outcome, by)
    values (t.id, q.id, t.source_id, t.stock_item_id, t.square_variation_id, q.old_price, q.proposed_price, g - 'object', a - 'object', 'failed_readback', v_by);
    return jsonb_build_object('ok', false, 'status', 'failed', 'error', 'Couldn''t confirm the register price. Try again.');
  end if;

  perform set_config('poppies.price_source', left('tag:' || coalesce(t.invoice_number, t.source_id) || ' by ' || v_by, 120), true);
  update stock_items set retail_sell_price = q.proposed_price where id = t.stock_item_id;
  update retail_price_history set pushed_to_square_at = now(), shelf_label_updated_at = now()
   where id = (select max(id) from retail_price_history where stock_item_id = t.stock_item_id);
  v_parts := price_parts_apply(q.parts, t.stock_item_id, t.id, t.op_key);
  update retail_price_proposal set status = 'applied', applied_at = now(), square_result = w || jsonb_build_object('parts', v_parts) where id = q.id;
  update delivery_tasks set status = 'done', apply_state = 'applied', done_by = v_by, done_at = now(),
         apply_result = jsonb_build_object('square_before', g->'cents', 'square_after', a->'cents', 'parts', v_parts)
   where id = p_task_id;
  insert into price_apply_audit (task_id, proposal_id, source_id, stock_item_id, square_variation_id, expected_old, new_price, square_before, square_after, outcome, by)
  values (t.id, q.id, t.source_id, t.stock_item_id, t.square_variation_id, q.old_price, q.proposed_price, g - 'object', a - 'object',
          case when coalesce((w->>'already')::boolean, false) then 'applied_already' else 'applied' end, v_by);
  return jsonb_build_object('ok', true, 'status', 'done', 'register', 'updated', 'parts', v_parts);
end $$;

-- delivery_task_tick keeps its name/signature for the Edge function and now delegates.
create or replace function public.delivery_task_tick(p_task_id bigint, p_by text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  return delivery_tag_confirm(p_task_id, p_by);
end $$;

-- 6) invoice arrival: propose + tag job instead of pushing
create or replace function public.produce_price_items(p_source_id text, p_item_ids bigint[], p_dry_run boolean DEFAULT true)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp' as $$
declare
  pi record; r record; v_lbl jsonb;
  v_applied jsonb := '[]'; v_held jsonb := '[]'; v_failed jsonb := '[]'; v_noprice jsonb := '[]';
begin
  select * into pi from processed_invoices where source_id = p_source_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'invoice not booked'); end if;

  for r in
    select c.* from v_price_rule_candidates c
     where c.stock_item_id = any (coalesce(p_item_ids, '{}'))
       and c.retail_category = 'Produce' and c.policy_source = 'retail_category' and c.method = 'band'
       and c.lane <> 'never' and c.skip_reason is null
     order by c.name
  loop
    v_lbl := produce_price_label(r.stock_item_id, r.square_variation_id)
             || jsonb_build_object('stock_item_id', r.stock_item_id, 'square_variation_id', r.square_variation_id,
                                   'old', r.old_price, 'new', r.proposed_price, 'pct', r.price_pct);
    if r.exceeds_max_pct then
      if not p_dry_run and not exists (select 1 from retail_price_proposal q where q.stock_item_id = r.stock_item_id and q.status = 'pending') then
        insert into retail_price_proposal (stock_item_id, lane, method, old_cost, new_cost, cost_pct, old_price, proposed_price, price_pct, cogs_pct_after, below_floor, status, source)
        values (r.stock_item_id, 'approve', r.method, r.anchor_cost, r.new_cost, r.cost_pct, r.old_price, r.proposed_price, r.price_pct, r.cogs_pct_after, coalesce(r.below_floor, false), 'pending', p_source_id);
      end if;
      v_held := v_held || v_lbl;
    elsif p_dry_run then
      v_applied := v_applied || v_lbl;
    elsif r.square_variation_id !~ '^[A-Z0-9]{20,}$' then
      v_failed := v_failed || (v_lbl || jsonb_build_object('error', 'no real Square variation id'));
    else
      perform price_propose_for_tag(r.stock_item_id, r.square_variation_id, r.old_price, r.proposed_price, 'auto', r.method,
                                    r.anchor_cost, r.new_cost, r.cost_pct, r.price_pct, r.cogs_pct_after, r.below_floor,
                                    p_source_id, canonical_supplier(pi.supplier), pi.invoice_number, pi.invoice_date,
                                    canonical_department(pi.department), 'auto: invoice ' || coalesce(pi.invoice_number, p_source_id), v_lbl);
      v_applied := v_applied || v_lbl;   -- "applied" here means: tag job created; register changes on staff confirm
    end if;
  end loop;

  select coalesce(jsonb_agg(produce_price_label(c.stock_item_id, c.square_variation_id)
                            || jsonb_build_object('stock_item_id', c.stock_item_id, 'square_variation_id', c.square_variation_id) order by c.name), '[]')
    into v_noprice
    from v_price_rule_candidates c
   where c.stock_item_id = any (coalesce(p_item_ids, '{}')) and c.skip_reason = 'item has no current shelf price';

  return jsonb_build_object('ok', true, 'applied', v_applied, 'held', v_held, 'failed', v_failed, 'no_price', v_noprice);
end $$;

-- 7) owner approval authorises; staff confirmation applies
create or replace function public.delivery_price_decide(p_task_id bigint, p_decision text, p_price numeric DEFAULT NULL::numeric, p_by text DEFAULT 'Josh'::text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp' as $$
declare t record; v_price numeric; v_var text; v_old numeric; v_test boolean; v_lbl jsonb; v_task bigint; si record;
begin
  select * into t from delivery_tasks where id = p_task_id for update;
  if not found or t.kind not in ('hold', 'noprice') then return jsonb_build_object('ok', false, 'error', 'Not a price job.'); end if;
  if t.status <> 'open' then return jsonb_build_object('ok', false, 'error', 'Already decided.', 'status', t.status); end if;
  v_test := delivery_is_test(t.source_id);

  if p_decision = 'keep' then
    if t.kind <> 'hold' then return jsonb_build_object('ok', false, 'error', 'Enter a price.'); end if;
    if not v_test then
      update retail_price_proposal set status = 'rejected', decided_at = now(), decided_by = p_by,
             skip_reason = left(format('kept via app (%s %s)', t.supplier, coalesce(t.invoice_number, t.source_id)), 200)
       where stock_item_id = t.stock_item_id and status = 'pending';
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
    v_lbl := produce_price_label(t.stock_item_id, v_var) || jsonb_build_object('stock_item_id', t.stock_item_id, 'square_variation_id', v_var,
             'old', v_old, 'new', v_price, 'pct', case when v_old > 0 then round((v_price - v_old) / v_old * 100, 2) end, 'set_by', p_by);
    -- authorise Josh's price; the register changes when staff confirm the tag
    v_task := price_propose_for_tag(t.stock_item_id, v_var, v_old, v_price, 'approve', 'owner', null, null, null,
                                    case when v_old > 0 then round((v_price - v_old) / v_old * 100, 2) end, null, false,
                                    t.source_id, t.supplier, t.invoice_number, t.invoice_date, t.department, p_by, v_lbl);
  end if;
  update delivery_tasks set status = 'approved', done_by = p_by, done_at = now(),
         answer = jsonb_build_object('decision', 'approve', 'price', v_price, 'practice', v_test, 'register', 'on tag confirm')
   where id = t.id;
  return jsonb_build_object('ok', true, 'status', 'approved', 'price', v_price, 'practice', v_test, 'register', 'on tag confirm');
end $$;

-- 8) nightly rules: auto lane proposes + tag job; approve lane unchanged (pending for Josh)
create or replace function public.price_rules_scan(p_dry_run boolean DEFAULT true)
returns jsonb language plpgsql set search_path to 'public', 'extensions', 'pg_temp' as $$
declare r record; v_lane text; v_applied int := 0; v_queued int := 0; v_forced int := 0; v_failed int := 0; v_rows jsonb := '[]'::jsonb;
begin
  for r in select * from v_price_rule_candidates where skip_reason is null and lane <> 'never' order by abs(coalesce(price_pct, 0)) desc loop
    v_lane := r.lane;
    if r.exceeds_max_pct and v_lane = 'auto' then v_lane := 'approve'; v_forced := v_forced + 1; end if;
    if v_lane = 'approve' then
      if not exists (select 1 from retail_price_proposal q where q.stock_item_id = r.stock_item_id and q.status in ('pending', 'authorised')) then
        if not p_dry_run then
          insert into retail_price_proposal (stock_item_id, lane, method, old_cost, new_cost, cost_pct, old_price, proposed_price, price_pct, cogs_pct_after, below_floor, status, source)
          values (r.stock_item_id, r.lane, r.method, r.anchor_cost, r.new_cost, r.cost_pct, r.old_price, r.proposed_price, r.price_pct, r.cogs_pct_after, coalesce(r.below_floor, false), 'pending', 'rules:' || current_date);
        end if;
        v_queued := v_queued + 1;
        v_rows := v_rows || jsonb_build_object('item', r.name, 'action', 'queued', 'from', r.old_price, 'to', r.proposed_price, 'cost_pct', r.cost_pct);
      end if;
    elsif v_lane = 'auto' then
      if exists (select 1 from retail_price_proposal q where q.stock_item_id = r.stock_item_id and q.status = 'authorised' and q.proposed_price = r.proposed_price) then
        continue;   -- already waiting for its tag
      end if;
      if p_dry_run then
        v_applied := v_applied + 1;
        v_rows := v_rows || jsonb_build_object('item', r.name, 'action', 'would_propose', 'from', r.old_price, 'to', r.proposed_price);
      elsif r.square_variation_id !~ '^[A-Z0-9]{20,}$' then
        v_failed := v_failed + 1;
        v_rows := v_rows || jsonb_build_object('item', r.name, 'action', 'failed', 'detail', 'no real Square variation id');
      else
        perform price_propose_for_tag(r.stock_item_id, r.square_variation_id, r.old_price, r.proposed_price, 'auto', r.method,
                                      r.anchor_cost, r.new_cost, r.cost_pct, r.price_pct, r.cogs_pct_after, r.below_floor,
                                      'rules:' || current_date, 'Price rules', null, current_date, null, 'auto: nightly rules',
                                      produce_price_label(r.stock_item_id, r.square_variation_id)
                                        || jsonb_build_object('stock_item_id', r.stock_item_id, 'square_variation_id', r.square_variation_id));
        v_applied := v_applied + 1;
        v_rows := v_rows || jsonb_build_object('item', r.name, 'action', 'tag_job', 'from', r.old_price, 'to', r.proposed_price);
      end if;
    end if;
  end loop;
  return jsonb_build_object('dry_run', p_dry_run, 'applied', v_applied, 'queued', v_queued, 'forced_to_approval', v_forced,
                            'failed', v_failed, 'rows', v_rows, 'note', 'applied = tag jobs created; register changes on staff confirm');
end $$;

-- 9) approved queue: authorise + tag job (no push)
create or replace function public.price_proposal_apply(p_dry_run boolean DEFAULT true)
returns jsonb language plpgsql set search_path to 'public', 'extensions', 'pg_temp' as $$
declare r record; v_ok int := 0; v_rows jsonb := '[]'::jsonb;
begin
  for r in
    select q.*, si.name, ssm.square_variation_id
      from retail_price_proposal q join stock_items si on si.id = q.stock_item_id join square_sync_map ssm on ssm.stock_item_id = q.stock_item_id
     where q.status = 'approved' order by q.id
  loop
    if not p_dry_run then
      update retail_price_proposal set status = 'superseded', decided_at = now(), decided_by = 'moved to tag confirm' where id = r.id;
      perform price_propose_for_tag(r.stock_item_id, r.square_variation_id, r.old_price, r.proposed_price, r.lane, r.method,
                                    r.old_cost, r.new_cost, r.cost_pct, r.price_pct, r.cogs_pct_after, r.below_floor,
                                    'approved:' || r.id, 'Approved prices', null, current_date, null, coalesce(r.decided_by, 'approved'),
                                    produce_price_label(r.stock_item_id, r.square_variation_id)
                                      || jsonb_build_object('stock_item_id', r.stock_item_id, 'square_variation_id', r.square_variation_id));
    end if;
    v_ok := v_ok + 1;
    v_rows := v_rows || jsonb_build_object('item', r.name, 'action', case when p_dry_run then 'would_create_tag_job' else 'tag_job' end, 'to', r.proposed_price);
  end loop;
  return jsonb_build_object('dry_run', p_dry_run, 'applied', v_ok, 'failed', 0, 'rows', v_rows);
end $$;

-- 10) staff list shows price fields
do $m$
declare d text := pg_get_functiondef('public.delivery_tasks_list()'::regprocedure);
begin
  d := replace(d, $q$'id', t.id, 'kind', t.kind, 'status', t.status,$q$,
                  $q$'id', t.id, 'kind', t.kind, 'status', t.status, 'price_mode', coalesce(t.price_mode, case when t.kind = 'tag' then 'tag_only' end), 'apply_state', t.apply_state, 'apply_result', t.apply_result,$q$);
  if d not like '%''price_mode''%' then raise exception 'delivery_tasks_list patch did not apply'; end if;
  execute d;
end $m$;

-- 11) privileges: internal only
do $m$
declare f regprocedure;
begin
  foreach f in array array['public.price_square_get(text)','public.price_square_put(text,bigint,integer,text)',
    'public.price_propose_for_tag(bigint,text,numeric,numeric,text,text,numeric,numeric,numeric,numeric,numeric,boolean,text,text,text,date,text,text,jsonb)',
    'public.price_parts_apply(jsonb,bigint,bigint,uuid)','public.delivery_tag_confirm(bigint,text)','public.delivery_task_tick(bigint,text)',
    'public.produce_price_items(text,bigint[],boolean)','public.delivery_price_decide(bigint,text,numeric,text)',
    'public.price_rules_scan(boolean)','public.price_proposal_apply(boolean)','public.delivery_tasks_list()']::regprocedure[] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $m$;
