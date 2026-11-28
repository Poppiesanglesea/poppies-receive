-- pricing_repair_01 integration test, part 3 of 5. 28 Nov 2026.
-- Runs on a DISPOSABLE local database only: db/tests/run_pricing_repair_local.sh (never production).
-- One transaction: seed + pre + migration + this file + rollback + post. The last statement raises 'PR-RESULTS {...}',
-- so everything rolls back. Square: price_square_get/put are served by pg_temp mocks and square_api raises, so no call can
-- reach Square. All fixtures are synthetic (PRSeed / PRTest names); supplier names come from app_config.

create temp table pr_square (variation text primary key, cents int, version bigint default 1, puts int default 0) on commit drop;
create temp table pr_bad (source_id text primary key, mode text) on commit drop;
create function pg_temp.square_mock_get(p_var text) returns jsonb language sql as $$
  select case when s.variation is null then jsonb_build_object('ok', false, 'error', 'GET 404')
              else jsonb_build_object('ok', true, 'cents', s.cents, 'version', s.version) end
    from (select 1) x left join pr_square s on s.variation = p_var $$;
create function pg_temp.square_mock_put(p_var text, p_version bigint, p_cents int, p_idem text) returns jsonb language plpgsql as $$
declare v bigint;
begin
  update pr_square set cents = p_cents, version = version + 1, puts = puts + 1 where variation = p_var and version = p_version returning version into v;
  if v is null then return jsonb_build_object('ok', false, 'conflict', true, 'error', 'version changed'); end if;
  return jsonb_build_object('ok', true, 'version', v);
end $$;
insert into pr_pre_fn select 'ppfi_def', null, pg_get_functiondef('public.produce_price_for_invoice(text,boolean)'::regprocedure);
create function pg_temp.sup(n int) returns text language sql as $$
  select coalesce(nullif(split_part((select value from app_config where key = 'produce_autoprice_suppliers'), ',', n), ''),
                  split_part((select value from app_config where key = 'produce_autoprice_suppliers'), ',', 1)) $$;
create function pg_temp.sid(p_name text) returns bigint language sql as $$ select id from stock_items where name = p_name $$;

-- independent check that p is cost x markup rounded UP to 5c: p*20 = k is whole and (k-1)/20 < exact <= k/20 (multiplication only)
create function pg_temp.exact_ok(p numeric, pack_cost numeric, pack_size numeric, base numeric, mk numeric, tax boolean) returns boolean
language plpgsql as $$
declare k numeric := p * 20; n numeric; d numeric;
begin
  if p is null or k <> trunc(k) then return false; end if;
  n := pack_cost * base * (100 + mk) * (case when tax then 110 else 100 end) * 20;   -- exact price x 20 x d
  d := pack_size * 10000;
  return (k - 1) * d < n and n <= k * d;
end $$;

-- synthetic item: shelf price, a pack cost dated p_cost_date, optional half with a recorded price, optional last price
-- change p_hist_days ago, retail category, and whether it has a Square variation
create function pg_temp.mk(p_name text, p_shelf numeric, p_cost numeric, p_size numeric, p_base numeric, p_part_base numeric,
                           p_part_price numeric, p_cost_date date, p_hist_days int, p_cat text default 'Produce', p_var boolean default true)
returns bigint language plpgsql as $$
declare i bigint; vm text; vp text;
begin
  insert into stock_items (name, department, count_unit, grams_per_count_unit, is_active, archived, is_prep, track_stock, inventory_mode, retail_sell_price)
  values (p_name, 'Grocer', case when p_base = 1000 then 'kg' else 'each' end, p_base, true, false, false, true, 'scan', p_shelf) returning id into i;
  delete from retail_price_history where stock_item_id = i;
  if p_hist_days is not null then
    insert into retail_price_history (stock_item_id, old_price, new_price, unit_cost_at_change, changed_at, source, note)
    values (i, p_shelf, p_shelf, p_cost / p_size * p_base, now() - make_interval(days => p_hist_days), 'PRTEST', 'synthetic');
  end if;
  vm := case when p_var then 'PRTESTMAIN' || lpad(i::text, 12, '0') end;
  insert into square_sync_map (stock_item_id, square_variation_id, square_item_name, retail_category, taxable, sync_price, sync_inventory)
  values (i, vm, p_name, p_cat, false, true, false);
  if p_var then
    insert into square_sales_map (square_variation_id, square_item_name, square_variation_name, retail_stock_item_id, retail_units_base, active)
    values (vm, p_name, 'Regular', i, p_base, true);
    insert into pr_square (variation, cents) values (vm, round(p_shelf * 100));
  end if;
  if p_part_base is not null then
    vp := 'PRTESTPART' || lpad(i::text, 12, '0');
    insert into square_sales_map (square_variation_id, square_item_name, square_variation_name, retail_stock_item_id, retail_units_base, active)
    values (vp, p_name, 'Half', i, p_part_base, true);
    if p_part_price is not null then
      insert into retail_part_variation_price (square_variation_id, stock_item_id, price) values (vp, i, p_part_price);
      insert into pr_square (variation, cents) values (vp, round(p_part_price * 100));
    end if;
  end if;
  insert into supplier_prices (stock_item_id, supplier, pack_label, pack_grams, pack_cost, effective_from, is_preferred, needs_review)
  values (i, 'PRTest supplier', 'PRTEST pack', p_size, p_cost, p_cost_date, true, false);
  return i;
end $$;

-- a booked delivery: invoice row, a new cost row dated today (same pack cost) and a delivery ledger row per item
create function pg_temp.deliver(p_src text, p_supplier text, p_items bigint[], p_at timestamptz, p_new_cost boolean default true)
returns void language plpgsql as $$
declare i bigint;
begin
  insert into processed_invoices (source_id, supplier, invoice_number, invoice_date, processed_at, booked_count, department, note)
  values (p_src, p_supplier, p_src, current_date, p_at, cardinality(p_items), 'Grocer', 'INVOICE');
  foreach i in array p_items loop
    if p_new_cost then
      insert into supplier_prices (stock_item_id, supplier, pack_label, pack_grams, pack_cost, effective_from, is_preferred, needs_review)
      select stock_item_id, supplier, pack_label, pack_grams, pack_cost, current_date, is_preferred, false
        from supplier_prices where stock_item_id = i and not coalesce(needs_review, false) order by effective_from desc, id desc limit 1;
    end if;
    insert into stock_ledger (stock_item_id, qty_base, movement_type, source, occurred_at, department)
    values (i, 1, 'delivery', 'invoice:' || p_src, p_at, 'Grocer');
  end loop;
end $$;

-- =====================================================================================================================
do $T$
declare x record;
begin
  -- ---------- 0. applying the migration changed no records
  perform pg_temp.ck('apply: no change to shelf prices, halves, proposals, tasks, operations, runs, history, costs or config',
                     pg_temp.state() = (select s from pr_state0), pg_temp.state()::text);
  perform pg_temp.ck('apply: 8 backups (7 functions + view)', (select count(*) from function_backup where label = 'pre-pricing-repair-2026-11-28') = 8);
  perform pg_temp.ck('apply: functions that must not change are unchanged',
                     not exists (select 1 from pr_pre_fn f join pg_proc p on p.oid::regprocedure::text = f.sig
                                  where p.prokind = 'f' and f.h is not null and p.proname not in ('produce_price_items', 'produce_price_sweep', 'price_proposal_decide',
                                        'price_proposal_apply', 'delivery_price_decide', 'sync_part_variation_prices', 'price_rules_scan')
                                    and md5(case when p.prokind = 'f' then pg_get_functiondef(p.oid) end) <> f.h));
  perform pg_temp.ck('apply: produce markup is 80% and Produce min change is 5c (compared with <)',
                     (select markup_pct from retail_markups where category = 'Produce') = 80
                     and (select min_change_cents from pricing_policy where scope = 'retail_category' and key = 'Produce') = 5
                     and pg_get_viewdef('public.v_price_rule_candidates'::regclass) like '%< min_change_cents%');

  -- ---------- 1. exact arithmetic, pure cases (category Produce = 80%, GST-free)
  for x in select * from (values
      ('12 for $14.00, each (on a 5c step)', 14.00, 12, 1, 2.10),
      ('18 for $25.00, each (on a 5c step)', 25.00, 18, 1, 2.50),
      ('9 for $10.50, each (on a 5c step)', 10.50, 9, 1, 2.10),
      ('6 for $7.00, each (on a 5c step)', 7.00, 6, 1, 2.10),
      ('12 for $28.00, half (on a 5c step)', 28.00, 12, 0.5, 2.10),
      ('12 for $28.00, quarter', 28.00, 12, 0.25, 1.05),
      ('above the step: 12 for $14.01, each', 14.01, 12, 1, 2.15),
      ('just above the step: 12 for $14.0001, each', 14.0001, 12, 1, 2.15),
      ('4 kg for $42.50, per kg', 42.50, 4000, 1000, 19.15),
      ('4 kg for $42.50, 500 g half', 42.50, 4000, 500, 9.60),
      ('13 kg for $30.00, per kg', 30.00, 13000, 1000, 4.20),
      ('$1.00 each', 1.00, 1, 1, 1.80),
      ('$2.50 each', 2.50, 1, 1, 4.50),
      ('$0.01 each', 0.01, 1, 1, 0.05),
      ('12 kg for $65.00, per kg (on a step)', 65.00, 12000, 1000, 9.75),
      ('12 for $44.00, each (on a step)', 44.00, 12, 1, 6.60)) v(label, c, sz, b, want) loop
    perform pg_temp.ck('exact: ' || x.label, retail_price_for_pack(x.c, x.sz, x.b, 'Produce', false) = x.want,
                       format('want %s got %s (old way %s)', x.want, retail_price_for_pack(x.c, x.sz, x.b, 'Produce', false),
                              retail_price_for(round(x.c / x.sz * x.b, 4), 'Produce', false)));
  end loop;
  perform pg_temp.ck('exact: taxable category (Default 80% x 1.10): $10.00 -> $19.80; null or zero pack size -> null',
                     retail_price_for_pack(10, 1, 1, 'Default', true) = 19.80 and retail_price_for_pack(10, null, 1, 'Produce', false) is null
                     and retail_price_for_pack(10, 0, 1, 'Produce', false) is null);

  -- ---------- 2. existing catalogue (PRSeed, made before the migration): only on-step items move, always down 5c
  create temp table pr_after on commit drop as select * from v_price_rule_candidates;
  create temp table pr_cost on commit drop as
    select distinct on (stock_item_id) stock_item_id, pack_cost, pack_grams from supplier_prices
     where not coalesce(needs_review, false) order by stock_item_id, effective_from desc, id desc;
  perform pg_temp.ck('existing: every Produce whole-item band price passes the exact check',
                     not exists (select 1 from pr_after a join pr_cost c using (stock_item_id) join retail_markups m on m.category = coalesce(
                                   (select category from retail_markups where category = a.retail_category), 'Default')
                                  where a.method = 'band' and a.retail_category = 'Produce' and a.proposed_price is not null
                                    and not pg_temp.exact_ok(a.proposed_price, c.pack_cost, c.pack_grams, a.retail_unit_base, m.markup_pct, coalesce(a.taxable, false))),
                     (select count(*) || ' Produce band rows' from pr_after where method = 'band' and retail_category = 'Produce'));
  create temp table pr_diff on commit drop as
    select coalesce(a.stock_item_id, b.stock_item_id) id, b.proposed_price before_p, a.proposed_price after_p, coalesce(a.method, b.method) method
      from pr_after a full join pr_before b on a.stock_item_id = b.stock_item_id
     where to_jsonb(a) is distinct from to_jsonb(b);
  perform pg_temp.ck('existing: passthrough (packaged) calculations identical', not exists (select 1 from pr_diff where method <> 'band'),
                     (select string_agg(id::text, ',') from pr_diff where method <> 'band'));
  perform pg_temp.ck('existing: each changed band price is exactly 5c lower than before (never higher)',
                     not exists (select 1 from pr_diff d join stock_items si on si.id = d.id
                                  where coalesce(d.before_p, si.retail_sell_price) - coalesce(d.after_p, si.retail_sell_price) <> 0.05),
                     (select string_agg(format('%s: %s -> %s', id, coalesce(before_p::text, 'shelf'), coalesce(after_p::text, 'shelf')), '; ') from pr_diff));
  perform pg_temp.ck('existing: exactly the three on-step Produce items moved; off-step, packaged, no-variation and non-Produce band items did not',
                     (select array_agg(si.name order by si.name) from pr_diff d join stock_items si on si.id = d.id)
                     = array['PRSeed Step Each 14/12', 'PRSeed Step Each 25/18', 'PRSeed Step Kg 65/12kg'],
                     (select array_agg(si.name order by si.name) from pr_diff d join stock_items si on si.id = d.id)::text);
  perform pg_temp.ck('existing: a shelf price already on the step no longer gets a +5c change; one 5c high now calculates 5c lower',
                     not exists (select 1 from pr_after where stock_item_id in (pg_temp.sid('PRSeed Step Each 14/12'), pg_temp.sid('PRSeed Step Kg 65/12kg')))
                     and (select proposed_price from pr_after where stock_item_id = pg_temp.sid('PRSeed Step Each 25/18')) = 2.50);
  perform pg_temp.ck('existing halves/quarters: only the on-step half moves ($2.15 recorded -> $2.10); the quarter is unchanged',
                     sync_part_variation_prices(pg_temp.sid('PRSeed Half 28/12'), true)
                       = jsonb_build_array(jsonb_build_object('variation', 'PRSEEDHALF' || lpad(pg_temp.sid('PRSeed Half 28/12')::text, 12, '0'),
                                                              'from', 2.15, 'to', 2.10, 'action', 'would_push'))
                     and (select r from pr_parts_before where stock_item_id = pg_temp.sid('PRSeed Half 28/12')) = '[]'
                     and not exists (select 1 from pr_parts_before b where b.stock_item_id <> pg_temp.sid('PRSeed Half 28/12')
                                       and sync_part_variation_prices(b.stock_item_id, true)::text <> b.r),
                     sync_part_variation_prices(pg_temp.sid('PRSeed Half 28/12'), true)::text);
  perform pg_temp.ck('non-Produce band: repeating-decimal price keeps the original expression (12 for $14.00 -> $2.15, not $2.10)',
                     (select proposed_price from pr_after where stock_item_id = pg_temp.sid('PRSeed Band Each 14/12')) = 2.15
                     and (select proposed_price from pr_before where stock_item_id = pg_temp.sid('PRSeed Band Each 14/12')) = 2.15
                     and retail_price_for(round(14.00 / 12, 4), 'PRSeed Band', false) = 2.15,
                     (select proposed_price from pr_after where stock_item_id = pg_temp.sid('PRSeed Band Each 14/12'))::text);
  perform pg_temp.ck('non-Produce band: half keeps the original expression ($2.15, not $2.10), identical to before',
                     sync_part_variation_prices(pg_temp.sid('PRSeed Band Half 28/12'), true)->0->>'to' = '2.15'
                     and sync_part_variation_prices(pg_temp.sid('PRSeed Band Half 28/12'), true)::text
                         = (select r from pr_parts_before where stock_item_id = pg_temp.sid('PRSeed Band Half 28/12')),
                     sync_part_variation_prices(pg_temp.sid('PRSeed Band Half 28/12'), true)::text);
  perform pg_temp.ck('existing: every active Produce half/quarter passes the exact check',
                     not exists (select 1 from square_sales_map sm join square_sync_map ssm on ssm.stock_item_id = sm.retail_stock_item_id and ssm.retail_category = 'Produce'
                                   join v_pricing_policy_for_item p on p.stock_item_id = ssm.stock_item_id and p.method = 'band'
                                   join pr_cost c on c.stock_item_id = ssm.stock_item_id
                                  where sm.active and sm.square_variation_id <> ssm.square_variation_id and c.pack_grams > 0
                                    and not pg_temp.exact_ok(retail_price_for_pack(c.pack_cost, c.pack_grams, sm.retail_units_base, ssm.retail_category, ssm.taxable),
                                                             c.pack_cost, c.pack_grams, sm.retail_units_base, 80, false)));
end $T$;

-- =====================================================================================================================
-- 3. synthetic next delivery: a shelf price 5c high, one already right, a missing Square variation, and whole/half items
do $N$
declare a bigint; b bigint; c bigint; x bigint; y bigint; nv bigint := pg_temp.sid('PRSeed NoVar'); r1 jsonb; r2 jsonb; t bigint; tok uuid; res jsonb;
begin
  -- X: 12 for $44.00 each, shelf $6.65 (5c high); Y: 12 kg for $65 per kg, shelf $9.75 (right). Last change 2 days ago.
  x := pg_temp.mk('PRTest Shelf 5c High', 6.65, 44.00, 12, 1, null, null, current_date - 30, 2);
  y := pg_temp.mk('PRTest Shelf Right', 9.75, 65.00, 12000, 1000, null, null, current_date - 30, 2);
  -- A: 12 for $14.00 each, shelf $2.15, half recorded $1.10; B: above the step, 12 for $14.01, shelf $2.10; C: 13 kg $30 per kg, shelf $4.20
  a := pg_temp.mk('PRTest Box12 Each', 2.15, 14.00, 12, 1, 0.5, 1.10, current_date - 30, 2);
  b := pg_temp.mk('PRTest Box12 Above', 2.10, 14.01, 12, 1, null, null, current_date - 30, 2);
  c := pg_temp.mk('PRTest Kg13 Right', 4.20, 30.00, 13000, 1000, null, null, current_date - 30, 2);
  perform pg_temp.ck('next delivery: before it, the 5c-high prices wait (no new cost since the last change); the right ones have nothing to change',
                     (select skip_reason from v_price_rule_candidates where stock_item_id = x) = 'no new supplier cost since the last price change'
                     and (select skip_reason from v_price_rule_candidates where stock_item_id = a) = 'no new supplier cost since the last price change'
                     and not exists (select 1 from v_price_rule_candidates where stock_item_id in (y, c)));

  perform pg_temp.deliver('PRTEST-NEXT-1', pg_temp.sup(2), array[x, y, nv], now());
  perform pg_temp.deliver('PRTEST-NEXT-2', pg_temp.sup(1), array[a, b, c], now());
  perform pg_temp.ck('next delivery: the 5c minimum does not hold back a 5c correction',
                     (select skip_reason is null and change_cents = -5 from v_price_rule_candidates where stock_item_id = x)
                     and (select skip_reason is null and change_cents = -5 from v_price_rule_candidates where stock_item_id = a),
                     (select string_agg(format('%s %s %s', stock_item_id, change_cents, skip_reason), '; ') from v_price_rule_candidates where stock_item_id in (x, a)));

  r1 := produce_price_for_invoice('PRTEST-NEXT-1', false);
  perform pg_temp.ck('next delivery: invoice priced; the 5c-high shelf price $6.65 -> $6.60',
                     (r1->>'ok')::boolean and exists (select 1 from jsonb_array_elements(r1->'applied') e
                                                       where (e->>'stock_item_id')::bigint = x and (e->>'old')::numeric = 6.65 and (e->>'new')::numeric = 6.60),
                     r1::text);
  perform pg_temp.ck('next delivery: a price already on the step stays (no +5c job)',
                     not exists (select 1 from jsonb_array_elements(r1->'applied') e where (e->>'stock_item_id')::bigint = y)
                     and not exists (select 1 from delivery_tasks where source_id = 'PRTEST-NEXT-1' and stock_item_id = y and kind = 'tag'));
  perform pg_temp.ck('missing variation: listed as failed for that item only; the rest of the invoice is priced',
                     exists (select 1 from jsonb_array_elements(r1->'failed') e where (e->>'stock_item_id')::bigint = nv and e->>'error' = 'no real Square variation id')
                     and exists (select 1 from delivery_tasks where source_id = 'PRTEST-NEXT-1' and stock_item_id = nv and kind = 'hold')
                     and exists (select 1 from produce_price_runs where source_id = 'PRTEST-NEXT-1'), r1::text);
  perform pg_temp.ck('missing variation (dry run): listed as failed, not as a tag change',
                     exists (select 1 from jsonb_array_elements(produce_price_items('PRTEST-NEXT-1', array[nv], true)->'failed') e where (e->>'stock_item_id')::bigint = nv)
                     and jsonb_array_length(produce_price_items('PRTEST-NEXT-1', array[nv], true)->'applied') = 0);
  perform pg_temp.ck('next delivery: the correction waits for staff confirm (expected 665 -> 660); shelf price untouched',
                     exists (select 1 from delivery_tasks t join price_apply_op o on o.task_id = t.id
                              where t.source_id = 'PRTEST-NEXT-1' and t.stock_item_id = x and t.kind = 'tag' and t.price_mode = 'apply_on_confirm'
                                and t.status = 'open' and o.role = 'main' and o.expected_cents = 665 and o.target_cents = 660 and o.state = 'ready')
                     and (select retail_sell_price from stock_items where id = x) = 6.65);

  r2 := produce_price_for_invoice('PRTEST-NEXT-2', false);
  perform pg_temp.ck('next delivery: A $2.15 -> $2.10, B (above the step) $2.10 -> $2.15, C untouched',
                     exists (select 1 from jsonb_array_elements(r2->'applied') e where (e->>'stock_item_id')::bigint = a and (e->>'new')::numeric = 2.10)
                     and exists (select 1 from jsonb_array_elements(r2->'applied') e where (e->>'stock_item_id')::bigint = b and (e->>'new')::numeric = 2.15)
                     and not exists (select 1 from jsonb_array_elements(r2->'applied') e where (e->>'stock_item_id')::bigint = c), r2::text);
  perform pg_temp.ck('next delivery: A half frozen from its recorded $1.10 to the exact $1.05',
                     exists (select 1 from price_apply_op o join delivery_tasks t on t.id = o.task_id
                              where t.source_id = 'PRTEST-NEXT-2' and t.stock_item_id = a and o.role = 'part' and o.expected_cents = 110 and o.target_cents = 105 and o.state = 'ready'),
                     (select jsonb_agg(jsonb_build_object('role', o.role, 'exp', o.expected_cents, 'tgt', o.target_cents, 'state', o.state))
                        from price_apply_op o join delivery_tasks t on t.id = o.task_id where t.source_id = 'PRTEST-NEXT-2' and t.stock_item_id = a)::text);
  perform pg_temp.ck('nothing reached Square while pricing (mock untouched)', (select coalesce(sum(puts), 0) from pr_square) = 0);

  -- staff confirm A's tag: register write goes to the mock only
  select id into t from delivery_tasks where source_id = 'PRTEST-NEXT-2' and stock_item_id = a and kind = 'tag';
  res := delivery_tag_claim(t, 'PRTest Staff');
  tok := (res->>'token')::uuid;
  res := delivery_tag_apply(t, tok, 'PRTest Staff');
  perform pg_temp.ck('staff confirm A: mock Square main 210c and half 105c; shelf $2.10 and half $1.05 recorded',
                     (select cents from pr_square where variation = 'PRTESTMAIN' || lpad(a::text, 12, '0')) = 210
                     and (select cents from pr_square where variation = 'PRTESTPART' || lpad(a::text, 12, '0')) = 105
                     and (select retail_sell_price from stock_items where id = a) = 2.10
                     and (select price from retail_part_variation_price where stock_item_id = a) = 1.05, res::text);
  perform pg_temp.ck('after the correction A is settled: no further change calculated', not exists (select 1 from v_price_rule_candidates where stock_item_id = a));
  perform pg_temp.deliver('PRTEST-NEXT-3', pg_temp.sup(1), array[a, c], now() + interval '1 second');
  r2 := produce_price_for_invoice('PRTEST-NEXT-3', false);
  perform pg_temp.ck('repeat delivery: no tag jobs for A or C', jsonb_array_length(r2->'applied') = 0
                     and not exists (select 1 from delivery_tasks where source_id = 'PRTEST-NEXT-3' and kind = 'tag'), r2::text);
end $N$;

-- =====================================================================================================================
-- 4. queue: isolation, fair order, back-off, parking, recovery
do $Q$
declare d bigint; f text; r jsonb; g1 text := 'PRTEST-GOOD-1'; g2 text := 'PRTEST-GOOD-2'; i int; s1 text := pg_temp.sup(1);
begin
  -- wrapper: the original produce_price_for_invoice, failing on purpose for sources listed in pr_bad
  f := replace((select def from pr_pre_fn where sig = 'ppfi_def'), 'public.produce_price_for_invoice(', 'public.produce_price_for_invoice_prtest_orig(');
  execute f;
  create or replace function public.produce_price_for_invoice(p_source_id text, p_dry_run boolean default true) returns jsonb
  language plpgsql as $w$
  declare r jsonb;
  begin
    if exists (select 1 from pr_bad where source_id = p_source_id and mode = 'early') then raise exception 'PRTEST synthetic failure (before any write)'; end if;
    r := produce_price_for_invoice_prtest_orig(p_source_id, p_dry_run);
    if exists (select 1 from pr_bad where source_id = p_source_id and mode = 'late') then raise exception 'PRTEST synthetic failure (after writes)'; end if;
    return r;
  end $w$;

  update app_config set value = now()::text where key = 'produce_autoprice_since';   -- only this test's new invoices are in the queue
  update app_config set value = 'live' where key = 'produce_autoprice_mode';
  d := pg_temp.mk('PRTest Queue Item', 3.00, 12.00, 6, 1, null, null, current_date - 1, null);   -- calc $3.60
  for i in 1..5 loop
    perform pg_temp.deliver('PRTEST-BAD-' || i, s1, array[d], now() + make_interval(secs => i), false);
    insert into pr_bad values ('PRTEST-BAD-' || i, 'early');
  end loop;
  perform pg_temp.deliver(g1, s1, array[d], now() + interval '10 seconds', false);

  r := produce_price_sweep();
  perform pg_temp.ck('queue pass 1: the 5 oldest (all failing) are tried, each failure recorded, the sweep itself completes',
                     (r->>'failed')::int = 5 and (select count(*) from produce_price_attempts where source_id like 'PRTEST-BAD-%' and attempts = 1
                                                   and next_attempt_at > now() and last_error like '%synthetic failure%') = 5
                     and not exists (select 1 from produce_price_runs where source_id = g1), r::text);
  r := produce_price_sweep();
  perform pg_temp.ck('queue pass 2: failing invoices wait for their back-off; the later good delivery is priced',
                     (r->>'failed')::int = 0 and exists (select 1 from produce_price_runs where source_id = g1)
                     and (select max(attempts) from produce_price_attempts where source_id like 'PRTEST-BAD-%') = 1, r::text);

  update produce_price_attempts set next_attempt_at = now() - interval '1 second' where source_id like 'PRTEST-BAD-%';
  perform pg_temp.deliver(g2, s1, array[d], now() + interval '20 seconds', false);
  r := produce_price_sweep();
  perform pg_temp.ck('queue pass 3: with all 5 failures due again, the new delivery still goes first (never-tried first)',
                     exists (select 1 from produce_price_runs where source_id = g2) and (r->>'failed')::int = 4
                     and (r->'runs'->0) ? g2, r::text);
  perform pg_temp.ck('queue back-off doubles: second failure waits 10 min',
                     (select count(*) from produce_price_attempts where source_id like 'PRTEST-BAD-%' and attempts = 2
                       and next_attempt_at between now() + interval '9 minutes' and now() + interval '11 minutes') = 4);

  -- a failure after partial writes leaves nothing behind (sub-transaction) and the good delivery's job is intact
  update produce_price_attempts set next_attempt_at = now() + interval '1 day' where source_id like 'PRTEST-BAD-%';
  perform pg_temp.deliver('PRTEST-BADLATE-1', s1, array[d], now() + interval '30 seconds', false);
  insert into pr_bad values ('PRTEST-BADLATE-1', 'late');
  r := produce_price_sweep();
  perform pg_temp.ck('queue: a failure after writes is rolled back for that invoice only',
                     (r->>'failed')::int = 1
                     and not exists (select 1 from retail_price_proposal where source = 'PRTEST-BADLATE-1')
                     and not exists (select 1 from delivery_tasks where source_id = 'PRTEST-BADLATE-1')
                     and not exists (select 1 from produce_price_runs where source_id = 'PRTEST-BADLATE-1')
                     and exists (select 1 from retail_price_proposal where source = g2 and stock_item_id = d and status = 'authorised')
                     and exists (select 1 from delivery_tasks where source_id = g2 and stock_item_id = d and kind = 'tag' and status = 'open'), r::text);

  -- parking after 8 tries
  update produce_price_attempts set attempts = 7, next_attempt_at = now() - interval '1 second' where source_id = 'PRTEST-BAD-1';
  update produce_price_attempts set next_attempt_at = now() + interval '1 day' where source_id = 'PRTEST-BADLATE-1';
  r := produce_price_sweep();
  perform pg_temp.ck('queue: parked after 8 failed tries', (select attempts = 8 and parked_at is not null from produce_price_attempts where source_id = 'PRTEST-BAD-1'), r::text);
  update produce_price_attempts set next_attempt_at = now() - interval '1 second' where source_id = 'PRTEST-BAD-1';
  r := produce_price_sweep();
  perform pg_temp.ck('queue: a parked invoice is not retried', (select attempts from produce_price_attempts where source_id = 'PRTEST-BAD-1') = 8, r::text);

  -- recovery: the cause is fixed, the next due try succeeds and the attempt is marked resolved
  delete from pr_bad where source_id = 'PRTEST-BAD-2';
  update produce_price_attempts set next_attempt_at = now() - interval '1 second' where source_id = 'PRTEST-BAD-2';
  r := produce_price_sweep();
  perform pg_temp.ck('queue: a fixed invoice is priced on its next try and marked resolved',
                     exists (select 1 from produce_price_runs where source_id = 'PRTEST-BAD-2')
                     and (select resolved_at is not null from produce_price_attempts where source_id = 'PRTEST-BAD-2'), r::text);
  perform pg_temp.ck('queue: failures are logged in engine_runs (steps_failed)',
                     exists (select 1 from engine_runs where ran_at >= now() and steps_failed > 0 and notes like 'PRODUCE-PRICE%PRTEST-BAD%'));

  -- put the real function back before the rollback section
  execute (select def from pr_pre_fn where sig = 'ppfi_def');
  drop function public.produce_price_for_invoice_prtest_orig(text, boolean);
end $Q$;

-- =====================================================================================================================
-- 5. out-of-date approvals at the real entry points
do $S$
declare e bigint; f bigint; g bigint; h bigint; j bigint; k bigint; l bigint; pe bigint; pf bigint; pg bigint; ph bigint;
        r jsonb; t1 bigint; t2 bigint; t3 bigint; v_other int; s1 text := pg_temp.sup(1);
begin
  -- all: shelf $5.00, 1 for $3.00 -> rules give $5.40, change due
  e := pg_temp.mk('PRTest Stale E', 5.00, 3.00, 1, 1, null, null, current_date - 1, null);
  f := pg_temp.mk('PRTest Current F', 5.00, 3.00, 1, 1, null, null, current_date - 1, null);
  g := pg_temp.mk('PRTest Shelf Moved G', 5.00, 3.00, 1, 1, null, null, current_date - 1, null);
  h := pg_temp.mk('PRTest Open Tag H', 5.00, 3.00, 1, 1, null, null, current_date - 1, null);
  pe := (price_propose(jsonb_build_object('mode', 'pending', 'item', e, 'old', 5.00, 'new', 6.00, 'method', 'band', 'source', 'PRTEST-PEND-E'))->>'proposal')::bigint;
  pf := (price_propose(jsonb_build_object('mode', 'pending', 'item', f, 'old', 5.00, 'new', 5.40, 'method', 'band', 'source', 'PRTEST-PEND-F'))->>'proposal')::bigint;
  pg := (price_propose(jsonb_build_object('mode', 'pending', 'item', g, 'old', 5.00, 'new', 5.40, 'method', 'band', 'source', 'PRTEST-PEND-G'))->>'proposal')::bigint;
  update stock_items set retail_sell_price = 5.20 where id = g;   -- the shelf moved after the proposal was made
  perform price_propose(jsonb_build_object('mode', 'authorised', 'item', h, 'variation', 'PRTESTMAIN' || lpad(h::text, 12, '0'), 'old', 5.00, 'new', 5.40,
                        'method', 'band', 'source', 'PRTEST-DELIVERY-H', 'supplier', s1, 'invoice_date', current_date, 'label', '{}'::jsonb));
  insert into retail_price_proposal (stock_item_id, lane, method, old_price, proposed_price, status, source, basis_date, basis_seq)
  values (h, 'approve', 'band', 5.00, 5.95, 'pending', 'PRTEST-PEND-H', current_date - 5, 0) returning id into ph;

  r := price_proposal_decide(array[pe, pf, pg, ph], 'approved', 'PRTest Josh');
  perform pg_temp.ck('decide: the current proposal is approved; the three out-of-date ones are not',
                     (r->>'rows')::int = 1 and (select status from retail_price_proposal where id = pf) = 'approved'
                     and jsonb_array_length(r->'stale') = 3, r::text);
  perform pg_temp.ck('decide: out-of-date calculation ($6.00 vs $5.40) withdrawn and re-queued at the current $5.40',
                     (select status from retail_price_proposal where id = pe) = 'superseded'
                     and exists (select 1 from jsonb_array_elements(r->'stale') s, retail_price_proposal q
                                  where (s->>'id')::bigint = pe and s->>'reason' = 'calculation changed' and q.id = (s->>'replaced_by')::bigint
                                    and q.status = 'pending' and q.proposed_price = 5.40 and q.stock_item_id = e), r::text);
  perform pg_temp.ck('decide: a moved shelf price withdraws the proposal (reason shelf price changed)',
                     (select status from retail_price_proposal where id = pg) = 'superseded'
                     and exists (select 1 from jsonb_array_elements(r->'stale') s where (s->>'id')::bigint = pg and s->>'reason' = 'shelf price changed'));
  perform pg_temp.ck('decide: an out-of-date proposal never cancels an open delivery tag job (no re-queue)',
                     (select status from retail_price_proposal where id = ph) = 'superseded'
                     and exists (select 1 from jsonb_array_elements(r->'stale') s where (s->>'id')::bigint = ph and s->'replaced_by' = 'null'::jsonb)
                     and exists (select 1 from retail_price_proposal where stock_item_id = h and source = 'PRTEST-DELIVERY-H' and status = 'authorised')
                     and exists (select 1 from delivery_tasks where source_id = 'PRTEST-DELIVERY-H' and stock_item_id = h and status = 'open'));
  r := price_proposal_decide(array[pe], 'rejected', 'PRTest Josh');
  perform pg_temp.ck('decide: rejecting is unchanged (only pending rows)', (r->>'rows')::int = 0);

  -- apply: F is approved and current, then goes out of date before apply
  select count(*) into v_other from retail_price_proposal where status = 'approved' and id <> pf;
  perform pg_temp.ck('apply: no other approved proposals exist (apply only touches this test''s rows)', v_other = 0, v_other::text);
  r := price_proposal_apply(true);
  perform pg_temp.ck('apply (dry run): the current approval would become a tag job',
                     exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'item' = 'PRTest Current F' and x->>'action' = 'would_create_tag_job'), r::text);
  update stock_items set retail_sell_price = 5.10 where id = f;   -- shelf moved after approval
  r := price_proposal_apply(true);
  perform pg_temp.ck('apply (dry run): the now out-of-date approval would be skipped, nothing written',
                     exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'item' = 'PRTest Current F' and x->>'action' = 'would_skip_out_of_date')
                     and (select status from retail_price_proposal where id = pf) = 'approved', r::text);
  r := price_proposal_apply(false);
  perform pg_temp.ck('apply: the out-of-date approval is skipped and makes no tag job',
                     (select status = 'skipped' and skip_reason like 'out of date at apply (shelf price changed)%' from retail_price_proposal where id = pf)
                     and not exists (select 1 from delivery_tasks where stock_item_id = f and kind = 'tag'), r::text);

  -- owner screen (delivery_owner_decide -> delivery_price_decide)
  j := pg_temp.mk('PRTest Hold J', 5.00, 3.00, 1, 1, null, null, current_date - 1, null);
  k := pg_temp.mk('PRTest Hold K', 5.00, 3.00, 1, 1, null, null, current_date - 1, null);
  l := pg_temp.mk('PRTest Hold L', 5.00, 3.00, 1, 1, null, null, current_date - 1, null);
  insert into delivery_tasks (source_id, supplier, invoice_number, invoice_date, department, kind, stock_item_id, square_variation_id, info, status)
  values ('PRTEST-HOLD-1', s1, 'PRTEST-HOLD-1', current_date, 'Grocer', 'hold', j, 'PRTESTMAIN' || lpad(j::text, 12, '0'),
          jsonb_build_object('name', 'PRTest Hold J', 'old', 5.00, 'new', 6.00), 'open') returning id into t1;
  insert into delivery_tasks (source_id, supplier, invoice_number, invoice_date, department, kind, stock_item_id, square_variation_id, info, status)
  values ('PRTEST-HOLD-1', s1, 'PRTEST-HOLD-1', current_date, 'Grocer', 'hold', k, 'PRTESTMAIN' || lpad(k::text, 12, '0'),
          jsonb_build_object('name', 'PRTest Hold K', 'old', 5.00, 'new', 6.00), 'open') returning id into t2;
  insert into delivery_tasks (source_id, supplier, invoice_number, invoice_date, department, kind, stock_item_id, square_variation_id, info, status)
  values ('PRTEST-HOLD-1', s1, 'PRTEST-HOLD-1', current_date, 'Grocer', 'hold', l, 'PRTESTMAIN' || lpad(l::text, 12, '0'),
          jsonb_build_object('name', 'PRTest Hold L', 'old', 4.80, 'new', 5.40), 'open') returning id into t3;

  r := delivery_owner_decide(t1, 'approve', null, 'PRTest Josh');
  perform pg_temp.ck('owner screen: accepting an out-of-date suggestion ($6.00, rules now $5.40) is refused and the job refreshed',
                     r->>'code' = 'stale' and not (r->>'ok')::boolean and (select (info->>'new')::numeric from delivery_tasks where id = t1) = 5.40
                     and (select status from delivery_tasks where id = t1) = 'open'
                     and not exists (select 1 from retail_price_proposal where stock_item_id = j), r::text);
  r := delivery_owner_decide(t1, 'approve', 5.40, 'PRTest Josh');
  perform pg_temp.ck('owner screen: approving the refreshed $5.40 works (tag job, applied on staff confirm)',
                     (r->>'ok')::boolean and (r->>'price')::numeric = 5.40
                     and exists (select 1 from retail_price_proposal where stock_item_id = j and status = 'authorised' and proposed_price = 5.40), r::text);
  r := delivery_owner_decide(t2, 'approve', 5.75, 'PRTest Josh');
  perform pg_temp.ck('owner screen: a price Josh types himself is accepted as typed',
                     (r->>'ok')::boolean and exists (select 1 from retail_price_proposal where stock_item_id = k and status = 'authorised' and proposed_price = 5.75), r::text);
  r := delivery_owner_decide(t3, 'approve', null, 'PRTest Josh');
  perform pg_temp.ck('owner screen: a job made against an old shelf price ($4.80, now $5.00) is refused and refreshed',
                     r->>'code' = 'stale' and (select (info->>'old')::numeric from delivery_tasks where id = t3) = 5.00, r::text);
  r := delivery_owner_decide(t3, 'keep', null, 'PRTest Josh');
  perform pg_temp.ck('owner screen: Keep is unchanged', (r->>'ok')::boolean and r->>'status' = 'kept', r::text);

  -- non-Produce regression: owner screen and apply behave exactly as before (no out-of-date guard)
  declare m bigint; tm bigint; qm bigint;
  begin
    m := pg_temp.mk('PRTest Pantry Hold M', 5.00, 3.00, 1, 1, null, null, current_date - 1, null, 'Pantry');
    insert into delivery_tasks (source_id, supplier, invoice_number, invoice_date, department, kind, stock_item_id, square_variation_id, info, status)
    values ('PRTEST-HOLD-2', s1, 'PRTEST-HOLD-2', current_date, 'Grocer', 'hold', m, 'PRTESTMAIN' || lpad(m::text, 12, '0'),
            jsonb_build_object('name', 'PRTest Pantry Hold M', 'old', 4.80, 'new', 6.00), 'open') returning id into tm;
    r := delivery_owner_decide(tm, 'approve', null, 'PRTest Josh');
    perform pg_temp.ck('non-Produce owner screen: an old suggestion is approved exactly as before (no refusal, no refresh)',
                       (r->>'ok')::boolean and (r->>'price')::numeric = 6.00 and r->>'code' is null
                       and (select info->>'new' from delivery_tasks where id = tm) = '6.00'
                       and exists (select 1 from retail_price_proposal where stock_item_id = m and status = 'authorised' and proposed_price = 6.00), r::text);
  end;

  perform pg_temp.ck('privileges: new functions and the attempts table are not open to anon/authenticated',
                     not has_function_privilege('anon', 'public.price_current_calc(bigint)', 'execute')
                     and not has_function_privilege('authenticated', 'public.price_proposal_staleness(bigint)', 'execute')
                     and not has_function_privilege('anon', 'public.retail_price_for_pack(numeric,numeric,numeric,text,boolean)', 'execute')
                     and not has_function_privilege('anon', 'public.price_guard_applies(bigint)', 'execute')
                     and not has_table_privilege('anon', 'public.produce_price_attempts', 'select')
                     and not has_table_privilege('authenticated', 'public.produce_price_attempts', 'insert'));
  perform pg_temp.ck('price_rules_scan dry run still runs', (price_rules_scan(true)->>'dry_run')::boolean);
end $S$;

-- =====================================================================================================================
-- 6. policy coverage (Codex 28 Nov 14:50): Produce item overrides and category rows are both guarded and re-queued under
--    the item's own policy; an override with lane 'never' is not re-queued. Non-Produce (passthrough) decisions are
--    exactly as before: current AND out-of-date legacy approvals are approved and applied as they always were.
do $L$
declare o1 bigint; o2 bigint; cat bigint; pt bigint; pt2 bigint; q_o1 bigint; q_o2 bigint; q_cat bigint; q_pt bigint; q_pt2 bigint; r jsonb; x record;
begin
  o1 := pg_temp.mk('PRTest Override Approve', 3.90, 2.50, 1, 1, null, null, current_date - 1, null);   -- rules $4.50
  o2 := pg_temp.mk('PRTest Override Never', 3.90, 2.50, 1, 1, null, null, current_date - 1, null);
  cat := pg_temp.mk('PRTest Category Item', 9.00, 5.40, 1, 1, null, null, current_date - 1, null);    -- rules $9.75
  insert into pricing_policy (scope, key, lane, method, min_change_cents, max_change_pct, note) values
    ('stock_item', o1::text, 'approve', 'band', 10, 50, 'PRTest override'), ('stock_item', o2::text, 'never', 'band', 5, 35, 'PRTest override');
  -- packaged (passthrough): shelf $4.00 set when the unit cost was $2.00; cost now 6 for $13.20 = $2.20 -> $4.40
  pt := pg_temp.mk('PRTest Pantry Current', 4.00, 13.20, 6, 1, null, null, current_date - 1, 20, 'Pantry');
  update retail_price_history set unit_cost_at_change = 2.00 where stock_item_id = pt;
  pt2 := pg_temp.mk('PRTest Pantry Stale', 4.00, 13.20, 6, 1, null, null, current_date - 1, 20, 'Pantry');
  update retail_price_history set unit_cost_at_change = 2.00 where stock_item_id = pt2;
  perform pg_temp.ck('fixture: policies resolve as intended (override approve/never, category band, default passthrough)',
                     (select array_agg(policy_source || '/' || lane || '/' || method order by stock_item_id) from v_pricing_policy_for_item where stock_item_id in (o1, o2, cat, pt))
                     = array['stock_item override/approve/band', 'stock_item override/never/band', 'retail_category/approve/band', 'default/approve/passthrough'],
                     (select array_agg(policy_source || '/' || lane || '/' || method order by stock_item_id) from v_pricing_policy_for_item where stock_item_id in (o1, o2, cat, pt))::text);
  perform pg_temp.ck('fixture: rules now give $4.50 (overrides), $9.75 (category), $4.40 (packaged)',
                     (select array_agg(proposed_price order by stock_item_id) from v_price_rule_candidates where stock_item_id in (o1, o2, cat, pt, pt2))
                     = array[4.50, 4.50, 9.75, 4.40, 4.40]::numeric[],
                     (select array_agg(proposed_price order by stock_item_id) from v_price_rule_candidates where stock_item_id in (o1, o2, cat, pt, pt2))::text);

  q_o1  := (price_propose(jsonb_build_object('mode', 'pending', 'item', o1, 'old', 3.90, 'new', 3.60, 'method', 'band', 'lane', 'approve', 'source', 'PRTEST-OLD-O1'))->>'proposal')::bigint;
  q_o2  := (price_propose(jsonb_build_object('mode', 'pending', 'item', o2, 'old', 3.90, 'new', 3.60, 'method', 'band', 'lane', 'approve', 'source', 'PRTEST-OLD-O2'))->>'proposal')::bigint;
  q_cat := (price_propose(jsonb_build_object('mode', 'pending', 'item', cat, 'old', 9.00, 'new', 8.10, 'method', 'band', 'lane', 'approve', 'source', 'PRTEST-OLD-CAT'))->>'proposal')::bigint;
  q_pt  := (price_propose(jsonb_build_object('mode', 'pending', 'item', pt, 'old', 4.00, 'new', 4.40, 'method', 'passthrough', 'lane', 'approve', 'source', 'PRTEST-PT'))->>'proposal')::bigint;
  q_pt2 := (price_propose(jsonb_build_object('mode', 'pending', 'item', pt2, 'old', 4.00, 'new', 4.60, 'method', 'passthrough', 'lane', 'approve', 'source', 'PRTEST-PT2'))->>'proposal')::bigint;

  r := price_proposal_decide(array[q_o1, q_o2, q_cat, q_pt, q_pt2], 'approved', 'PRTest Josh');
  perform pg_temp.ck('policy: non-Produce current and out-of-date legacy proposals are both approved exactly as before',
                     (select count(*) from retail_price_proposal where id in (q_pt, q_pt2) and status = 'approved' and decided_by = 'PRTest Josh') = 2
                     and (r->>'rows')::int = 2
                     and not exists (select 1 from jsonb_to_recordset(r->'stale') s(id bigint) where s.id in (q_pt, q_pt2)), r::text);
  perform pg_temp.ck('policy: out-of-date Produce override and category proposals are refused',
                     (select count(*) from retail_price_proposal where id in (q_o1, q_o2, q_cat) and status = 'superseded') = 3
                     and jsonb_array_length(r->'stale') = 3, r::text);
  for x in select s.*, q.stock_item_id item from jsonb_to_recordset(r->'stale') s(id bigint, replaced_by bigint, now numeric)
             join retail_price_proposal q on q.id = s.id where s.id in (q_o1, q_cat) loop
    perform pg_temp.ck(format('policy: %s re-queued at the current price under its own lane/method', (select name from stock_items where id = x.item)),
                       x.replaced_by is not null and exists (select 1 from retail_price_proposal n join v_pricing_policy_for_item p on p.stock_item_id = n.stock_item_id
                                                               where n.id = x.replaced_by and n.status = 'pending' and n.proposed_price = x.now
                                                                 and n.lane = p.lane and n.method = p.method),
                       (select to_jsonb(n) from retail_price_proposal n where n.id = x.replaced_by)::text);
  end loop;
  perform pg_temp.ck('policy: an override with lane never is withdrawn but not re-queued',
                     exists (select 1 from jsonb_to_recordset(r->'stale') s(id bigint, replaced_by bigint) where s.id = q_o2 and s.replaced_by is null)
                     and not exists (select 1 from retail_price_proposal where stock_item_id = o2 and status = 'pending'));
  -- the non-Produce out-of-date legacy approval is applied exactly as before (a tag job at its approved $4.60)
  r := price_proposal_apply(false);
  perform pg_temp.ck('non-Produce apply: the out-of-date legacy approval is applied exactly as before',
                     (select status = 'superseded' and skip_reason = 'moved to tag confirm' from retail_price_proposal where id = q_pt2)
                     and exists (select 1 from retail_price_proposal where stock_item_id = pt2 and status = 'authorised' and proposed_price = 4.60)
                     and exists (select 1 from delivery_tasks where stock_item_id = pt2 and kind = 'tag' and status = 'open'), r::text);
  perform pg_temp.ck('policy: override rows themselves unchanged',
                     (select count(*) from pricing_policy where scope = 'stock_item' and key in (o1::text, o2::text) and note = 'PRTest override') = 2);
end $L$;
