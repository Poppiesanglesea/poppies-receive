-- Acceptance tests for staged 03 (tag-confirm pricing). Synthetic data only. Square is replaced by pg_temp.square_mock;
-- run ONLY in a disposable database or inside a transaction that is rolled back. Every check raises on failure.
\set ON_ERROR_STOP on
create temp table square_mock (variation_id text primary key, cents int, version bigint default 1, puts int default 0,
  fail_get boolean default false, fail_put boolean default false, lose_response boolean default false);

insert into processed_invoices (source_id, supplier, invoice_number, invoice_date, note, booked_count, department)
values ('inv-1', 'Supplier P', 'P-1', current_date, 'INVOICE', 1, 'Grocer'), ('inv-2', 'Supplier P', 'P-2', current_date, 'INVOICE', 1, 'Grocer');
insert into stock_items (id, name, department, retail_sell_price) select 100 + g, 'Synthetic produce ' || g, 'Grocer', 5.00 from generate_series(0, 9) g;
insert into square_sync_map (stock_item_id, square_variation_id, retail_category)
  select 100 + g, 'VARSYNTH' || lpad(g::text, 16, '0'), 'Produce' from generate_series(0, 9) g;
insert into square_mock (variation_id, cents) select 'VARSYNTH' || lpad(g::text, 16, '0'), 500 from generate_series(0, 9) g;
insert into part_stub values (100, 'VARPARTHALF0000000000000', 2.50, 2.70);
insert into square_mock (variation_id, cents) values ('VARPARTHALF0000000000000', 250);
create or replace function pg_temp.cand(p_item int, p_new numeric, p_exceeds boolean default false) returns void language sql as $$
  delete from v_price_rule_candidates where stock_item_id = p_item;
  insert into v_price_rule_candidates (stock_item_id, name, retail_category, lane, method, policy_source, square_variation_id, anchor_cost, new_cost,
    cost_pct, old_price, proposed_price, price_pct, cogs_pct_after, below_floor, skip_reason, exceeds_max_pct)
  values (p_item, 'Synthetic produce', 'Produce', 'auto', 'band', 'retail_category', 'VARSYNTH' || lpad((p_item - 100)::text, 16, '0'),
          2.8, 3.0, 7, 5.00, p_new, round((p_new - 5) / 5 * 100, 2), 55, false, null, p_exceeds) $$;
create or replace function pg_temp.task(p_item int) returns bigint language sql as $$
  select id from delivery_tasks where stock_item_id = p_item and kind = 'tag' and status = 'open' order by id desc limit 1 $$;
create or replace function pg_temp.puts(p_item int) returns int language sql as $$
  select puts from square_mock where variation_id = 'VARSYNTH' || lpad((p_item - 100)::text, 16, '0') $$;
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
  begin if not coalesce(c, false) then raise exception 'FAIL: %', msg; end if; raise notice 'pass: %', msg; end $$;

-- T1 invoice arrival creates proposal + tag job, no register write; parts frozen
select pg_temp.cand(100, 5.40);
select produce_price_items('inv-1', array[100::bigint], false);
select pg_temp.ok(pg_temp.puts(100) = 0, 'T1 invoice arrival does not write the register');
select pg_temp.ok((select status from retail_price_proposal where stock_item_id = 100 order by id desc limit 1) = 'authorised', 'T1 proposal authorised');
select pg_temp.ok((select price_mode = 'apply_on_confirm' and apply_state = 'ready' from delivery_tasks where id = pg_temp.task(100)), 'T1 apply-on-confirm tag job');
select pg_temp.ok((select jsonb_array_length(parts) = 1 and (parts->0->>'to')::numeric = 2.70 from retail_price_proposal where stock_item_id = 100 and status = 'authorised'), 'T1 part price frozen on proposal');
-- T2 staff confirm applies, reads back, completes, applies frozen part
create temp table t2 as select pg_temp.task(100) id;
select delivery_tag_confirm((select id from t2), 'Staff A');
select pg_temp.ok((select cents from square_mock where variation_id = 'VARSYNTH0000000000000000') = 540, 'T2 register updated to proposal');
select pg_temp.ok(pg_temp.puts(100) = 1, 'T2 exactly one write');
select pg_temp.ok((select status = 'done' and apply_state = 'applied' and done_by = 'Staff A' from delivery_tasks where id = (select id from t2)), 'T2 job done with staff recorded');
select pg_temp.ok((select retail_sell_price from stock_items where id = 100) = 5.40, 'T2 stored sell price updated');
select pg_temp.ok((select cents from square_mock where variation_id = 'VARPARTHALF0000000000000') = 270, 'T2 frozen half price applied');
select pg_temp.ok((select outcome from price_apply_audit where task_id = (select id from t2) order by id desc limit 1) = 'applied', 'T2 audit row');
-- T3 double click / retry after success is idempotent
select delivery_tag_confirm((select id from t2), 'Staff A');
select pg_temp.ok(pg_temp.puts(100) = 1, 'T3 second confirm does not write again');
-- T4 legacy tag-only job never writes
insert into delivery_tasks (source_id, kind, stock_item_id, square_variation_id, price_mode, info) values ('old-1', 'tag', 101, 'VARSYNTH0000000000000001', 'tag_only', '{}');
select delivery_tag_confirm((select id from delivery_tasks where source_id = 'old-1'), 'Staff A');
select pg_temp.ok(pg_temp.puts(101) = 0 and (select status from delivery_tasks where source_id = 'old-1') = 'done', 'T4 tag-only job completes without a register write');
-- T5 newer invoice supersedes older proposal; old job cannot write
select pg_temp.cand(102, 5.40); select produce_price_items('inv-1', array[102::bigint], false);
create temp table t5 as select pg_temp.task(102) id;
select pg_temp.cand(102, 5.60); select produce_price_items('inv-2', array[102::bigint], false);
select pg_temp.ok((select status from delivery_tasks where id = (select id from t5)) = 'superseded', 'T5 old job superseded');
select delivery_tag_confirm((select id from t5), 'Staff A');
select pg_temp.ok(pg_temp.puts(102) = 0, 'T5 superseded job does not write');
select delivery_tag_confirm(pg_temp.task(102), 'Staff A');
select pg_temp.ok((select cents from square_mock where variation_id = 'VARSYNTH0000000000000002') = 560, 'T5 newest proposal applies');
-- T6 register changed elsewhere -> conflict, no write
select pg_temp.cand(103, 5.40); select produce_price_items('inv-1', array[103::bigint], false);
update square_mock set cents = 777 where variation_id = 'VARSYNTH0000000000000003';
select delivery_tag_confirm(pg_temp.task(103), 'Staff A');
select pg_temp.ok(pg_temp.puts(103) = 0 and (select apply_state from delivery_tasks where stock_item_id = 103 and kind = 'tag') = 'conflict', 'T6 conflict, no write');
-- T7 ambiguous write (timeout after Square applied): op key kept; retry reconciles from read, no second write
select pg_temp.cand(104, 5.40); select produce_price_items('inv-1', array[104::bigint], false);
create temp table t7 as select pg_temp.task(104) id;
update square_mock set lose_response = true where variation_id = 'VARSYNTH0000000000000004';
select delivery_tag_confirm((select id from t7), 'Staff A');
create temp table t7k as select op_key from delivery_tasks where id = (select id from t7);
select pg_temp.ok((select apply_state = 'failed' and op_key is not null from delivery_tasks where id = (select id from t7)), 'T7 ambiguous failure keeps op key');
update square_mock set lose_response = false where variation_id = 'VARSYNTH0000000000000004';
select delivery_tag_confirm((select id from t7), 'Staff A');
select pg_temp.ok(pg_temp.puts(104) = 1, 'T7 retry does not write twice');
select pg_temp.ok((select outcome from price_apply_audit where task_id = (select id from t7) order by id desc limit 1) = 'applied_already', 'T7 retry recorded as already applied');
-- T8 definite failure drops op key; retry uses a new operation and succeeds
select pg_temp.cand(105, 5.40); select produce_price_items('inv-1', array[105::bigint], false);
create temp table t8 as select pg_temp.task(105) id;
update square_mock set fail_put = true where variation_id = 'VARSYNTH0000000000000005';
select delivery_tag_confirm((select id from t8), 'Staff A');
select pg_temp.ok((select apply_state = 'failed' and op_key is null from delivery_tasks where id = (select id from t8)), 'T8 definite failure drops op key');
update square_mock set fail_put = false where variation_id = 'VARSYNTH0000000000000005';
select delivery_tag_confirm((select id from t8), 'Staff A');
select pg_temp.ok((select apply_state from delivery_tasks where id = (select id from t8)) = 'applied', 'T8 retry succeeds');
-- T9 over-ceiling move stays with Josh; staff cannot apply it
select pg_temp.cand(106, 9.90, true); select produce_price_items('inv-1', array[106::bigint], false);
select pg_temp.ok((select status from retail_price_proposal where stock_item_id = 106) = 'pending', 'T9 over-ceiling stays pending (owner)');
select pg_temp.ok(not exists (select 1 from delivery_tasks where stock_item_id = 106 and kind = 'tag'), 'T9 no staff tag job for owner-only move');
insert into delivery_tasks (source_id, kind, stock_item_id, square_variation_id, info) values ('inv-1', 'hold', 106, 'VARSYNTH0000000000000006', '{"old":5,"new":9.9}');
select pg_temp.ok((delivery_tag_confirm((select id from delivery_tasks where kind = 'hold' and stock_item_id = 106), 'Staff A')->>'ok')::boolean = false, 'T9 staff confirm refuses an owner hold job');
-- T10 concurrent claim -> busy, no write
select pg_temp.cand(107, 5.40); select produce_price_items('inv-1', array[107::bigint], false);
update delivery_tasks set apply_state = 'applying', claimed_at = now() where id = pg_temp.task(107);
select pg_temp.ok((delivery_tag_confirm(pg_temp.task(107), 'Staff B')->>'status') = 'busy' and pg_temp.puts(107) = 0, 'T10 claimed job reports busy, no write');
-- T11 owner approval authorises, register waits for the tag
select delivery_price_decide((select id from delivery_tasks where kind = 'hold' and stock_item_id = 106), 'approve', 9.50, 'Josh');
select pg_temp.ok(pg_temp.puts(106) = 0, 'T11 owner approval does not write the register');
select pg_temp.ok((select status from retail_price_proposal where stock_item_id = 106 order by id desc limit 1) = 'authorised', 'T11 owner price authorised');
select delivery_tag_confirm(pg_temp.task(106), 'Staff A');
select pg_temp.ok((select cents from square_mock where variation_id = 'VARSYNTH0000000000000006') = 950, 'T11 staff confirm applies the owner price');
-- T12 nightly rules and approved queue create tag jobs, never write
select pg_temp.cand(108, 5.40); select price_rules_scan(false);
select pg_temp.ok(pg_temp.puts(108) = 0 and pg_temp.task(108) is not null, 'T12 nightly auto lane creates a tag job, no write');
insert into retail_price_proposal (stock_item_id, lane, method, old_price, proposed_price, status) values (109, 'approve', 'band', 5.00, 5.30, 'approved');
select price_proposal_apply(false);
select pg_temp.ok(pg_temp.puts(109) = 0 and pg_temp.task(109) is not null, 'T12 approved queue creates a tag job, no write');
-- T13 staff list exposes the price fields
select pg_temp.ok((select delivery_tasks_list()::text like '%"price_mode": "apply_on_confirm"%'), 'T13 list shows price mode');
select pg_temp.ok(not exists (select 1 from square_mock where puts > 1), 'no variation was written more than once');
