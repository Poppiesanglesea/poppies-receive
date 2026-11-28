-- retail_lines_01 integration test — ROLLED BACK. 28 Nov 2026.
-- Run as ONE query, appended after db/migrations/20261128_retail_lines_01.sql:
--   cat db/migrations/20261128_retail_lines_01.sql db/tests/retail_lines_rollback_test.sql | <one execute_sql call>
-- The last statement always raises 'RL-RESULTS {...}', so the migration, fixtures and every write roll back together
-- (verified separately: a table created in the same query does not survive). Square is replaced by a stub inside
-- the transaction; the real square_api is never reached. Fixtures are synthetic (no business data).
-- After running, check nothing is left: db/tests/retail_lines_residue_check.sql

create temp table rl_t (n serial, name text, ok boolean, detail text) on commit drop;
create temp table rl_square (id serial, method text, path text, body jsonb) on commit drop;
create function pg_temp.ck(p_name text, p_ok boolean, p_detail text default null) returns void language sql
  as $$ insert into rl_t (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;

-- Square stub (transaction-local definition; rolled back)
create or replace function public.square_api(p_method text, p_path text, p_body jsonb default null) returns jsonb
language plpgsql as $$
declare k text := md5(coalesce(p_body->>'idempotency_key', random()::text));
begin
  insert into rl_square (method, path, body) values (p_method, p_path, p_body);
  if p_path = '/v2/catalog/object' and p_body->'object'->>'type' = 'ITEM' then
    return jsonb_build_object('status', 200, 'body', jsonb_build_object('catalog_object', jsonb_build_object('id', 'RLITEM' || k,
             'item_data', jsonb_build_object('variations', jsonb_build_array(jsonb_build_object('id', 'RLVAR' || k))))));
  elsif p_path = '/v2/catalog/object' then
    return jsonb_build_object('status', 200, 'body', jsonb_build_object('catalog_object', jsonb_build_object('id', 'RLVAR' || k)));
  end if;
  return jsonb_build_object('status', 200, 'body', '{}'::jsonb);
end $$;

do $T$
declare
  SUP constant text := 'Retail Test Supplier RL'; OTHER constant text := 'Retail Other Supplier RL';
  who text := btrim(split_part((select value from app_config where key = 'delivery_staff_names'), ',', 1));
  base12 text := '930000000101'; inner13 text; carton text; carton2 text; good13 text; known13 text;
  a bigint; b bigint; c bigint; k bigint; u1 bigint; u2 bigint; u3 bigint; u4 bigint; u5 bigint; u6 bigint; u7 bigint; u8 bigint;
  r jsonb; r2 jsonb; l jsonb; cards jsonb; op1 uuid := gen_random_uuid(); op2 uuid := gen_random_uuid(); op3 uuid := gen_random_uuid();
  n int; n2 int; v_cat text; v_line bigint; v_receipt uuid; d text; photo_before int; si bigint; t0 timestamptz;
begin
  -- ---------- fixtures
  inner13 := delivery_gtin_inner('1' || base12 || '0');           -- inner GTIN-13 of the carton (check digit recomputed)
  for i in 0..9 loop if delivery_gtin_ok('1' || base12 || i) then carton := '1' || base12 || i; end if; end loop;
  for i in 0..9 loop if delivery_gtin_ok('19300000002' || '05' || i) then carton2 := '19300000002' || '05' || i; end if; end loop;
  for i in 0..9 loop if delivery_gtin_ok('930000000999' || i) then good13 := '930000000999' || i; end if; end loop;
  for i in 0..9 loop if delivery_gtin_ok('930000000888' || i) then known13 := '930000000888' || i; end if; end loop;
  perform pg_temp.ck('fixture: GTIN helpers', delivery_gtin_ok(carton) and delivery_gtin_ok(inner13) and delivery_gtin_ok(good13)
                     and delivery_gtin_ok('4006381333931') and not delivery_gtin_ok('4006381333932') and delivery_gtin_inner(carton) = inner13
                     and delivery_gtin_ok(delivery_gtin_inner(carton2)) and delivery_gtin_inner('4006381333931') is null,
                     format('carton %s inner %s', carton, inner13));

  insert into stock_items (name, department, count_unit, grams_per_count_unit, is_active, archived, is_prep, track_stock, inventory_mode, retail_sell_price)
  values ('RLTest Crackers Original', 'Grocer', 'each', 1, true, false, false, true, 'scan', 8.50) returning id into a;
  insert into stock_items (name, department, count_unit, grams_per_count_unit, is_active, archived, is_prep, track_stock, inventory_mode)
  values ('RLTest Crackers Other Supplier', 'Grocer', 'each', 1, true, false, false, true, 'scan') returning id into b;
  insert into stock_items (name, department, count_unit, grams_per_count_unit, is_active, archived, is_prep, track_stock, inventory_mode)
  values ('RLTest Crackers Archived', 'Grocer', 'each', 1, false, true, false, true, 'scan') returning id into c;
  insert into stock_items (name, department, count_unit, grams_per_count_unit, is_active, archived, is_prep, track_stock)
  values ('RLTest Crackers Kitchen', 'Cafe', 'each', 1, true, false, false, true) returning id into k;
  insert into square_variation_identity (variation_id, item_id, item_name, variation_name, upc, price, is_archived)
  values ('RLVAR-A', 'RLITEM-A', 'RLTest Crackers', 'Original', inner13, 8.5, false),
         ('RLVAR-B', 'RLITEM-B', 'RLTest Crackers', 'Other', known13, 9.0, false),
         ('RLVAR-C', 'RLITEM-C', 'RLTest Crackers', 'Archived', null, 9.0, false);
  insert into square_sales_map (square_variation_id, square_item_name, square_variation_name, retail_stock_item_id, retail_units_base, size, active)
  values ('RLVAR-A', 'RLTest Crackers', 'Original', a, 1, 'regular', true), ('RLVAR-B', 'RLTest Crackers', 'Other', b, 1, 'regular', true),
         ('RLVAR-C', 'RLTest Crackers', 'Archived', c, 1, 'regular', true);
  insert into supplier_product_map (supplier, match_text, stock_item_id, pack_grams, department) values
    (SUP, 'RLTEST OLD WORDING CRACKERS', a, 8, 'Grocer'), (OTHER, 'RLTEST OTHER CRACKERS', b, 6, 'Grocer');
  insert into supplier_prices (stock_item_id, supplier, pack_label, pack_grams, pack_cost, effective_from, is_preferred, needs_review)
  values (a, SUP, 'carton', 8, 16, current_date - 60, true, false);   -- 2.00 each

  insert into processed_invoices (source_id, supplier, invoice_number, invoice_date, department, line_count, booked_count, unmatched_count) values
    ('RLTEST-1', SUP, 'RL-INV-1', current_date - 2, 'Grocer', 6, 0, 6), ('RLTEST-2', SUP, 'RL-INV-2', current_date - 1, 'Grocer', 1, 0, 1),
    ('RLTEST-3', SUP, 'RL-INV-3', current_date - 1, 'Gift Store', 1, 0, 1), ('RLTEST-4', SUP, 'RL-INV-4', current_date - 1, 'Cafe', 1, 0, 1);
  insert into ingest_unmatched (supplier, description, unit_price, invoice_date, qty, unit, source_tag, sku, department, seen_at) values
    (SUP, 'RLTest Crackers Original 250g (8)', 24, current_date - 2, 2, null, 'invoice:RLTEST-1', carton, 'Grocer', now()) returning id into u1;
  insert into ingest_unmatched (supplier, description, unit_price, invoice_date, qty, unit, source_tag, sku, department, seen_at) values
    (SUP, 'RLTest Crackers Original 250g (8)', 24, current_date - 1, 1, null, 'invoice:RLTEST-2', carton, 'Grocer', now()) returning id into u2;
  insert into ingest_unmatched (supplier, description, unit_price, invoice_date, qty, unit, source_tag, sku, department, seen_at) values
    (SUP, 'RLTest Brand New Chutney 110g (12)', 60, current_date - 2, 1, null, 'invoice:RLTEST-1', carton2, 'Grocer', now()) returning id into u3;
  insert into ingest_unmatched (supplier, description, unit_price, invoice_date, qty, unit, source_tag, sku, department, seen_at) values
    (SUP, 'RLTest Mystery Item', 10, current_date - 2, 1, null, 'invoice:RLTEST-1', null, 'Grocer', now()) returning id into u4;
  insert into ingest_unmatched (supplier, description, unit_price, invoice_date, qty, unit, source_tag, sku, department, seen_at) values
    (SUP, 'RLTest Candle Large', 15, current_date - 1, 2, null, 'invoice:RLTEST-3', null, 'Gift Store', now()) returning id into u5;
  insert into ingest_unmatched (supplier, description, unit_price, invoice_date, qty, unit, source_tag, sku, department, seen_at) values
    (SUP, 'RLTest Kitchen Flour 10kg', 20, current_date - 1, 1, null, 'invoice:RLTEST-4', null, 'Cafe', now()) returning id into u6;
  insert into ingest_unmatched (supplier, description, unit_price, invoice_date, qty, unit, source_tag, sku, department, seen_at) values
    (SUP, 'RLTest Biscuits Booking Fail (6)', 12, current_date - 2, 1, null, 'invoice:RLTEST-1', null, 'Grocer', now()) returning id into u7;
  insert into ingest_unmatched (supplier, description, unit_price, invoice_date, qty, unit, source_tag, sku, department, seen_at) values
    (SUP, 'RLTest Second New Jam 250g (6)', 30, current_date - 2, 1, null, 'invoice:RLTEST-1', null, 'Grocer', now()) returning id into u8;
  insert into invoice_lines (source_id, line_no, supplier, booked, description, department, qty, invoice_date, invoice_number, kind)
  select substr(source_tag, 9), row_number() over (partition by source_tag order by id), SUP, false, description, department, qty, invoice_date,
         'RL', 'invoice' from ingest_unmatched where id in (u1, u2, u3, u4, u5, u6, u7, u8);

  -- ---------- list, eligibility, candidates, search
  t0 := clock_timestamp();
  cards := delivery_retail_lines_list()->'cards';
  perform pg_temp.ck('list: under 3 s with all live waiting lines', clock_timestamp() - t0 < interval '3 seconds',
                     format('%s ms, %s cards, %s lines', round(extract(epoch from clock_timestamp() - t0) * 1000),
                            jsonb_array_length(cards), (select count(*) from jsonb_array_elements(cards) cd, jsonb_array_elements(cd->'lines'))));
  l := (select x from jsonb_array_elements(cards) cd, jsonb_array_elements(cd->'lines') x where (x->>'unmatched_id')::bigint = u1);
  perform pg_temp.ck('list: line shape', l->>'status' = 'open' and (l->>'printed_pack')::int = 8 and l->>'carton_code' = carton
                     and (l->>'invoice_unit_cost_ex')::numeric = 24 and jsonb_typeof(l->'candidates') = 'array', l::text);
  perform pg_temp.ck('list: café line and other departments', not exists (select 1 from jsonb_array_elements(cards) cd, jsonb_array_elements(cd->'lines') x where (x->>'unmatched_id')::bigint = u6)
                     and exists (select 1 from jsonb_array_elements(cards) cd where cd->>'source_id' = 'RLTEST-3' and cd->>'department' = 'Gift Store'));
  perform pg_temp.ck('candidates: carton barcode match first, ineligible excluded',
                     (l->'candidates'->0->>'stock_item_id')::bigint = a and (l->'candidates'->0->>'barcode_match')::boolean
                     and not exists (select 1 from jsonb_array_elements(l->'candidates') x where (x->>'stock_item_id')::bigint in (b, c, k)),
                     (l->'candidates')::text);
  perform pg_temp.ck('candidates: option facts', (l->'candidates'->0->>'unit_cost_ex')::numeric = 2 and (l->'candidates'->0->>'shelf_price')::numeric = 8.5
                     and (l->'candidates'->0->>'last_count')::numeric = 8 and (l->'candidates'->0->>'supplied_by_this_supplier')::boolean);
  r := delivery_retail_search(u1, 'RLTest Crackers');
  perform pg_temp.ck('search: array of eligible only', jsonb_typeof(r) = 'array' and jsonb_array_length(r) = 1 and (r->0->>'stock_item_id')::bigint = a, r::text);
  perform pg_temp.ck('search: non-retail line is null (404)', delivery_retail_search(u6, 'RLTest') is null);
  perform pg_temp.ck('search: short query is empty', delivery_retail_search(u1, 'R') = '[]'::jsonb);

  -- ---------- existing: validation and checks
  r := delivery_retail_answer(u6, 'existing', jsonb_build_object('stock_item_id', k, 'units', 1), op1, who);
  perform pg_temp.ck('existing: café line 404', (r->>'http')::int = 404 and r->'body'->>'code' = 'not_found', r::text);
  r := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', a, 'units', 8), op1, 'Nobody RL');
  perform pg_temp.ck('existing: unknown staff name', (r->>'http')::int = 400 and r->'body'->>'code' = 'invalid', r::text);
  r := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', a), op1, who);
  perform pg_temp.ck('existing: missing units', r->'body'->>'code' = 'invalid', r::text);
  r := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', a, 'units', 1.5), op1, who);
  perform pg_temp.ck('existing: fractional units', r->'body'->>'code' = 'invalid', r::text);
  r := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', a, 'units', '8'), op1, who);
  perform pg_temp.ck('existing: units as text rejected', r->'body'->>'code' = 'invalid', r::text);
  r := delivery_retail_answer(u1, 'existing', jsonb_build_object('units', 8), op1, who);
  perform pg_temp.ck('existing: missing product', r->'body'->>'code' = 'invalid', r::text);
  r := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', b, 'units', 8), op1, who);
  perform pg_temp.ck('existing: other supplier''s product not eligible', r->'body'->>'code' = 'not_eligible', r::text);
  r := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', c, 'units', 8), op1, who);
  perform pg_temp.ck('existing: archived product not eligible', r->'body'->>'code' = 'not_eligible', r::text);
  r := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', k, 'units', 8), op1, who);
  perform pg_temp.ck('existing: café product not eligible', r->'body'->>'code' = 'not_eligible', r::text);

  r := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', a, 'units', 1, 'confirm', '[]'::jsonb), op1, who);
  perform pg_temp.ck('existing: carton booked as 1 -> needs_confirm, all soft',
                     r->'body'->>'code' = 'needs_confirm'
                     and (select bool_and((x->>'soft')::boolean) from jsonb_array_elements(r->'body'->'checks') x)
                     and (select array_agg(x->>'code' order by x->>'code') from jsonb_array_elements(r->'body'->'checks') x)
                         = array['cost_above_shelf', 'count_differs', 'printed_pack_differs'], r::text);
  r := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', a, 'units', 1, 'confirm', '["printed_pack_differs"]'::jsonb), op1, who);
  perform pg_temp.ck('existing: partial confirm still needs_confirm', r->'body'->>'code' = 'needs_confirm', r::text);
  perform pg_temp.ck('existing: needs_confirm wrote nothing',
                     not exists (select 1 from delivery_retail_answers where unmatched_id = u1) and not exists (select 1 from delivery_retail_ops where op_id = op1)
                     and (select resolved_at from ingest_unmatched where id = u1) is null
                     and not exists (select 1 from stock_ledger where stock_item_id = a));
  r := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', a, 'units', 4, 'confirm', '[]'::jsonb), op1, who);
  perform pg_temp.ck('existing: cost_differs at 4 (6.00 vs 2.00)',
                     r->'body'->>'code' = 'needs_confirm' and r->'body'->'checks' @> '[{"code":"cost_differs"}]', r::text);

  -- ---------- existing: success, sibling, replay, conflict, already answered
  r := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', a, 'units', 8, 'confirm', '[]'::jsonb), op1, who);
  perform pg_temp.ck('existing: books with same op_id after needs_confirm',
                     (r->>'http')::int = 200 and r->'body'->>'status' = 'done' and (r->'body'->'line'->>'unmatched_id')::bigint = u1, r::text);
  select coalesce(sum(qty_base), 0), count(*) into n, n2 from stock_ledger where stock_item_id = a and movement_type = 'delivery';
  perform pg_temp.ck('existing: stock booked for the line and its sibling (2x8 + 1x8)', n = 24 and n2 = 2, format('qty %s rows %s', n, n2));
  perform pg_temp.ck('existing: mapping saved with pack 8',
                     exists (select 1 from supplier_product_map where stock_item_id = a and supplier = SUP and match_text ilike 'RLTest Crackers Original 250g (8)' and pack_grams = 8));
  perform pg_temp.ck('existing: invoice line flagged booked', (select bool_and(booked) from invoice_lines where description = 'RLTest Crackers Original 250g (8)'));
  l := delivery_retail_line_json(u2);
  perform pg_temp.ck('existing: sibling line shows done (booked outside)', l->>'status' = 'done' and l->'answer' = 'null'::jsonb, l::text);
  r2 := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', a, 'units', 8, 'confirm', '[]'::jsonb), op1, who);
  perform pg_temp.ck('existing: same op_id + payload replays',
                     (r2->>'http')::int = 200 and (r2->'body'->>'replayed')::boolean and (r2->'body'->'line'->>'unmatched_id')::bigint = u1
                     and (select count(*) from stock_ledger where stock_item_id = a) = 2, r2::text);
  r2 := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', a, 'units', 9, 'confirm', '[]'::jsonb), op1, who);
  perform pg_temp.ck('existing: same op_id + other payload -> op_conflict', (r2->>'http')::int = 409 and r2->'body'->>'code' = 'op_conflict'
                     and (r2->'body'->'line'->>'unmatched_id')::bigint = u1, r2::text);
  r2 := delivery_retail_answer(u1, 'existing', jsonb_build_object('stock_item_id', a, 'units', 8), op2, who);
  perform pg_temp.ck('existing: new op_id on answered line -> already_answered', (r2->>'http')::int = 409 and r2->'body'->>'code' = 'already_answered'
                     and (r2->'body'->'line'->>'unmatched_id')::bigint = u1 and r2->'body'->'line'->>'status' = 'done', r2::text);
  r2 := delivery_retail_answer(u2, 'existing', jsonb_build_object('stock_item_id', a, 'units', 8), op2, who);
  perform pg_temp.ck('existing: sibling already booked -> already_answered', r2->'body'->>'code' = 'already_answered', r2::text);
  r2 := delivery_retail_answer(u4, 'josh', jsonb_build_object('reason', 'x'), op1, who);
  perform pg_temp.ck('ops: an op_id used on another line is a conflict', r2->'body'->>'code' = 'op_conflict', r2::text);

  -- ---------- existing: booking that does not complete is undone
  d := pg_get_functiondef('public.ingest_invoice_line(text,text,numeric,date,numeric,text,text,text,text)'::regprocedure);
  execute (select format('create or replace function public.ingest_invoice_line(%s) returns %s language sql as %L',
                          pg_get_function_arguments(p.oid), pg_get_function_result(p.oid), 'select null::' || pg_get_function_result(p.oid))
             from pg_proc p where p.oid = 'public.ingest_invoice_line(text,text,numeric,date,numeric,text,text,text,text)'::regprocedure);
  r := delivery_retail_answer(u7, 'existing', jsonb_build_object('stock_item_id', a, 'units', 6), op3, who);
  execute d;
  perform pg_temp.ck('existing: failed booking -> booking_failed, mapping rolled back',
                     r->'body'->>'code' = 'booking_failed'
                     and not exists (select 1 from supplier_product_map where match_text ilike 'RLTest Biscuits Booking Fail%')
                     and not exists (select 1 from delivery_retail_answers where unmatched_id = u7)
                     and not exists (select 1 from delivery_retail_ops where op_id = op3), r::text);
  perform pg_temp.ck('existing: line still open after failed booking', delivery_retail_line_json(u7, false)->>'status' = 'open');

  -- ---------- josh
  r := delivery_retail_answer(u4, 'josh', jsonb_build_object('reason', '   '), gen_random_uuid(), who);
  perform pg_temp.ck('josh: blank reason rejected', r->'body'->>'code' = 'invalid', r::text);
  r := delivery_retail_answer(u4, 'josh', jsonb_build_object('reason', 'Not sure what this is'), gen_random_uuid(), who);
  perform pg_temp.ck('josh: with_josh', (r->>'http')::int = 200 and r->'body'->>'status' = 'with_josh'
                     and r->'body'->'line'->'answer'->>'reason' = 'Not sure what this is', r::text);

  -- ---------- new: barcode checks (PR #5 payload shape)
  r := delivery_retail_answer(u3, 'new', jsonb_build_object('units', 12, 'barcode', left(good13, 12) || ((right(good13, 1)::int + 1) % 10), 'no_barcode', false, 'name', '', 'note', '', 'confirm', '[]'::jsonb), gen_random_uuid(), who);
  perform pg_temp.ck('new: bad check digit -> barcode_invalid', r->'body'->>'code' = 'barcode_invalid', r::text);
  r := delivery_retail_answer(u3, 'new', jsonb_build_object('units', 12, 'barcode', carton2, 'no_barcode', false, 'name', '', 'note', '', 'confirm', '[]'::jsonb), gen_random_uuid(), who);
  perform pg_temp.ck('new: invoice carton code -> carton_barcode', r->'body'->>'code' = 'carton_barcode', r::text);
  r := delivery_retail_answer(u3, 'new', jsonb_build_object('units', 12, 'barcode', '0' || carton2, 'no_barcode', false, 'confirm', '[]'::jsonb), gen_random_uuid(), who);
  perform pg_temp.ck('new: carton code with a leading zero -> invalid or carton', r->'body'->>'code' in ('carton_barcode', 'barcode_invalid'), r::text);
  r := delivery_retail_answer(u3, 'new', jsonb_build_object('units', 12, 'barcode', carton, 'no_barcode', false, 'confirm', '[]'::jsonb), gen_random_uuid(), who);
  perform pg_temp.ck('new: any GTIN-14 trade unit -> carton_barcode', r->'body'->>'code' = 'carton_barcode', r::text);
  r := delivery_retail_answer(u3, 'new', jsonb_build_object('units', 12, 'barcode', known13, 'no_barcode', false, 'confirm', '[]'::jsonb), gen_random_uuid(), who);
  perform pg_temp.ck('new: barcode already in Square -> barcode_known', r->'body'->>'code' = 'barcode_known' and r->'body'->>'product' like 'RLTest Crackers%', r::text);
  r := delivery_retail_answer(u3, 'new', jsonb_build_object('units', 12, 'barcode', '', 'no_barcode', true, 'name', '', 'note', '', 'confirm', '[]'::jsonb), gen_random_uuid(), who);
  perform pg_temp.ck('new: Grocer, no barcode, no note -> barcode_required', r->'body'->>'code' = 'barcode_required', r::text);
  r := delivery_retail_answer(u3, 'new', jsonb_build_object('units', 6, 'barcode', good13, 'no_barcode', false, 'confirm', '[]'::jsonb), gen_random_uuid(), who);
  perform pg_temp.ck('new: units vs printed pack -> needs_confirm', r->'body'->>'code' = 'needs_confirm' and r->'body'->'checks' @> '[{"code":"printed_pack_differs","soft":true}]', r::text);
  r := delivery_retail_answer(u5, 'new', jsonb_build_object('units', 1, 'barcode', '', 'no_barcode', true, 'name', '', 'note', '', 'confirm', '[]'::jsonb), gen_random_uuid(), who);
  perform pg_temp.ck('new: Gift Store with no barcode and no note is allowed', (r->>'http')::int = 200 and r->'body'->>'status' = 'setting_up', r::text);

  -- ---------- new: success -> receipt for new-stock-setup
  select count(*) into photo_before from jsonb_array_elements(delivery_recent_list(null)->'recent') x where x->>'kind' = 'photo';
  r := delivery_retail_answer(u3, 'new', jsonb_build_object('units', 12, 'barcode', good13, 'no_barcode', false, 'name', '', 'note', '', 'confirm', '[]'::jsonb), op2, who);
  v_receipt := (r->'body'->>'receipt_id')::uuid;
  perform pg_temp.ck('new: setting_up with receipt id = op_id', (r->>'http')::int = 200 and r->'body'->>'status' = 'setting_up' and v_receipt = op2
                     and (r->'body'->'line'->>'unmatched_id')::bigint = u3, r::text);
  perform pg_temp.ck('new: receipt is a submitted invoice_line receipt carrying staff facts',
                     exists (select 1 from delivery_receipts x where x.id = op2 and x.origin = 'invoice_line' and x.status = 'submitted' and x.setup_status = 'pending'
                               and x.staff_edits->>'invoice_number' = 'RL-INV-1' and x.submitted_lines->0->>'staff_units_per_invoice_unit' = '12'
                               and x.submitted_lines->0->>'carton_code' = carton2 and x.submitted_lines->0->>'barcode' = good13
                               and (x.submitted_lines->0->>'invoice_unit_cost_ex')::numeric = 60));
  perform pg_temp.ck('new: invoice_line receipts stay out of Recent deliveries',
                     (select count(*) from jsonb_array_elements(delivery_recent_list(null)->'recent') x where x->>'kind' = 'photo') = photo_before);
  r2 := delivery_retail_answer(u3, 'new', jsonb_build_object('units', 12, 'barcode', good13, 'no_barcode', false, 'name', '', 'note', '', 'confirm', '[]'::jsonb), op2, who);
  perform pg_temp.ck('new: replay returns the same receipt, no second receipt', (r2->'body'->>'replayed')::boolean and r2->'body'->>'receipt_id' = op2::text
                     and (select count(*) from delivery_receipts where source_id = 'retail-line:' || u3) = 1, r2::text);

  -- ---------- new-stock-setup simulation: the reader guesses 10 per carton and returns the carton code as gtin/supplier code
  select cc.square_category_id into v_cat from square_categories cc join square_categories root on root.square_category_id = cc.root_id
   where cc.category_type = 'REGULAR_CATEGORY' and coalesce(cc.is_deleted, false) = false and canonical_department(root.name) = 'Grocer' limit 1;
  insert into new_stock_lines (receipt_id, line_no, input, decision, decided_at)
  select op2, 1, x.submitted_lines->0, jsonb_build_object('action', 'new_item', 'item_name', 'RLTest Brand - New Chutney', 'variation_name', '110g',
           'category_id', v_cat, 'units_per_invoice_unit', 10, 'unit_cost_ex', 6.6, 'taxable', true, 'gtin', carton2, 'supplier_code', carton2,
           'confidence', 0.95, 'reason', 'test'), now()
    from delivery_receipts x where x.id = op2 returning id into v_line;
  r := new_stock_apply(v_line, false);
  perform pg_temp.ck('setup: apply creates in (stubbed) Square', r->>'status' = 'square_created', r::text);
  perform pg_temp.ck('setup: staff units and invoice cost win over the reader',
                     exists (select 1 from new_stock_lines x where x.id = v_line and (x.result->>'units_per_invoice_unit')::numeric = 12
                               and (x.result->>'unit_cost_ex')::numeric = 5), (select result::text from new_stock_lines where id = v_line));
  perform pg_temp.ck('setup: shelf barcode = staff scan, carton code nowhere in Square',
                     exists (select 1 from new_stock_lines x where x.id = v_line and x.result->>'upc' = good13 and x.sku = good13)
                     and not exists (select 1 from rl_square q where q.body::text like '%' || carton2 || '%'),
                     (select string_agg(body::text, ' | ') from rl_square));
  r := new_stock_wire(v_line);
  perform pg_temp.ck('setup: wire links and replays the exact invoice line', r->>'status' = 'created' and (r->'replay'->>'unmatched_id')::bigint = u3
                     and r->'replay'->>'booked' is not null, r::text);
  si := (r->>'stock_item_id')::bigint;
  select coalesce(sum(qty_base), 0) into n from stock_ledger where stock_item_id = si and movement_type = 'delivery' and source = 'invoice:RLTEST-1';
  perform pg_temp.ck('setup: booked 1 carton x 12', n = 12, format('qty %s item %s', n, si));
  perform pg_temp.ck('setup: mapping pack is 12', exists (select 1 from supplier_product_map where stock_item_id = si and supplier = SUP and pack_grams = 12));
  l := delivery_retail_line_json(u3);
  perform pg_temp.ck('setup: line done', l->>'status' = 'done' and l->'answer'->>'action' = 'new', l::text);

  -- reader says "known" for a line staff called new -> Josh, nothing mapped
  r := delivery_retail_answer(u8, 'new', jsonb_build_object('units', 6, 'barcode', '', 'no_barcode', true, 'note', 'loose jar, no code', 'confirm', '[]'::jsonb), gen_random_uuid(), who);
  insert into new_stock_lines (receipt_id, line_no, input, decision, decided_at)
  select x.id, 1, x.submitted_lines->0, jsonb_build_object('action', 'known', 'existing_stock_item_id', a, 'confidence', 0.9, 'reason', 'test'), now()
    from delivery_receipts x where x.source_id = 'retail-line:' || u8 returning id into v_line;
  r := new_stock_apply(v_line, false);
  perform pg_temp.ck('setup: "known" for a staff-new line goes to Josh', r->>'status' = 'needs_josh'
                     and not exists (select 1 from supplier_product_map where match_text ilike 'RLTest Second New Jam%')
                     and delivery_retail_line_json(u8)->>'status' = 'with_josh', r::text);

  -- photo-flow lines are unaffected by the patch (no staff keys: reader's units/cost/gtin used as before)
  insert into delivery_receipts (id, source_id, supplier, department, status, setup_status, staff_edits, submitted_lines, is_fixture)
  values (gen_random_uuid(), 'app:rltest-photo', SUP, 'Grocer', 'submitted', 'pending', '{}', '[]', true) returning id into v_receipt;
  insert into new_stock_lines (receipt_id, line_no, input, decision) values (v_receipt, 1,
    jsonb_build_object('description', 'RLTest Photo Thing', 'qty', 1, 'unit_price', 20, 'source', 'invoice'),
    jsonb_build_object('action', 'new_item', 'item_name', 'RLTest Photo Thing', 'category_id', v_cat, 'units_per_invoice_unit', 4,
                       'unit_cost_ex', 5, 'gtin', good13, 'confidence', 0.95, 'reason', 'test')) returning id into v_line;
  r := new_stock_apply(v_line, true);
  perform pg_temp.ck('photo flow unchanged: reader units/cost/gtin used', exists (select 1 from new_stock_lines x where x.id = v_line and x.status = 'dry_run'
                       and (x.result->>'units_per_invoice_unit')::numeric = 4 and (x.result->>'unit_cost_ex')::numeric = 5 and x.result->>'upc' = good13),
                     (select result::text from new_stock_lines where id = v_line));

  -- ---------- dry_run -> live requeue
  insert into new_stock_lines (receipt_id, line_no, input, status, result)
  select x.id, 1, x.submitted_lines->0, 'dry_run', '{"would":"new_item"}' from delivery_receipts x where x.source_id = 'retail-line:' || u5;
  update delivery_receipts set setup_status = 'dry_run' where source_id = 'retail-line:' || u5;
  update app_config set value = 'dry_run' where key = 'new_stock_mode';
  perform pg_temp.ck('dry_run: line shows test-mode note', delivery_retail_line_json(u5)->>'status_note' like 'Test mode%');
  perform delivery_retail_lines_list();
  perform pg_temp.ck('dry_run: nothing requeued while dry_run', (select setup_status from delivery_receipts where source_id = 'retail-line:' || u5) = 'dry_run');
  update app_config set value = 'live' where key = 'new_stock_mode';
  perform delivery_retail_lines_list();
  perform pg_temp.ck('dry_run: requeued once live', (select setup_status from delivery_receipts where source_id = 'retail-line:' || u5) = 'pending'
                     and (select l.status from new_stock_lines l join delivery_receipts x on x.id = l.receipt_id where x.source_id = 'retail-line:' || u5) = 'pending');

  -- ---------- list after the actions
  cards := delivery_retail_lines_list()->'cards';
  perform pg_temp.ck('list: statuses after actions',
    (select jsonb_object_agg(x->>'unmatched_id', x->>'status') from jsonb_array_elements(cards) cd, jsonb_array_elements(cd->'lines') x
      where (x->>'unmatched_id')::bigint in (u1, u2, u3, u4, u5, u7, u8))
    = jsonb_build_object(u1::text, 'done', u2::text, 'done', u3::text, 'done', u4::text, 'with_josh', u5::text, 'setting_up', u7::text, 'open', u8::text, 'with_josh'),
    (select jsonb_object_agg(x->>'unmatched_id', x->>'status') from jsonb_array_elements(cards) cd, jsonb_array_elements(cd->'lines') x)::text);
  perform pg_temp.ck('list: open counts', (select (cd->>'open')::int from jsonb_array_elements(cards) cd where cd->>'source_id' = 'RLTEST-1') = 1);

  -- ---------- privileges
  perform pg_temp.ck('selfcheck ok', (delivery_app_selfcheck()->>'ok')::boolean, delivery_app_selfcheck()::text);
  perform pg_temp.ck('no anon/authenticated on new tables', not has_table_privilege('anon', 'delivery_retail_answers', 'select')
                     and not has_table_privilege('authenticated', 'delivery_retail_ops', 'select'));
end $T$;

do $$ begin
  raise exception 'RL-RESULTS %', (select jsonb_build_object('passed', count(*) filter (where ok), 'failed', count(*) filter (where not ok),
    'failures', coalesce(jsonb_agg(jsonb_build_object('n', n, 'name', name, 'detail', left(detail, 600)) order by n) filter (where not ok), '[]'),
    'names', jsonb_agg(name order by n)) from rl_t);
end $$;
