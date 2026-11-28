-- pricing_repair_01 test, part 0 (LOCAL ONLY, disposable database): synthetic "existing" catalogue that exists before the
-- migration, so the before/after comparison has known cases. All names start with PRSeed; no business data.
--   Step*  : the true price sits exactly on a 5c step (the old 4-dp rounding came out 5c high)
--   Off*   : the true price is not on a step (unaffected)
--   Half*  : a half variation on a step (affected) / off a step (unaffected)
--   Pantry : a packaged (passthrough) item, unaffected
--   NoVar  : a produce item with no Square variation and no shelf price (first price due)
do $seed$
declare i bigint;
  procedure_items jsonb := '[
    {"n": "PRSeed Step Each 14/12",  "shelf": 2.10, "cost": 14.00, "size": 12,    "base": 1},
    {"n": "PRSeed Step Kg 65/12kg",  "shelf": 9.75, "cost": 65.00, "size": 12000, "base": 1000},
    {"n": "PRSeed Step Each 25/18",  "shelf": 2.40, "cost": 25.00, "size": 18,    "base": 1},
    {"n": "PRSeed Off Kg 30/13kg",   "shelf": 4.00, "cost": 30.00, "size": 13000, "base": 1000},
    {"n": "PRSeed Off Kg 42.50/4kg", "shelf": 19.00,"cost": 42.50, "size": 4000,  "base": 1000}]';
  x jsonb;
begin
  for x in select * from jsonb_array_elements(procedure_items) loop
    insert into stock_items (name, department, count_unit, grams_per_count_unit, retail_sell_price)
    values (x->>'n', 'Grocer', case when (x->>'base')::numeric = 1000 then 'kg' else 'each' end, (x->>'base')::numeric, (x->>'shelf')::numeric) returning id into i;
    insert into square_sync_map (stock_item_id, square_variation_id, square_item_name, retail_category, taxable)
    values (i, 'PRSEEDMAIN' || lpad(i::text, 12, '0'), x->>'n', 'Produce', false);
    insert into square_sales_map (square_variation_id, square_item_name, square_variation_name, retail_stock_item_id, retail_units_base)
    values ('PRSEEDMAIN' || lpad(i::text, 12, '0'), x->>'n', 'Regular', i, (x->>'base')::numeric);
    insert into supplier_prices (stock_item_id, supplier, pack_label, pack_grams, pack_cost, effective_from)
    values (i, 'PRSeed supplier', 'PRSeed pack', (x->>'size')::numeric, (x->>'cost')::numeric, current_date - 3);
  end loop;

  -- whole 12 for $28.00 each = $4.20 (on a step either way); half on a step ($2.10, recorded $2.15); quarter $1.05 (recorded right)
  insert into stock_items (name, department, count_unit, grams_per_count_unit, retail_sell_price) values ('PRSeed Half 28/12', 'Grocer', 'each', 1, 4.20) returning id into i;
  insert into square_sync_map (stock_item_id, square_variation_id, square_item_name, retail_category, taxable) values (i, 'PRSEEDMAIN' || lpad(i::text, 12, '0'), 'PRSeed Half 28/12', 'Produce', false);
  insert into square_sales_map (square_variation_id, square_item_name, square_variation_name, retail_stock_item_id, retail_units_base) values
    ('PRSEEDMAIN' || lpad(i::text, 12, '0'), 'PRSeed Half 28/12', 'Regular', i, 1),
    ('PRSEEDHALF' || lpad(i::text, 12, '0'), 'PRSeed Half 28/12', 'Half', i, 0.5),
    ('PRSEEDQRTR' || lpad(i::text, 12, '0'), 'PRSeed Half 28/12', 'Quarter', i, 0.25);
  insert into retail_part_variation_price (square_variation_id, stock_item_id, price) values ('PRSEEDHALF' || lpad(i::text, 12, '0'), i, 2.15),
    ('PRSEEDQRTR' || lpad(i::text, 12, '0'), i, 1.05);
  insert into supplier_prices (stock_item_id, supplier, pack_label, pack_grams, pack_cost, effective_from) values (i, 'PRSeed supplier', 'PRSeed pack', 12, 28.00, current_date - 3);

  -- packaged (passthrough): shelf $4.00 set when the unit cost was $2.00; cost now $2.20 -> $4.40
  insert into stock_items (name, department, count_unit, grams_per_count_unit, retail_sell_price) values ('PRSeed Pantry Jar', 'Grocer', 'each', 1, 4.00) returning id into i;
  insert into square_sync_map (stock_item_id, square_variation_id, square_item_name, retail_category, taxable) values (i, 'PRSEEDMAIN' || lpad(i::text, 12, '0'), 'PRSeed Pantry Jar', 'Pantry', true);
  insert into retail_price_history (stock_item_id, old_price, new_price, unit_cost_at_change, changed_at, source) values (i, 3.80, 4.00, 2.00, now() - interval '20 days', 'PRSeed');
  insert into supplier_prices (stock_item_id, supplier, pack_label, pack_grams, pack_cost, effective_from) values (i, 'PRSeed supplier', 'PRSeed pack', 6, 13.20, current_date - 3);

  -- produce item with no Square variation and no shelf price: a first price is calculated ($2.90 from $1.60)
  insert into stock_items (name, department, count_unit, grams_per_count_unit, retail_sell_price) values ('PRSeed NoVar', 'Grocer', 'each', 1, null) returning id into i;
  insert into square_sync_map (stock_item_id, square_variation_id, square_item_name, retail_category, taxable) values (i, null, 'PRSeed NoVar', 'Produce', false);
  insert into supplier_prices (stock_item_id, supplier, pack_label, pack_grams, pack_cost, effective_from) values (i, 'PRSeed supplier', 'PRSeed pack', 1, 1.60, current_date - 3);
end $seed$;
