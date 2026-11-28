-- pricing_repair_01 — produce pricing repair and hardening, 28 Nov 2026.
-- STATUS: STAGED, NOT APPLIED. Josh (28 Nov, via Codex): "leave prices that are 5c too high and they can be picked up
-- on the next delivery rather than having to change them now. repair and harden then test again".
-- Tests: db/tests/pricing_repair_rollback_test.sql (one transaction that always rolls back; Square stubbed).
-- Rollback: db/rollback/20261128_pricing_repair_01_rollback.sql
--
-- What it changes
--  1. Exact pack arithmetic. New retail_price_for_pack(pack_cost, pack_size, base, category, taxable): cost x markup
--     (x 1.10 if taxable) rounded UP to 5c in exact integer arithmetic, from the unrounded pack cost. Used by
--     v_price_rule_candidates (band method; whole items) and sync_part_variation_prices (halves/quarters). Before, the
--     cost per unit was rounded to 4 dp (or carried a repeating decimal) before the markup, so a price that lands exactly
--     on a 5c step came out 5c high (e.g. 12 for $14.00 -> $2.15, should be $2.10). Passthrough pricing and
--     round_up_5c are unchanged.
--  2. A missing Square variation stays with its item. produce_price_items lists it under "failed" (dry run too) instead
--     of reaching price_propose, which raised and aborted the whole invoice; any other per-item error is caught in a
--     sub-transaction and listed under "failed". price_rules_scan gets the same NULL-safe check.
--  3. The produce queue isolates failures. produce_price_sweep prices each invoice in its own sub-transaction. A failure
--     is recorded in produce_price_attempts and retried with back-off (5 min, doubling, capped at 6 h; parked after 8
--     tries). Invoices never tried are always taken first, so failing invoices cannot starve later deliveries.
--  4. Out-of-date approvals are refused at the entry points that approve or apply them:
--       * price_proposal_decide(ids, 'approved')  - a pending proposal whose shelf price or calculated price has moved is
--         withdrawn (superseded) and, if a change is still due and no delivery tag job is open, re-queued as a fresh
--         pending proposal. The result lists them under "stale".
--       * price_proposal_apply(...)               - an approved proposal that is now out of date is skipped, never applied.
--       * delivery_price_decide (app owner screen, via delivery_owner_decide) - accepting a job's suggested price is
--         refused if the shelf price or the calculation has moved; the job is refreshed with the current figures.
--         A price Josh types himself is still accepted.
-- Mutations on apply: one new empty table, function backups, function/view replacements. No change to stock, shelf
-- prices, proposals, tasks or Square on apply. Existing prices that are 5c high are NOT corrected now: the normal
-- 5c minimum change (Produce min_change_cents = 5, compared with "<") lets the correction through on the next delivery.

do $guard$
declare x record;
begin
  for x in select * from (values
      ('produce_price_items(text,bigint[],boolean)', '4d9f0951e1d39ed29305718dd8e59d26'),
      ('produce_price_sweep()', '9476929e875e5c43dcd3997f96f3a27f'),
      ('price_proposal_decide(bigint[],text,text)', '1dabfac5bf4f118a5682092377441a9c'),
      ('price_proposal_apply(boolean)', '02067b3d70e463891555941ac5134818'),
      ('delivery_price_decide(bigint,text,numeric,text)', '96c4b76f8172b1cdcabd85c5994ae3ca'),
      ('sync_part_variation_prices(bigint,boolean)', '88bdbdffcb867305e1873bafd5621531'),
      ('price_rules_scan(boolean)', '62b54dab1872e8dc8f21bdf4c9f2a15f')) v(sig, h) loop
    if md5(pg_get_functiondef(('public.' || x.sig)::regprocedure)) <> x.h then
      raise exception 'pricing_repair_01 refused: % changed since it was reviewed (28 Nov 14:40)', x.sig;
    end if;
  end loop;
  if md5(pg_get_viewdef('public.v_price_rule_candidates'::regclass)) <> '90291838dcd7a73db0db10fd5c53d8fe' then
    raise exception 'pricing_repair_01 refused: v_price_rule_candidates changed since it was reviewed';
  end if;
end $guard$;

-- 0. backups (restorable with fn_backup_restore(name, 'pre-pricing-repair-2026-11-28'); the view entry restores the view)
insert into public.function_backup (label, fn_name, signature, definition)
select 'pre-pricing-repair-2026-11-28', p.proname, p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
   and p.proname in ('produce_price_items', 'produce_price_sweep', 'price_proposal_decide', 'price_proposal_apply',
                     'delivery_price_decide', 'sync_part_variation_prices', 'price_rules_scan');
insert into public.function_backup (label, fn_name, signature, definition)
values ('pre-pricing-repair-2026-11-28', 'v_price_rule_candidates', 'view',
        'CREATE OR REPLACE VIEW public.v_price_rule_candidates AS ' || pg_get_viewdef('public.v_price_rule_candidates'::regclass));

create function pg_temp.patch(p_src text, p_from text, p_to text) returns text language plpgsql as $$
declare n int := (length(p_src) - length(replace(p_src, p_from, ''))) / greatest(length(p_from), 1);
begin
  if n <> 1 then raise exception 'pricing_repair_01: anchor found % times: %', n, left(p_from, 80); end if;
  return replace(p_src, p_from, p_to);
end $$;

-- 1. exact pack arithmetic --------------------------------------------------------------------------------------------
create or replace function public.retail_price_for_pack(p_pack_cost numeric, p_pack_size numeric, p_base numeric,
                                                         p_category text, p_taxable boolean)
 returns numeric
 language plpgsql
 stable
 set search_path to 'public', 'pg_temp'
as $function$
-- pricing-repair-2026-11-28. Shelf price for "base" units out of a pack: pack_cost / pack_size x base x (1 + markup)
-- (x 1.10 if taxable), rounded UP to the next 5c. Worked as one exact fraction n / d with div/mod (numeric * and div/mod
-- are exact), so a price that lands exactly on a 5c step stays on it.
declare mk numeric; n numeric; d numeric;
begin
  if p_pack_cost is null or p_pack_size is null or p_pack_size = 0 or p_base is null then return null; end if;
  select markup_pct into mk from retail_markups where category = p_category;
  if mk is null then select markup_pct into mk from retail_markups where category = 'Default'; end if;
  if mk is null then return null; end if;
  n := p_pack_cost * p_base * (100 + mk) * (case when p_taxable then 110 else 100 end) * 20;   -- in 5c steps x d
  d := p_pack_size * 10000;
  if d < 0 then n := -n; d := -d; end if;
  return round((div(n, d) + case when mod(n, d) > 0 then 1 else 0 end) / 20.0, 2);
end $function$;

do $v$
declare v text := pg_get_viewdef('public.v_price_rule_candidates'::regclass);
begin
  v := pg_temp.patch(v,
    'round(((cur.pack_cost / NULLIF(cur.pack_grams, (0)::numeric)) * COALESCE(sm.retail_units_base, si.grams_per_count_unit)), 4) AS new_cost,',
    'cur.pack_cost, cur.pack_grams AS pack_size, round(((cur.pack_cost / NULLIF(cur.pack_grams, (0)::numeric)) * COALESCE(sm.retail_units_base, si.grams_per_count_unit)), 4) AS new_cost,');
  v := pg_temp.patch(v,
    'WHEN ''band''::text THEN retail_price_for(b.new_cost, b.retail_category, b.taxable)',
    'WHEN ''band''::text THEN retail_price_for_pack(b.pack_cost, b.pack_size, b.retail_unit_base, b.retail_category, b.taxable)');
  execute 'CREATE OR REPLACE VIEW public.v_price_rule_candidates AS ' || v;
end $v$;

do $s$
declare f text := pg_get_functiondef('public.sync_part_variation_prices(bigint,boolean)'::regprocedure);
begin
  f := pg_temp.patch(f, E'whenever the parent moves.\n',
         E'whenever the parent moves.\n-- pricing-repair-2026-11-28: exact pack arithmetic (retail_price_for_pack), no 4-dp cost rounding.\n');
  f := pg_temp.patch(f, E'retail_price_for(round(c.pack_cost / nullif(c.pack_grams,0) * sm.retail_units_base, 4),\n                            ssm.retail_category, ssm.taxable) as new_price',
         'retail_price_for_pack(c.pack_cost, c.pack_grams, sm.retail_units_base, ssm.retail_category, ssm.taxable) as new_price');
  execute f;
end $s$;

-- 2. missing Square variation isolated to its item -------------------------------------------------------------------
create or replace function public.produce_price_items(p_source_id text, p_item_ids bigint[], p_dry_run boolean default true)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
-- pricing-repair-2026-11-28: an item with no real Square variation, or any error pricing one item, is listed under
-- "failed" for that item only (sub-transaction); the rest of the invoice is still priced.
declare
  pi record; r record; v_lbl jsonb; res jsonb; p jsonb; v_err text;
  v_applied jsonb := '[]'; v_held jsonb := '[]'; v_failed jsonb := '[]'; v_noprice jsonb := '[]'; v_skipped jsonb := '[]';
begin
  select * into pi from processed_invoices where source_id = p_source_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'invoice not booked'); end if;

  for r in
    select c.* from v_price_rule_candidates c
     where c.stock_item_id = any (coalesce(p_item_ids, '{}'))
       and c.retail_category = 'Produce' and c.policy_source = 'retail_category' and c.method = 'band'
       and c.lane <> 'never'
       and (c.skip_reason is null or (c.skip_reason = 'item has no current shelf price' and c.proposed_price is not null))
     order by c.stock_item_id
  loop
    v_lbl := produce_price_label(r.stock_item_id, r.square_variation_id)
             || jsonb_build_object('stock_item_id', r.stock_item_id, 'square_variation_id', r.square_variation_id,
                                   'old', r.old_price, 'new', r.proposed_price, 'pct', r.price_pct);
    if coalesce(r.square_variation_id, '') !~ '^[A-Z0-9]{20,}$' then
      v_failed := v_failed || (v_lbl || jsonb_build_object('error', 'no real Square variation id'));
      continue;
    end if;
    if p_dry_run then
      v_applied := v_applied || v_lbl;
      continue;
    end if;
    p := jsonb_build_object('item', r.stock_item_id, 'variation', r.square_variation_id, 'old', r.old_price, 'new', r.proposed_price,
           'method', r.method, 'old_cost', r.anchor_cost, 'new_cost', r.new_cost, 'cost_pct', r.cost_pct, 'price_pct', r.price_pct,
           'cogs_after', r.cogs_pct_after, 'below_floor', r.below_floor, 'source', p_source_id,
           'basis_date', coalesce(pi.invoice_date, pi.processed_at::date), 'basis_seq', pi.id);
    begin
      res := price_propose(p || jsonb_build_object('mode', 'authorised', 'lane', 'auto', 'label', v_lbl,
               'supplier', canonical_supplier(pi.supplier), 'invoice_number', pi.invoice_number, 'invoice_date', pi.invoice_date,
               'department', canonical_department(pi.department),
               'authorised_by', 'auto (markup, Josh 28 Nov): invoice ' || coalesce(pi.invoice_number, p_source_id)));
      if res->>'outcome' = 'authorised' or (res->>'outcome' = 'replay' and coalesce((res->>'task_open')::boolean, false)) then
        v_applied := v_applied || v_lbl;
      else
        v_skipped := v_skipped || (v_lbl || jsonb_build_object('outcome', res->>'outcome', 'status', res->>'status'));
      end if;
    exception when others then
      get stacked diagnostics v_err = message_text;
      v_failed := v_failed || (v_lbl || jsonb_build_object('error', left('could not price: ' || v_err, 200)));
    end;
  end loop;

  select coalesce(jsonb_agg(produce_price_label(c.stock_item_id, c.square_variation_id)
                            || jsonb_build_object('stock_item_id', c.stock_item_id, 'square_variation_id', c.square_variation_id) order by c.name), '[]')
    into v_noprice
    from v_price_rule_candidates c
   where c.stock_item_id = any (coalesce(p_item_ids, '{}')) and c.skip_reason = 'item has no current shelf price'
     and not (c.retail_category = 'Produce' and c.policy_source = 'retail_category' and c.method = 'band'
              and c.lane <> 'never' and c.proposed_price is not null);

  return jsonb_build_object('ok', true, 'applied', v_applied, 'held', v_held, 'failed', v_failed, 'no_price', v_noprice, 'skipped', v_skipped);
end
$function$;

do $r$
declare f text := pg_get_functiondef('public.price_rules_scan(boolean)'::regprocedure);
begin
  f := pg_temp.patch(f, E'      elsif r.square_variation_id !~ ''^[A-Z0-9]{20,}$'' then',
         E'      elsif coalesce(r.square_variation_id, '''') !~ ''^[A-Z0-9]{20,}$'' then   -- pricing-repair-2026-11-28: NULL-safe');
  execute f;
end $r$;

-- 3. queue isolation with fair retry ---------------------------------------------------------------------------------
create table public.produce_price_attempts (
  source_id text primary key,
  attempts int not null default 0,
  last_error text,
  first_failed_at timestamptz not null default now(),
  last_attempt_at timestamptz,
  next_attempt_at timestamptz,
  parked_at timestamptz,        -- set after 8 failed tries: needs a look (clear the row to retry)
  resolved_at timestamptz       -- set when a later try succeeds
);
alter table public.produce_price_attempts enable row level security;
revoke all on public.produce_price_attempts from public, anon, authenticated;
grant all on public.produce_price_attempts to service_role;

create or replace function public.produce_price_sweep()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
-- pricing-repair-2026-11-28: each invoice is priced in its own sub-transaction. A failure is recorded in
-- produce_price_attempts and retried with back-off (5 min doubling, at most 6 h; parked after 8 tries). Invoices never
-- tried are always taken first, so failing invoices cannot starve later deliveries.
declare v_mode text := (select value from app_config where key = 'produce_autoprice_mode'); r record; v_out jsonb := '[]';
        v_res jsonb; v_ok int := 0; v_bad int := 0; v_err text; v_n int;
begin
  if coalesce(v_mode, 'off') = 'off' then return jsonb_build_object('mode', 'off'); end if;
  for r in
    select pi.source_id from processed_invoices pi
      left join produce_price_attempts a on a.source_id = pi.source_id and a.resolved_at is null
     where pi.processed_at >= (select value from app_config where key = 'produce_autoprice_since')::timestamptz
       and canonical_department(pi.department) = 'Grocer'
       and canonical_supplier(pi.supplier) = any (string_to_array((select value from app_config where key = 'produce_autoprice_suppliers'), ','))
       and coalesce(pi.booked_count, 0) > 0
       and not exists (select 1 from produce_price_runs x where x.source_id = pi.source_id)
       and (a.source_id is null or (a.parked_at is null and a.next_attempt_at <= now()))
     order by coalesce(a.attempts, 0), pi.processed_at limit 5
  loop
    begin
      v_res := produce_price_for_invoice(r.source_id, v_mode <> 'live');
      update produce_price_attempts set resolved_at = now() where source_id = r.source_id and resolved_at is null;
      v_ok := v_ok + 1;
      v_out := v_out || jsonb_build_object(r.source_id, v_res);
    exception when others then
      get stacked diagnostics v_err = message_text;
      insert into produce_price_attempts as a (source_id, attempts, last_error, last_attempt_at, next_attempt_at)
      values (r.source_id, 1, left(v_err, 500), now(), now() + interval '5 minutes')
      on conflict (source_id) do update
         set attempts = a.attempts + 1, last_error = excluded.last_error, last_attempt_at = now(),
             next_attempt_at = now() + least(interval '5 minutes' * power(2, a.attempts)::int, interval '6 hours'),
             parked_at = case when a.attempts + 1 >= 8 then now() end, resolved_at = null
      returning attempts into v_n;
      v_bad := v_bad + 1;
      v_out := v_out || jsonb_build_object(r.source_id, jsonb_build_object('ok', false, 'error', left(v_err, 300), 'attempts', v_n));
    end;
  end loop;
  if jsonb_array_length(v_out) > 0 then
    insert into engine_runs (steps_ok, steps_failed, notes) values (v_ok, v_bad, left('PRODUCE-PRICE mode=' || v_mode || ' ' || v_out::text, 500));
  end if;
  return jsonb_build_object('mode', v_mode, 'runs', v_out, 'failed', v_bad);
end $function$;

-- 4. out-of-date approvals -------------------------------------------------------------------------------------------
create or replace function public.price_current_calc(p_item bigint)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
-- pricing-repair-2026-11-28: the item's shelf price and what the price rules give now. "due" = the rules would
-- propose a change now. With no candidate row the calculation equals the shelf price (nothing to change).
declare v_shelf numeric; c record;
begin
  select retail_sell_price into v_shelf from stock_items where id = p_item;
  select * into c from v_price_rule_candidates where stock_item_id = p_item;
  return jsonb_build_object('shelf', v_shelf,
    'now', case when c.stock_item_id is null then v_shelf else c.proposed_price end,
    'due', c.stock_item_id is not null and c.skip_reason is null and c.lane <> 'never',
    'skip_reason', c.skip_reason);
end $function$;

create or replace function public.price_proposal_staleness(p_id bigint)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
-- pricing-repair-2026-11-28: a pending/approved proposal is out of date when the shelf price it started from has
-- moved, or (for rule-calculated proposals) the rules now give a different price.
declare q retail_price_proposal%rowtype; cur jsonb;
begin
  select * into q from retail_price_proposal where id = p_id;
  if not found then return jsonb_build_object('stale', true, 'reason', 'proposal not found'); end if;
  cur := price_current_calc(q.stock_item_id);
  if round(q.old_price, 2) is distinct from round((cur->>'shelf')::numeric, 2) then
    return cur || jsonb_build_object('stale', true, 'reason', 'shelf price changed', 'was_old', q.old_price, 'was_new', q.proposed_price);
  end if;
  if q.method in ('band', 'passthrough') and round(q.proposed_price, 2) is distinct from round((cur->>'now')::numeric, 2) then
    return cur || jsonb_build_object('stale', true, 'reason', 'calculation changed', 'was_old', q.old_price, 'was_new', q.proposed_price);
  end if;
  return cur || jsonb_build_object('stale', false);
end $function$;

create or replace function public.price_proposal_decide(p_ids bigint[], p_decision text, p_by text default 'Josh'::text)
 returns jsonb
 language plpgsql
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
-- pricing-repair-2026-11-28: an approval is checked first. An out-of-date pending proposal is withdrawn (superseded)
-- and, if a change is still due and no delivery tag job is open for the item, re-queued as a fresh pending proposal.
declare v_n int := 0; q record; s jsonb; c record; res jsonb; v_new bigint; v_stale jsonb := '[]'::jsonb;
begin
  if p_decision not in ('approved','rejected') then
    raise exception 'decision must be approved or rejected';
  end if;
  if p_decision = 'rejected' then
    update retail_price_proposal
       set status = p_decision, decided_at = now(), decided_by = p_by
     where id = any(p_ids) and status = 'pending';
    get diagnostics v_n = row_count;
    return jsonb_build_object('decision', p_decision, 'rows', v_n);
  end if;

  for q in select id, stock_item_id from retail_price_proposal where id = any(p_ids) and status = 'pending' order by stock_item_id, id loop
    perform price_item_lock(q.stock_item_id);
    continue when not exists (select 1 from retail_price_proposal where id = q.id and status = 'pending');
    s := price_proposal_staleness(q.id);
    if not (s->>'stale')::boolean then
      update retail_price_proposal set status = 'approved', decided_at = now(), decided_by = p_by where id = q.id;
      v_n := v_n + 1;
      continue;
    end if;
    update retail_price_proposal
       set status = 'superseded', decided_at = now(), decided_by = left('out of date at approval: ' || p_by, 120),
           skip_reason = left(format('out of date at approval (%s): shelf %s, rules now %s', s->>'reason',
                                     coalesce(s->>'shelf', 'none'), coalesce(s->>'now', 'none')), 200)
     where id = q.id;
    v_new := null;
    if coalesce((s->>'due')::boolean, false)
       and not exists (select 1 from retail_price_proposal x where x.stock_item_id = q.stock_item_id and x.status = 'authorised') then
      select * into c from v_price_rule_candidates where stock_item_id = q.stock_item_id;
      res := price_propose(jsonb_build_object('mode', 'pending', 'item', c.stock_item_id, 'variation', c.square_variation_id,
               'old', c.old_price, 'new', c.proposed_price, 'lane', c.lane, 'method', c.method, 'old_cost', c.anchor_cost,
               'new_cost', c.new_cost, 'cost_pct', c.cost_pct, 'price_pct', c.price_pct, 'cogs_after', c.cogs_pct_after,
               'below_floor', c.below_floor, 'source', 'refresh:' || q.id, 'basis_date', current_date, 'basis_seq', 0));
      if res->>'outcome' = 'pending' then v_new := (res->>'proposal')::bigint; end if;
    end if;
    v_stale := v_stale || jsonb_build_object('id', q.id, 'item', q.stock_item_id, 'reason', s->>'reason',
                 'was_old', s->'was_old', 'was_new', s->'was_new', 'shelf', s->'shelf', 'now', s->'now', 'replaced_by', v_new);
  end loop;
  return jsonb_build_object('decision', p_decision, 'rows', v_n, 'stale', v_stale);
end $function$;

do $a$
declare f text := pg_get_functiondef('public.price_proposal_apply(boolean)'::regprocedure);
begin
  f := pg_temp.patch(f, 'declare r record; res jsonb; v_ok int := 0; v_rows jsonb := ''[]''::jsonb;',
         'declare r record; res jsonb; v_ok int := 0; v_rows jsonb := ''[]''::jsonb; v_s jsonb;');
  f := pg_temp.patch(f, E'     where q.status = ''approved'' order by q.stock_item_id, q.id\n  loop\n',
         E'     where q.status = ''approved'' order by q.stock_item_id, q.id\n  loop\n'
      || E'    -- pricing-repair-2026-11-28: never apply an approval that has gone out of date\n'
      || E'    if not p_dry_run then perform price_item_lock(r.stock_item_id); end if;\n'
      || E'    v_s := price_proposal_staleness(r.id);\n'
      || E'    if (v_s->>''stale'')::boolean then\n'
      || E'      if not p_dry_run then\n'
      || E'        update retail_price_proposal set status = ''skipped'', decided_at = now(),\n'
      || E'               skip_reason = left(format(''out of date at apply (%s): shelf %s, rules now %s'', v_s->>''reason'',\n'
      || E'                                         coalesce(v_s->>''shelf'', ''none''), coalesce(v_s->>''now'', ''none'')), 200)\n'
      || E'         where id = r.id;\n'
      || E'      end if;\n'
      || E'      v_rows := v_rows || jsonb_build_object(''item'', r.name, ''action'', case when p_dry_run then ''would_skip_out_of_date'' else ''skipped_out_of_date'' end,\n'
      || E'                                             ''was'', r.proposed_price, ''now'', v_s->''now'', ''reason'', v_s->>''reason'');\n'
      || E'      continue;\n'
      || E'    end if;\n');
  execute f;
end $a$;

do $d$
declare f text := pg_get_functiondef('public.delivery_price_decide(bigint,text,numeric,text)'::regprocedure);
begin
  f := pg_temp.patch(f, E'  v_ids bigint[]; res jsonb; v_src text; v_bd date; v_bs bigint; v_qid bigint;\n',
         E'  v_ids bigint[]; res jsonb; v_src text; v_bd date; v_bs bigint; v_qid bigint; v_cur jsonb; v_sug numeric;\n');
  f := pg_temp.patch(f, E'    select retail_sell_price into v_old from stock_items where id = t.stock_item_id;\n',
         E'    select retail_sell_price into v_old from stock_items where id = t.stock_item_id;\n'
      || E'    -- pricing-repair-2026-11-28: accepting the job''s suggested price only works while it is still current;\n'
      || E'    -- a price Josh types himself is accepted as typed.\n'
      || E'    v_sug := round((t.info->>''new'')::numeric, 2);\n'
      || E'    if v_sug is not null and (p_price is null or round(p_price, 2) = v_sug) then\n'
      || E'      v_cur := price_current_calc(t.stock_item_id);\n'
      || E'      if (t.info ? ''old'' and round((t.info->>''old'')::numeric, 2) is distinct from round(v_old, 2))\n'
      || E'         or v_sug is distinct from round((v_cur->>''now'')::numeric, 2) then\n'
      || E'        update delivery_tasks set info = info || jsonb_build_object(''old'', v_old, ''new'', (v_cur->>''now'')::numeric, ''refreshed_at'', now())\n'
      || E'         where id = t.id;\n'
      || E'        return jsonb_build_object(''ok'', false, ''code'', ''stale'', ''shelf'', v_old, ''now'', (v_cur->>''now'')::numeric,\n'
      || E'          ''error'', format(''This price is out of date. The shelf price is %s and the price now works out at %s. Check it, then approve again.'',\n'
      || E'                          coalesce(''$'' || to_char(v_old, ''FM999990.00''), ''not set''),\n'
      || E'                          coalesce(''$'' || to_char((v_cur->>''now'')::numeric, ''FM999990.00''), ''not set'')));\n'
      || E'      end if;\n'
      || E'    end if;\n');
  execute f;
end $d$;

-- privileges: new functions are internal (service role only)
do $p$
declare f text;
begin
  foreach f in array array['public.retail_price_for_pack(numeric,numeric,numeric,text,boolean)', 'public.price_current_calc(bigint)',
                           'public.price_proposal_staleness(bigint)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $p$;
