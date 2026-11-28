-- retail_lines_01 — staff jobs for retail waiting invoice lines (Grocer, Gift Store, Garden), 28 Nov 2026.
-- STATUS: STAGED, NOT APPLIED. Contract: docs/retail-lines-contract.md. Tests: db/tests/retail_lines_rollback_test.sql
-- (run inside one transaction that always rolls back; Square is stubbed inside that transaction).
--
-- What it does
--  * New tables delivery_retail_answers (one staff answer per waiting line) and delivery_retail_ops (op_id replay).
--  * delivery_receipts.origin ('photo' | 'invoice_line'): receipts this flow creates for "new product" set-up are kept
--    out of the photo lists (Recent deliveries, New stock recent) but still go through new-stock-setup and Josh's list.
--  * Read: delivery_retail_lines_list(), delivery_retail_search(id, q).  Write: delivery_retail_answer(id, action, body,
--    op_id, by) — the only writer; returns {http, body}.
--  * Patches new_stock_apply (anchored text replacements, each asserted): for lines from this flow only (input has
--    staff_units_per_invoice_unit), the staff-confirmed units per invoice unit and the invoice's ex-GST cost win over the
--    reader's guess; "known" decisions go to Josh instead of mapping silently; a carton code is never used as the shelf
--    barcode or SKU. Photo-flow lines are unaffected (the new keys are absent).
--  * Patches delivery_recent_list to list only origin = 'photo' receipts.
--  * Rev 2 (28 Nov, Codex review): the list is read-only (STABLE; it never requeues anything). A "new" answer records
--    the set-up mode it was made in; a plan made while new-stock set-up was in test mode stays a plan (new_stock_apply
--    forces a dry run for it) until Josh promotes it with delivery_retail_promote (owner key). Lines carry their own
--    department; cards list all departments.
-- Mutations on apply: two new tables (empty), one new column with default, function backups, function replacements.
-- No change to stock, invoices, prices, mappings or Square on apply.
-- Rollback: db/rollback/20261128_retail_lines_01_rollback.sql

-- re-run guard (28 Nov 2026 review): a second run would overwrite the 'pre-retail-lines-2026-11-28' rollback point with
-- this migration's own definitions. The rollback drops delivery_retail_answer, so re-applying after a rollback still works.
do $rerun$ begin
  if to_regprocedure('public.delivery_retail_answer(bigint,text,jsonb,uuid,text)') is not null then
    raise exception 'retail_lines_01 refused: it is already applied (delivery_retail_answer exists). Roll it back first to re-apply.';
  end if;
end $rerun$;

-- 0. backups (restorable with fn_backup_restore(fn, 'pre-retail-lines-2026-11-28'))
insert into public.function_backup (label, fn_name, signature, definition)
select 'pre-retail-lines-2026-11-28', p.proname, p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
   and p.proname in ('new_stock_apply', 'delivery_recent_list');

-- 1. schema
alter table public.delivery_receipts add column if not exists origin text not null default 'photo';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'delivery_receipts_origin_chk') then
    alter table public.delivery_receipts add constraint delivery_receipts_origin_chk check (origin in ('photo', 'invoice_line'));
  end if;
end $$;

create table if not exists public.delivery_retail_answers (
  unmatched_id bigint primary key references public.ingest_unmatched(id),
  action text not null check (action in ('existing', 'new', 'josh')),
  by_name text not null,
  units integer check (units between 1 and 500),
  stock_item_id bigint references public.stock_items(id),
  barcode text,
  no_barcode boolean not null default false,
  name text,
  note text,
  reason text,
  confirmed text[] not null default '{}',
  receipt_id uuid references public.delivery_receipts(id),
  setup_mode text check (setup_mode in ('live', 'dry_run')),
  promoted_at timestamptz,
  promoted_by text,
  promote_op_id uuid unique,
  result jsonb,
  op_id uuid not null unique,
  created_at timestamptz not null default now()
);
create table if not exists public.delivery_retail_ops (
  op_id uuid primary key,
  unmatched_id bigint not null,
  action text not null,
  request_hash text not null,
  response jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.delivery_retail_answers enable row level security;
alter table public.delivery_retail_ops enable row level security;
revoke all on public.delivery_retail_answers, public.delivery_retail_ops from public, anon, authenticated;

-- 2. pure helpers
create or replace function public.delivery_gtin_ok(p text) returns boolean
language sql immutable set search_path to 'public' as $$
  select coalesce(p ~ '^[0-9]+$' and length(p) in (8, 12, 13, 14)
    and (10 - (select sum(substr(lpad(p, 14, '0'), g, 1)::int * case when g % 2 = 1 then 3 else 1 end)
                 from generate_series(1, 13) g) % 10) % 10 = right(p, 1)::int, false)
$$;

-- "(12)" at the end, "6 x 750ml", "ctn 12", "box of 6" -> sellable units per invoice unit as printed
create or replace function public.delivery_retail_printed_pack(p text) returns integer
language sql immutable set search_path to 'public' as $$
  select nullif(coalesce((regexp_match(p, '\((\d{1,3})\)\s*$'))[1],
                         (regexp_match(p, '(\d{1,3})\s*[x×]\s*\d', 'i'))[1],
                         (regexp_match(p, '(?:ctn|carton|case|box|pk|pack|tray)\s*(?:of\s*)?(\d{1,3})\M', 'i'))[1])::int, 0)
$$;

-- a GTIN-14 with indicator 1-8 is a trade unit (carton); its inner item GTIN-13 is digits 2-13 plus a new check digit
create or replace function public.delivery_gtin_inner(p text) returns text
language sql immutable set search_path to 'public' as $$
  select case when p ~ '^[1-8][0-9]{13}$' then
    substr(p, 2, 12) || ((10 - (select sum(substr(substr(p, 2, 12), g, 1)::int * case when g % 2 = 0 then 3 else 1 end)
                                  from generate_series(1, 12) g) % 10) % 10)::text end
$$;

-- 3. which waiting lines belong to this flow
-- suppliers handled by the produce pricing run (Harvey's/Biodynamic): their lines keep their own count jobs on /deliveries
create or replace function public.delivery_retail_produce_suppliers() returns text[]
language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(distinct canonical_supplier(rp.supplier)), '{}')
    from produce_price_runs r join processed_invoices rp on rp.source_id = r.source_id
$$;

create or replace function public.delivery_retail_line_ok(p_unmatched_id bigint, p_produce text[] default null) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from ingest_unmatched u
      join processed_invoices p on 'invoice:' || p.source_id = u.source_tag
     where u.id = p_unmatched_id
       and canonical_department(u.department) in ('Grocer', 'Gift Store', 'Garden')
       and u.qty is not null and u.qty > 0
       and u.description !~ '\[UNRESOLVED UNIT:'
       and not delivery_is_test(p.source_id)
       and coalesce(p.note, '') not like 'DUPLICATE%'
       and not exists (select 1 from delivery_tasks t where t.unmatched_id = u.id)
       and not (canonical_supplier(u.supplier) = any (coalesce(p_produce, delivery_retail_produce_suppliers()))))
$$;

-- generic retail eligibility for "existing"
create or replace function public.delivery_retail_item_eligible(p_unmatched_id bigint, p_stock_item_id bigint) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from ingest_unmatched u join stock_items s on s.id = p_stock_item_id
     where u.id = p_unmatched_id
       and s.department = canonical_department(u.department)
       and s.department in ('Grocer', 'Gift Store', 'Garden')
       and s.archived is not true and s.is_active is not false and s.is_prep is not true
       and exists (select 1 from square_sales_map sm where sm.retail_stock_item_id = s.id and sm.active)
       and (exists (select 1 from supplier_product_map m where m.stock_item_id = s.id and m.supplier = canonical_supplier(u.supplier))
            or not exists (select 1 from supplier_product_map m where m.stock_item_id = s.id
                            and m.supplier is distinct from canonical_supplier(u.supplier))))
$$;

create or replace function public.delivery_retail_facts(p_unmatched_id bigint, p_stock_item_id bigint) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'last_count', (select round(m.pack_grams / nullif(s.grams_per_count_unit, 0), 2) from supplier_product_map m
                    where m.stock_item_id = s.id and m.supplier = canonical_supplier(u.supplier) and m.pack_grams is not null
                    order by m.id desc limit 1),
    'unit_cost_ex', (select round(sp.pack_cost / nullif(sp.pack_grams, 0) * coalesce(nullif(s.grams_per_count_unit, 0), 1), 4)
                       from supplier_prices sp where sp.stock_item_id = s.id and sp.pack_cost > 0 and sp.pack_grams > 0
                      order by sp.effective_from desc nulls last, sp.id desc limit 1),
    'shelf_price', coalesce((select round(vi.price, 2) from square_sales_map sm join square_variation_identity vi on vi.variation_id = sm.square_variation_id
                              where sm.retail_stock_item_id = s.id and sm.active and vi.price > 0 order by sm.id limit 1),
                            s.retail_sell_price),
    'taxable', coalesce((select ss.taxable from square_sync_map ss where ss.stock_item_id = s.id), true),
    'upcs', coalesce((select jsonb_agg(distinct vi.upc) from square_sales_map sm join square_variation_identity vi on vi.variation_id = sm.square_variation_id
                       where sm.retail_stock_item_id = s.id and sm.active and vi.upc is not null), '[]'::jsonb))
    from stock_items s, ingest_unmatched u where s.id = p_stock_item_id and u.id = p_unmatched_id
$$;

create or replace function public.delivery_retail_option(p_unmatched_id bigint, p_stock_item_id bigint) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select o || jsonb_build_object('unit_cost_ex', f->'unit_cost_ex', 'shelf_price', f->'shelf_price',
            'barcode_match', coalesce(delivery_gtin_inner(nullif(regexp_replace(coalesce(u.sku, ''), '\D', '', 'g'), '')) in
                                        (select lpad(x, 13, '0') from jsonb_array_elements_text(f->'upcs') x), false))
    from ingest_unmatched u,
         lateral (select delivery_item_option(p_unmatched_id, p_stock_item_id) o, delivery_retail_facts(p_unmatched_id, p_stock_item_id) f) z
   where u.id = p_unmatched_id
$$;

-- candidates for many lines in one pass: stock-name tokens are matched to invoice-line tokens first (hash joins), and the
-- exact delivery_name_close test, eligibility and option facts run only on that small pool. Plus the carton's inner GTIN.
create or replace function public.delivery_retail_candidates_bulk(p_ids bigint[]) returns table (unmatched_id bigint, candidates jsonb)
language sql stable security definer set search_path to 'public' as $$
  with l as materialized (
    select u.id, regexp_replace(u.description, '\s*\[UNRESOLVED UNIT:[^\]]*\]$', '') d, canonical_department(u.department) dept,
           delivery_gtin_inner(nullif(regexp_replace(coalesce(u.sku, ''), '\D', '', 'g'), '')) inner13
      from ingest_unmatched u where u.id = any (p_ids)),
  dw as materialized (select distinct l.id, w from l, regexp_split_to_table(lower(l.d), '[^a-z]+') w where length(w) >= 3),
  it as materialized (select distinct s.id, s.department, left(w, 4) w4 from stock_items s, regexp_split_to_table(lower(s.name), '[^a-z]+') w
                       where s.department in (select dept from l) and s.archived is not true and length(w) >= 3),
  bc as materialized (select l.id lid, sm.retail_stock_item_id sid from l
                        join square_variation_identity vi on lpad(vi.upc, 13, '0') = l.inner13
                        join square_sales_map sm on sm.square_variation_id = vi.variation_id and sm.active
                       where l.inner13 is not null),
  pool as materialized (
    select dw.id lid, it.id sid from dw join l on l.id = dw.id join it on it.w4 = left(dw.w, 4) and it.department = l.dept
    union
    select dw.id, it.id from dw join l on l.id = dw.id join it on length(dw.w) = 3 and left(it.w4, 3) = dw.w and it.department = l.dept
    union
    select lid, sid from bc),
  ok as materialized (
    select p.lid, p.sid from pool p join l on l.id = p.lid join stock_items s on s.id = p.sid
     where (delivery_name_close(l.d, s.name) or exists (select 1 from bc where bc.lid = p.lid and bc.sid = p.sid))
       and delivery_retail_item_eligible(p.lid, p.sid)),
  opt as (select ok.lid, delivery_retail_option(ok.lid, ok.sid) o from ok)
  select l.id, coalesce((select jsonb_agg(o order by (o->>'barcode_match')::boolean desc, (o->>'supplied_by_this_supplier')::boolean desc, o->>'name')
                           from (select o from opt where opt.lid = l.id
                                  order by (o->>'barcode_match')::boolean desc, (o->>'supplied_by_this_supplier')::boolean desc, o->>'name' limit 10) z), '[]'::jsonb)
    from l
$$;

create or replace function public.delivery_retail_candidates(p_unmatched_id bigint) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select candidates from delivery_retail_candidates_bulk(array[p_unmatched_id])), '[]'::jsonb)
$$;

create or replace function public.delivery_retail_search(p_unmatched_id bigint, p_q text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select case when not delivery_retail_line_ok(p_unmatched_id) then null else
    coalesce((select jsonb_agg(delivery_retail_option(p_unmatched_id, s.id) order by s.name)
                from (select s.id, s.name from stock_items s, ingest_unmatched u
                       where u.id = p_unmatched_id and length(btrim(coalesce(p_q, ''))) >= 2
                         and s.department = canonical_department(u.department)
                         and s.name ilike '%' || replace(replace(btrim(p_q), '%', ''), '_', '') || '%'
                         and delivery_retail_item_eligible(p_unmatched_id, s.id)
                       order by s.name limit 15) s), '[]') end
$$;

-- 4. one line as the app sees it
create or replace function public.delivery_retail_line_json(p_unmatched_id bigint, p_with_candidates boolean default true) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare u ingest_unmatched; a delivery_retail_answers; v_status text; v_note text; n record; v_rs text; v_promo boolean := false;
  v_mode text := coalesce((select value from app_config where key = 'new_stock_mode'), 'dry_run');
begin
  select * into u from ingest_unmatched where id = p_unmatched_id;
  select * into a from delivery_retail_answers where unmatched_id = p_unmatched_id;
  if u.resolved_at is not null then
    v_status := 'done';
    v_note := case when a.action is null then 'Booked outside the app.' end;
  elsif a.action is null then
    v_status := 'open';
  elsif a.action = 'josh' then
    v_status := 'with_josh'; v_note := 'Sent to Josh.';
  elsif a.action = 'existing' then
    v_status := 'with_josh'; v_note := 'Matched, but the booking did not finish. Josh to check.';
  else
    select r.setup_status into v_rs from delivery_receipts r where r.id = a.receipt_id;
    select l.status, l.note into n from new_stock_lines l where l.receipt_id = a.receipt_id order by l.line_no limit 1;
    -- a plan made in test mode is never turned into a real product by itself
    v_promo := a.setup_mode = 'dry_run' and a.promoted_at is null and v_mode = 'live';
    if v_promo then
      v_status := 'with_josh'; v_note := 'Planned while product set-up was in test mode. Josh needs to approve creating it.';
    elsif n.status in ('needs_josh', 'failed', 'square_created') then
      v_status := 'with_josh'; v_note := coalesce(n.note, 'Set-up needs Josh.');
    elsif n.status = 'dry_run' or v_rs = 'dry_run' then
      v_status := 'setting_up'; v_note := 'Test mode: planned, not created in Square yet.';
    elsif n.status in ('created', 'known', 'skipped') then
      v_status := 'with_josh';
      v_note := case when n.status = 'skipped' then 'Set-up says this is not stock. Josh to check.'
                     else 'Product set up, but the invoice line did not book. Josh to check.' end;
    else
      v_status := 'setting_up'; v_note := 'Being set up.';
    end if;
  end if;
  return jsonb_build_object(
    'unmatched_id', u.id,
    'department', canonical_department(u.department),
    'needs_promotion', v_promo,
    'description', regexp_replace(u.description, '\s*\[UNRESOLVED UNIT:[^\]]*\]$', ''),
    'qty', u.qty, 'unit', u.unit,
    'invoice_unit_cost_ex', round(u.unit_price, 4),
    'printed_pack', delivery_retail_printed_pack(u.description),
    'carton_code', nullif(btrim(u.sku), ''),
    'status', v_status, 'status_note', v_note,
    'answer', case when a.action is null then null else jsonb_strip_nulls(jsonb_build_object(
                'action', a.action, 'by', a.by_name, 'at', a.created_at, 'units', a.units, 'stock_item_id', a.stock_item_id,
                'name', coalesce(a.name, (select s.name from stock_items s where s.id = a.stock_item_id)),
                'barcode', a.barcode, 'no_barcode', a.no_barcode, 'reason', a.reason, 'confirmed', to_jsonb(a.confirmed))) end,
    'candidates', case when v_status = 'open' and p_with_candidates then delivery_retail_candidates(u.id) end);
end $$;

-- 5. list — read-only (STABLE: the database refuses any write from it)
create or replace function public.delivery_retail_lines_list() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_mode text := coalesce((select value from app_config where key = 'new_stock_mode'), 'dry_run');
  v_produce text[] := delivery_retail_produce_suppliers(); v_cards jsonb;
begin
  with ids as (
         select u.id from ingest_unmatched u
           join processed_invoices p on 'invoice:' || p.source_id = u.source_tag
           left join delivery_retail_answers a on a.unmatched_id = u.id
          where p.invoice_date >= current_date - 30
            and (u.resolved_at is null or u.resolved_at > now() - interval '48 hours' or a.created_at > now() - interval '48 hours')
            and delivery_retail_line_ok(u.id, v_produce)),
       lines as materialized (select ids.id, delivery_retail_line_json(ids.id, false) l from ids),
       cand as materialized (select * from delivery_retail_candidates_bulk(coalesce((select array_agg(id) from lines where l->>'status' = 'open'), '{}'))),
       full_lines as (select lines.id, case when cand.unmatched_id is null then lines.l else lines.l || jsonb_build_object('candidates', cand.candidates) end l
                        from lines left join cand on cand.unmatched_id = lines.id)
  select jsonb_agg(c order by c->>'invoice_date' desc, c->>'supplier', c->>'source_id') into v_cards from (
    select jsonb_build_object(
             'source_id', p.source_id, 'supplier', canonical_supplier(p.supplier), 'invoice_number', p.invoice_number,
             'invoice_date', p.invoice_date,
             'department', case when count(distinct canonical_department(u.department)) = 1 then canonical_department(min(u.department)) end,
             'departments', to_jsonb(array_agg(distinct canonical_department(u.department) order by canonical_department(u.department))),
             'open', count(*) filter (where r.l->>'status' = 'open'),
             'lines', jsonb_agg(r.l order by u.id)) c
      from full_lines r
      join ingest_unmatched u on u.id = r.id
      join processed_invoices p on 'invoice:' || p.source_id = u.source_tag
     group by p.source_id, p.supplier, p.invoice_number, p.invoice_date) z;
  return jsonb_build_object('new_stock_mode', v_mode, 'cards', coalesce(v_cards, '[]'::jsonb));
end $$;

-- 6. the only writer
create or replace function public.delivery_retail_answer(p_unmatched_id bigint, p_action text, p_body jsonb, p_op_id uuid, p_by text)
returns jsonb language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp' as $$
declare
  u ingest_unmatched; a delivery_retail_answers; op delivery_retail_ops; p processed_invoices; s stock_items;
  v_body jsonb := coalesce(p_body, '{}'::jsonb) - 'op_id' - 'by';
  v_hash text; v_by text := btrim(coalesce(p_by, '')); v_units int; v_confirm text[]; v_checks jsonb := '[]'; v_soft text[] := '{}';
  v_printed int; v_facts jsonb; v_cost numeric; v_shelf_ex numeric; v_barcode text; v_carton text; v_hit text;
  v_item bigint; v_map jsonb; v_receipt uuid; v_resp jsonb; v_line jsonb; v_name text; v_note text; v_reason text;
  v_mode text := case when (select value from app_config where key = 'new_stock_mode') = 'live' then 'live' else 'dry_run' end;
begin
  if p_op_id is null then return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'invalid', 'error', 'Missing op_id.')); end if;
  if p_action not in ('existing', 'new', 'josh') then return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'invalid', 'error', 'Unknown action.')); end if;
  v_hash := md5(p_action || ':' || p_unmatched_id || ':' || v_by || ':' || v_body::text);

  -- serialise everything for this line
  select * into u from ingest_unmatched where id = p_unmatched_id for update;
  if not found or not delivery_retail_line_ok(p_unmatched_id) then
    return jsonb_build_object('http', 404, 'body', jsonb_build_object('ok', false, 'code', 'not_found', 'error', 'This line is not a retail waiting line.'));
  end if;

  -- op replay / conflict (a different line's op_id is a conflict too)
  select * into op from delivery_retail_ops where op_id = p_op_id;
  if found then
    if op.request_hash = v_hash then
      return jsonb_build_object('http', 200, 'body', op.response || jsonb_build_object('replayed', true, 'line', delivery_retail_line_json(p_unmatched_id)));
    end if;
    return jsonb_build_object('http', 409, 'body', jsonb_build_object('ok', false, 'code', 'op_conflict',
      'error', 'This action was already sent with different details.', 'line', delivery_retail_line_json(p_unmatched_id)));
  end if;

  select * into a from delivery_retail_answers where unmatched_id = p_unmatched_id;
  if found or u.resolved_at is not null then
    return jsonb_build_object('http', 409, 'body', jsonb_build_object('ok', false, 'code', 'already_answered',
      'error', 'Someone has already dealt with this line.', 'line', delivery_retail_line_json(p_unmatched_id)));
  end if;

  -- common validation
  if v_by = '' or not (v_by = any (select btrim(x) from regexp_split_to_table(coalesce((select value from app_config where key = 'delivery_staff_names'), ''), ',') x)) then
    return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'invalid', 'error', 'Pick your name first.'));
  end if;
  begin
    v_confirm := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(v_body->'confirm', '[]')) x), '{}');
  exception when others then
    return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'invalid', 'error', 'confirm must be a list.'));
  end;
  select * into p from processed_invoices where 'invoice:' || source_id = u.source_tag;

  if p_action = 'josh' then
    v_reason := btrim(coalesce(v_body->>'reason', ''));
    if length(v_reason) not between 1 and 300 then
      return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'invalid', 'error', 'Say in a few words what Josh needs to know.'));
    end if;
    insert into delivery_retail_answers (unmatched_id, action, by_name, reason, op_id) values (u.id, 'josh', v_by, v_reason, p_op_id);
    insert into engine_runs (steps_ok, steps_failed, notes)
    values (1, 0, left(format('DELIVERY-APP retail line to Josh by %s: %s (%s)', v_by, u.description, v_reason), 500));

  else
    -- units: sellable units in ONE invoice unit
    if jsonb_typeof(v_body->'units') is distinct from 'number' or (v_body->>'units')::numeric <> trunc((v_body->>'units')::numeric)
       or (v_body->>'units')::numeric not between 1 and 500 then
      return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'invalid', 'error', 'Enter how many you can sell from one invoice unit (1 to 500).'));
    end if;
    v_units := (v_body->>'units')::int;
    v_printed := delivery_retail_printed_pack(u.description);
    if v_printed is not null and v_units <> v_printed then
      v_soft := array_append(v_soft, 'printed_pack_differs');
      v_checks := v_checks || jsonb_build_object('code', 'printed_pack_differs', 'soft', true,
        'message', format('The invoice shows %s in each, you entered %s. Count one carton again.', v_printed, v_units));
    end if;
    v_carton := nullif(regexp_replace(coalesce(u.sku, ''), '\D', '', 'g'), '');

    if p_action = 'existing' then
      -- a whole positive number only: a fraction would make the ::bigint cast raise, which the app reports as "uncertain"
      -- and asks staff to retry forever (28 Nov review)
      if jsonb_typeof(v_body->'stock_item_id') is distinct from 'number'
         or (v_body->>'stock_item_id')::numeric <> trunc((v_body->>'stock_item_id')::numeric)
         or (v_body->>'stock_item_id')::numeric < 1 then
        return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'invalid', 'error', 'Pick the product.'));
      end if;
      v_item := (v_body->>'stock_item_id')::bigint;
      if not delivery_retail_item_eligible(u.id, v_item) then
        return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'not_eligible',
          'error', 'That product can''t be used for this supplier or department. Search again or choose "It''s a new product".'));
      end if;
      select * into s from stock_items where id = v_item;
      v_facts := delivery_retail_facts(u.id, v_item);
      if (v_facts->>'last_count') is not null and abs(v_units - (v_facts->>'last_count')::numeric) > 0.5 * (v_facts->>'last_count')::numeric then
        v_soft := array_append(v_soft, 'count_differs');
        v_checks := v_checks || jsonb_build_object('code', 'count_differs', 'soft', true,
          'message', format('Last time this supplier''s carton had %s. You entered %s.', (v_facts->>'last_count')::numeric, v_units));
      end if;
      if u.unit_price is not null then
        v_cost := u.unit_price / v_units;
        v_shelf_ex := (v_facts->>'shelf_price')::numeric / case when coalesce((v_facts->>'taxable')::boolean, true) then 1.1 else 1 end;
        if v_shelf_ex > 0 and v_cost >= v_shelf_ex then
          v_soft := array_append(v_soft, 'cost_above_shelf');
          v_checks := v_checks || jsonb_build_object('code', 'cost_above_shelf', 'soft', true,
            'message', format('That makes each one cost $%s, more than its shelf price. Is it really %s per carton?', round(v_cost, 2), v_units));
        elsif (v_facts->>'unit_cost_ex')::numeric > 0 and (v_cost < 0.5 * (v_facts->>'unit_cost_ex')::numeric or v_cost > 2 * (v_facts->>'unit_cost_ex')::numeric) then
          v_soft := array_append(v_soft, 'cost_differs');
          v_checks := v_checks || jsonb_build_object('code', 'cost_differs', 'soft', true,
            'message', format('That makes each one cost $%s; last time it was $%s. Check the count and the product.', round(v_cost, 2), round((v_facts->>'unit_cost_ex')::numeric, 2)));
        end if;
      end if;
    else -- new
      v_barcode := nullif(regexp_replace(coalesce(v_body->>'barcode', ''), '\s', '', 'g'), '');
      v_name := nullif(btrim(coalesce(v_body->>'name', '')), '');
      v_note := nullif(btrim(coalesce(v_body->>'note', '')), '');
      if length(coalesce(v_name, '')) > 120 or length(coalesce(v_note, '')) > 300 then
        return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'invalid', 'error', 'Name or note is too long.'));
      end if;
      if v_barcode is not null then
        if not delivery_gtin_ok(v_barcode) then
          return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'barcode_invalid', 'error', 'That barcode didn''t scan properly. Scan it again.'));
        end if;
        if (v_carton is not null and lpad(v_barcode, 14, '0') = lpad(v_carton, 14, '0')) or v_barcode ~ '^[1-9][0-9]{13}$' then  -- 1-8 trade units, 9 variable-measure (28 Nov review)
          return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'carton_barcode',
            'error', 'That is the carton''s barcode. Scan the barcode on one item you would sell.'));
        end if;
        select vi.item_name || case when coalesce(nullif(btrim(vi.variation_name), ''), 'Regular') <> 'Regular' then ' – ' || vi.variation_name else '' end
          into v_hit from square_variation_identity vi
         where lpad(vi.upc, 14, '0') = lpad(v_barcode, 14, '0') and vi.is_archived is not true limit 1;
        if v_hit is not null then
          return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'barcode_known',
            'error', format('That barcode is already "%s". Choose "It''s something we already sell".', v_hit), 'product', v_hit));
        end if;
      elsif canonical_department(u.department) = 'Grocer' and not (coalesce(v_body->'no_barcode' = 'true'::jsonb, false) and v_note is not null) then
        return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'barcode_required',
          'error', 'Scan the barcode on one item. If it has none, tick "No barcode" and say why.'));
      end if;
    end if;

    -- soft checks: each must be confirmed
    if exists (select 1 from unnest(v_soft) c where not (c = any (v_confirm))) then
      return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'needs_confirm',
        'error', 'Check this before saving.', 'checks', v_checks));
    end if;

    if p_action = 'existing' then
      -- Siblings (28 Nov 2026 review): map_unmatched also books every other open line of this supplier with the identical
      -- description, on any invoice. Lock them (id order), and refuse while any of them already has a 'new' answer: booking
      -- it here would attach that line to this product while its own set-up may still create a separate Square product.
      perform 1 from ingest_unmatched x
       where x.id <> u.id and x.resolved_at is null and x.description = u.description
         and canonical_supplier(x.supplier) = canonical_supplier(u.supplier)
       order by x.id for update;
      if exists (select 1 from ingest_unmatched x join delivery_retail_answers ra on ra.unmatched_id = x.id
                  where x.id <> u.id and x.resolved_at is null and x.description = u.description
                    and canonical_supplier(x.supplier) = canonical_supplier(u.supplier) and ra.action = 'new') then
        return jsonb_build_object('http', 409, 'body', jsonb_build_object('ok', false, 'code', 'sibling_in_setup',
          'error', 'The same product on another delivery is already being set up as a new product. Wait until it is in Square, then match this line to it, or send this line to Josh.',
          'line', delivery_retail_line_json(p_unmatched_id)));
      end if;
      begin  -- savepoint: the mapping is undone if this line does not book
        v_map := map_unmatched(u.id, v_item, v_units * coalesce(nullif(s.grams_per_count_unit, 0), 1), null, null, false, null);
        if coalesce(v_map->>'status', '') <> 'mapped' or not exists (select 1 from ingest_unmatched x where x.id = u.id and x.resolved_at is not null) then
          raise exception 'retail-line-not-booked';
        end if;
      exception when others then
        return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'booking_failed',
          'error', 'It couldn''t be booked. Nothing was changed. Send it to Josh.', 'detail', coalesce(v_map, jsonb_build_object('error', sqlerrm))));
      end;
      insert into delivery_retail_answers (unmatched_id, action, by_name, units, stock_item_id, confirmed, result, op_id)
      values (u.id, 'existing', v_by, v_units, v_item, coalesce((select array_agg(c) from unnest(v_soft) c), '{}'), v_map, p_op_id);
      insert into engine_runs (steps_ok, steps_failed, notes)
      values (1, 0, left(format('DELIVERY-APP retail line matched by %s: %s -> %s, %s per invoice unit; booked %s',
                                v_by, u.description, s.name, v_units, v_map->>'lines_booked_with_stock'), 500));
    else
      v_receipt := p_op_id;  -- deterministic: one receipt per op
      insert into delivery_receipts (id, source_id, supplier, department, status, origin, photo_paths, submitted_at, setup_status,
                                     staff_edits, submitted_lines, confirmed_payload)
      values (v_receipt, 'retail-line:' || u.id, canonical_supplier(u.supplier), canonical_department(u.department), 'submitted', 'invoice_line',
              '{}', now(), 'pending',
              jsonb_build_object('invoice_number', p.invoice_number, 'invoice_date', coalesce(u.invoice_date, p.invoice_date),
                                 'origin', 'invoice_line', 'unmatched_id', u.id, 'by', v_by),
              jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                'description', coalesce(v_name, regexp_replace(u.description, '\s*\[UNRESOLVED UNIT:[^\]]*\]$', '')),
                'invoice_description', regexp_replace(u.description, '\s*\[UNRESOLVED UNIT:[^\]]*\]$', ''),
                'qty', u.qty, 'unit', u.unit, 'unit_price', u.unit_price, 'source', 'invoice',
                'barcode', v_barcode, 'carton_code', v_carton,
                'staff_units_per_invoice_unit', v_units, 'invoice_unit_cost_ex', u.unit_price, 'planned_in_mode', v_mode,
                'note', trim(both ' ' from concat_ws(' ', format('Staff counted %s sellable units per invoice unit (unit_price is ex GST per invoice unit).', v_units),
                                                       case when v_carton is not null then 'The code on the invoice line is the carton code, not the shelf barcode.' end,
                                                       case when coalesce(v_body->'no_barcode' = 'true'::jsonb, false) then 'Item has no barcode.' end, v_note))))),
              jsonb_build_object('origin', 'invoice_line', 'op_id', p_op_id));
      insert into delivery_retail_answers (unmatched_id, action, by_name, units, barcode, no_barcode, name, note, confirmed, receipt_id, setup_mode, op_id)
      values (u.id, 'new', v_by, v_units, v_barcode, coalesce(v_body->'no_barcode' = 'true'::jsonb, false), v_name, v_note,
              coalesce((select array_agg(c) from unnest(v_soft) c), '{}'), v_receipt, v_mode, p_op_id);
      insert into engine_runs (steps_ok, steps_failed, notes)
      values (1, 0, left(format('NEW-STOCK-APP submitted source=retail-line:%s supplier=%s dept=%s lines=1 (from invoice line, by %s)',
                                u.id, canonical_supplier(u.supplier), canonical_department(u.department), v_by), 500));
    end if;
  end if;

  v_line := delivery_retail_line_json(u.id, false);
  v_resp := jsonb_build_object('ok', true, 'status', v_line->>'status', 'receipt_id', v_receipt);
  insert into delivery_retail_ops (op_id, unmatched_id, action, request_hash, response) values (p_op_id, u.id, p_action, v_hash, v_resp);
  return jsonb_build_object('http', 200, 'body', v_resp || jsonb_build_object('line', v_line));
end $$;

-- 6b. explicit promotion of a test-mode plan (owner key only, via the Edge owner route). Requires set-up to be live.
create or replace function public.delivery_retail_promote(p_unmatched_id bigint, p_op_id uuid, p_by text default 'Josh')
returns jsonb language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare u ingest_unmatched; a delivery_retail_answers; v_resp jsonb; v_line jsonb;
begin
  if p_op_id is null then return jsonb_build_object('http', 400, 'body', jsonb_build_object('ok', false, 'code', 'invalid', 'error', 'Missing op_id.')); end if;
  select * into u from ingest_unmatched where id = p_unmatched_id for update;
  select * into a from delivery_retail_answers where unmatched_id = p_unmatched_id for update;
  if u.id is null or a.unmatched_id is null or a.action <> 'new' or a.setup_mode is distinct from 'dry_run' then
    return jsonb_build_object('http', 404, 'body', jsonb_build_object('ok', false, 'code', 'not_found', 'error', 'No test-mode plan for this line.'));
  end if;
  if a.promoted_at is not null then
    if a.promote_op_id = p_op_id then
      return jsonb_build_object('http', 200, 'body', jsonb_build_object('ok', true, 'replayed', true, 'receipt_id', a.receipt_id,
                                'status', (delivery_retail_line_json(u.id, false))->>'status', 'line', delivery_retail_line_json(u.id, false)));
    end if;
    return jsonb_build_object('http', 409, 'body', jsonb_build_object('ok', false, 'code', 'already_answered',
                              'error', 'Already approved.', 'line', delivery_retail_line_json(u.id, false)));
  end if;
  if u.resolved_at is not null then
    return jsonb_build_object('http', 409, 'body', jsonb_build_object('ok', false, 'code', 'already_answered',
                              'error', 'This line is already booked.', 'line', delivery_retail_line_json(u.id, false)));
  end if;
  if coalesce((select value from app_config where key = 'new_stock_mode'), 'dry_run') <> 'live' then
    return jsonb_build_object('http', 409, 'body', jsonb_build_object('ok', false, 'code', 'setup_test_mode',
                              'error', 'Product set-up is still in test mode, so nothing can be created yet.', 'line', delivery_retail_line_json(u.id, false)));
  end if;
  update delivery_receipts set submitted_lines = jsonb_set(submitted_lines, '{0,promoted}', 'true'::jsonb), setup_status = 'pending'
   where id = a.receipt_id;
  update new_stock_lines set input = input || '{"promoted": true}'::jsonb,
         status = case when status = 'dry_run' then 'pending' else status end,
         result = case when status = 'dry_run' then null else result end,
         price = case when status = 'dry_run' then null else price end,
         sku = case when status = 'dry_run' then null else sku end,
         awaiting_price = case when status = 'dry_run' then false else awaiting_price end
   where receipt_id = a.receipt_id;
  update delivery_retail_answers set promoted_at = now(), promoted_by = left(coalesce(nullif(btrim(p_by), ''), 'Josh'), 40), promote_op_id = p_op_id
   where unmatched_id = u.id;
  insert into engine_runs (steps_ok, steps_failed, notes)
  values (1, 0, left(format('DELIVERY-APP retail line test-mode plan approved by %s: %s (receipt %s)', coalesce(p_by, 'Josh'), u.description, a.receipt_id), 500));
  v_line := delivery_retail_line_json(u.id, false);
  return jsonb_build_object('http', 200, 'body', jsonb_build_object('ok', true, 'status', v_line->>'status', 'receipt_id', a.receipt_id, 'line', v_line));
end $$;

-- 7. new_stock_apply: staff-confirmed units/cost, no silent "known", carton code never a shelf code
do $$
declare d text := pg_get_functiondef('public.new_stock_apply(bigint, boolean)'::regprocedure); o text;
begin
  o := d;
  d := replace(d, $a$  d := coalesce(l.decision, '{}'); i := l.input;$a$, $a$  d := coalesce(l.decision, '{}'); i := l.input;
  -- retail waiting lines (28 Nov 2026): a plan made while set-up was in test mode stays a plan until Josh promotes it
  if i->>'planned_in_mode' = 'dry_run' and not coalesce((i->>'promoted')::boolean, false) then p_dry_run := true; end if;$a$);
  if d = o then raise exception 'new_stock_apply patch 0 (test-mode plan guard) did not apply'; end if;
  o := d;
  d := replace(d, $a$  if v_action = 'known' then
    v_known := $a$, $a$  if v_action = 'known' and i ? 'staff_units_per_invoice_unit' then
    -- retail waiting lines (28 Nov 2026): staff said "new"; an existing-product match is Josh's call, not a silent mapping
    update new_stock_lines set status = 'needs_josh',
           note = 'Staff said this is a new product, but set-up thinks it is an existing one (stock item ' || coalesce(d->>'existing_stock_item_id', '?') || '). Josh to check.'
     where id = l.id;
    return jsonb_build_object('ok', true, 'status', 'needs_josh', 'why', 'staff_new_but_known');
  end if;

  if v_action = 'known' then
    v_known := $a$);
  if d = o then raise exception 'new_stock_apply patch 1 (known guard) did not apply'; end if;
  o := d;
  d := replace(d, $a$  v_units := coalesce(nullif(d->>'units_per_invoice_unit', '')::numeric, 1);
  v_cost_ex := nullif(d->>'unit_cost_ex', '')::numeric;$a$,
    $a$  v_units := coalesce(nullif(i->>'staff_units_per_invoice_unit', '')::numeric, nullif(d->>'units_per_invoice_unit', '')::numeric, 1);
  v_cost_ex := coalesce(round(nullif(i->>'invoice_unit_cost_ex', '')::numeric / nullif(nullif(i->>'staff_units_per_invoice_unit', '')::numeric, 0), 4),
                        nullif(d->>'unit_cost_ex', '')::numeric);$a$);
  if d = o then raise exception 'new_stock_apply patch 2 (staff units/cost) did not apply'; end if;
  o := d;
  d := replace(d, $a$  if v_upc is not null and length(v_upc) not between 8 and 14 then v_upc := null; end if;$a$,
    $a$  if v_upc is not null and length(v_upc) not between 8 and 14 then v_upc := null; end if;
  -- a carton (trade unit) code is never the shelf barcode
  if v_upc is not null and (v_upc ~ '^[1-9][0-9]{13}$'
       or lpad(v_upc, 14, '0') = lpad(nullif(regexp_replace(coalesce(i->>'carton_code', ''), '\D', '', 'g'), ''), 14, '0')) then
    v_upc := nullif(regexp_replace(coalesce(i->>'barcode', ''), '\D', '', 'g'), '');
    if v_upc is not null and (v_upc ~ '^[1-9][0-9]{13}$' or length(v_upc) not between 8 and 14) then v_upc := null; end if;
  end if;$a$);
  if d = o then raise exception 'new_stock_apply patch 3 (carton upc) did not apply'; end if;
  o := d;
  d := replace(d, $a$  if v_sku is not null and v_sku is distinct from v_upc and exists (select 1 from square_variation_identity where sku = v_sku and is_archived is not true) then$a$,
    $a$  if v_sku is not null and nullif(regexp_replace(coalesce(i->>'carton_code', ''), '\D', '', 'g'), '') is not null
     and lpad(regexp_replace(v_sku, '\D', '', 'g'), 14, '0') = lpad(regexp_replace(i->>'carton_code', '\D', '', 'g'), 14, '0') then
    v_sku := coalesce(v_upc, new_stock_next_sku(v_sup, case when v_action = 'new_variation' then d->>'square_item_id' end));
  end if;
  if v_sku is not null and v_sku is distinct from v_upc and exists (select 1 from square_variation_identity where sku = v_sku and is_archived is not true) then$a$);
  if d = o then raise exception 'new_stock_apply patch 4 (carton sku) did not apply'; end if;
  execute d;
end $$;

-- 8. delivery_recent_list: photo receipts only
do $$
declare d text := pg_get_functiondef('public.delivery_recent_list(text)'::regprocedure); o text;
begin
  o := d;
  d := replace(d, $a$where not coalesce(r.is_fixture, false) and r.status <> 'cancelled'$a$,
                  $a$where not coalesce(r.is_fixture, false) and r.status <> 'cancelled' and r.origin = 'photo'$a$);
  if d = o then raise exception 'delivery_recent_list patch did not apply'; end if;
  execute d;
end $$;

-- 9. privileges: service role only (delivery_app_selfcheck covers delivery_% functions)
do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('delivery_gtin_ok', 'delivery_retail_printed_pack', 'delivery_gtin_inner', 'delivery_retail_line_ok',
                                'delivery_retail_produce_suppliers', 'delivery_retail_candidates_bulk',
                                'delivery_retail_item_eligible', 'delivery_retail_facts', 'delivery_retail_option', 'delivery_retail_candidates',
                                'delivery_retail_search', 'delivery_retail_line_json', 'delivery_retail_lines_list', 'delivery_retail_answer',
                                'delivery_retail_promote')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
