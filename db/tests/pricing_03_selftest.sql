-- Acceptance tests for staged 03 (tag-confirm pricing). Synthetic data only. Run with db/tests/run_local.sh, which builds
-- a disposable database from db/tests/local/base.sql, applies 01/02/03 and points the Square mock at a separate mock
-- database (db/tests/local/square_mock_store.sql) through dblink, so "Square" writes survive a rollback here exactly
-- like real external calls. Every check raises 'FAIL: ...' on failure; the runner requires zero errors.
\set ON_ERROR_STOP off
select set_config('test.mock_conn', :'mock_conn', false);

\ir local/mock_session.sql
\ir local/test_helpers.sql

-- fixtures
insert into suppliers (id, name) values (1, 'Supplier P');
insert into processed_invoices (source_id, supplier, invoice_number, invoice_date, note, booked_count, department) values
  ('inv-1', 'Supplier P', 'P-1', '2026-11-20', 'INVOICE', 1, 'Grocer'),
  ('inv-2', 'Supplier P', 'P-2', '2026-11-22', 'INVOICE', 1, 'Grocer'),
  ('inv-0', 'Supplier P', 'P-0', '2026-11-10', 'INVOICE', 1, 'Grocer');   -- booked last, dated first
insert into stock_items (id, name, department, retail_sell_price, count_unit) select 100 + g, 'Synthetic produce ' || g, 'Grocer', 5.00, 'kg' from generate_series(0, 29) g;
insert into square_sync_map (stock_item_id, square_variation_id, retail_category) select 100 + g, pg_temp.v(100 + g), 'Produce' from generate_series(0, 29) g;
select pg_temp.mx('insert into square (variation_id, cents) select ''VARSYNTH'' || lpad(g::text, 16, ''0''), 500 from generate_series(0, 29) g');
-- halves: item 100/101/102 have recorded half prices; item 110's half has never had a recorded price
insert into square_variation_identity values ('VARHALF100XXXXXXXXXXXX', 'Synthetic produce 0', 'Half'), ('VARHALF101XXXXXXXXXXXX', 'Synthetic produce 1', 'Half'),
  ('VARHALF102XXXXXXXXXXXX', 'Synthetic produce 2', 'Half'), ('VARHALF110XXXXXXXXXXXX', 'Synthetic produce 10', 'Half');
insert into retail_part_variation_price (square_variation_id, stock_item_id, price) values
  ('VARHALF100XXXXXXXXXXXX', 100, 2.50), ('VARHALF101XXXXXXXXXXXX', 101, 2.50), ('VARHALF102XXXXXXXXXXXX', 102, 2.50);
insert into test_part_prices values (100, 'VARHALF100XXXXXXXXXXXX', 2.70), (101, 'VARHALF101XXXXXXXXXXXX', 2.70),
  (102, 'VARHALF102XXXXXXXXXXXX', 2.70), (110, 'VARHALF110XXXXXXXXXXXX', 2.70);
select pg_temp.mx('insert into square (variation_id, cents) values (''VARHALF100XXXXXXXXXXXX'', 250), (''VARHALF101XXXXXXXXXXXX'', 260),
  (''VARHALF102XXXXXXXXXXXX'', 250), (''VARHALF110XXXXXXXXXXXX'', 999)');

-- T1 invoice arrival through the full production caller chain (produce_price_for_invoice -> produce_price_items ->
-- delivery_tasks_add): proposal + apply-on-confirm job + frozen operations; nothing written; legacy add doesn't reset
select pg_temp.cand(100, 5.40);
select pg_temp.deliver('inv-1', array[100]);
select pg_temp.ok(pg_temp.mq(pg_temp.v(100), 'puts') = 0, 'T1 invoice arrival does not write the register');
select pg_temp.ok((select count(*) = 1 from delivery_tasks where stock_item_id = 100 and kind = 'tag'), 'T1 one tag job (legacy add did not duplicate)');
select pg_temp.ok((select price_mode = 'apply_on_confirm' and apply_state = 'ready' and proposal_id is not null from delivery_tasks where id = pg_temp.task(100)),
                  'T1 legacy delivery_tasks_add left the apply-on-confirm job intact');
select pg_temp.ok((select count(*) = 2 and bool_and(state = 'ready') from price_apply_op where task_id = pg_temp.task(100)), 'T1 main + half operations persisted before any write');
select pg_temp.ok((select expected_cents = 250 and target_cents = 270 and label->>'name' = 'Synthetic produce 0 – Half' from price_apply_op where task_id = pg_temp.task(100) and role = 'part'),
                  'T1 half frozen with its recorded price and a staff label');
-- T2 confirm applies main then half, each once, read back, job done
create temp table t2 as select pg_temp.task(100) id;
select pg_temp.confirm((select id from t2));
select pg_temp.ok(pg_temp.mq(pg_temp.v(100), 'cents') = 540 and pg_temp.mq(pg_temp.v(100), 'puts') = 1, 'T2 register main price updated once');
select pg_temp.ok(pg_temp.mq('VARHALF100XXXXXXXXXXXX', 'cents') = 270 and pg_temp.mq('VARHALF100XXXXXXXXXXXX', 'puts') = 1, 'T2 half updated once');
select pg_temp.ok((select status = 'done' and apply_state = 'applied' and done_by = 'Staff A' from delivery_tasks where id = (select id from t2)), 'T2 job done with staff recorded');
select pg_temp.ok((select retail_sell_price = 5.40 from stock_items where id = 100), 'T2 stored sell price updated');
select pg_temp.ok((select status = 'applied' from retail_price_proposal where id = (select proposal_id from delivery_tasks where id = (select id from t2))), 'T2 proposal applied');
select pg_temp.ok((select count(*) filter (where outcome = 'applied') = 2 from price_apply_audit where task_id = (select id from t2)), 'T2 audit per variation');
-- T3 second confirm and an invoice replay are no-ops
select pg_temp.confirm((select id from t2));
select produce_price_items('inv-1', array[100::bigint], false);
select pg_temp.ok(pg_temp.mq(pg_temp.v(100), 'puts') = 1 and (select count(*) = 1 from delivery_tasks where stock_item_id = 100 and kind = 'tag')
                  and (select count(*) = 1 from retail_price_proposal where stock_item_id = 100), 'T3 repeat confirm / invoice replay change nothing');
-- T4 legacy tag-only job never writes
insert into delivery_tasks (source_id, kind, stock_item_id, square_variation_id, price_mode, info) values ('old-1', 'tag', 119, pg_temp.v(119), 'tag_only', '{}');
select pg_temp.confirm((select id from delivery_tasks where source_id = 'old-1'));
select pg_temp.ok(pg_temp.mq(pg_temp.v(119), 'puts') = 0 and (select status from delivery_tasks where source_id = 'old-1') = 'done', 'T4 tag-only job completes without a register write');
-- T5 newer invoice supersedes older proposal; old job cannot write
select pg_temp.cand(103, 5.40); select produce_price_items('inv-1', array[103::bigint], false);
create temp table t5 as select pg_temp.task(103) id;
select pg_temp.cand(103, 5.60); select produce_price_items('inv-2', array[103::bigint], false);
select pg_temp.ok((select status = 'superseded' from delivery_tasks where id = (select id from t5)), 'T5 old job superseded');
select pg_temp.confirm((select id from t5));
select pg_temp.ok(pg_temp.mq(pg_temp.v(103), 'puts') = 0, 'T5 superseded job does not write');
select pg_temp.confirm(pg_temp.task(103));
select pg_temp.ok(pg_temp.mq(pg_temp.v(103), 'cents') = 560, 'T5 newest proposal applies');
-- T6 register changed elsewhere -> conflict, no write
select pg_temp.cand(104, 5.40); select produce_price_items('inv-1', array[104::bigint], false);
select pg_temp.mx('update square set cents = 777 where variation_id = ''VARSYNTH0000000000000004''');
select pg_temp.confirm(pg_temp.task(104));
select pg_temp.ok(pg_temp.mq(pg_temp.v(104), 'puts') = 0 and (select apply_state from delivery_tasks where id = pg_temp.task(104)) = 'conflict', 'T6 conflict, no write');
-- T7 timeout after Square applied: same operation key kept; retry reconciles from a read, no second write
select pg_temp.cand(105, 5.40); select produce_price_items('inv-1', array[105::bigint], false);
select pg_temp.mx('update square set lose_response = true where variation_id = ''VARSYNTH0000000000000005''');
select pg_temp.confirm(pg_temp.task(105));
create temp table t7 as select price_op_key(id, gen) idem_key from price_apply_op where task_id = pg_temp.task(105) and role = 'main';
select pg_temp.ok((select state = 'ambiguous' from price_apply_op where task_id = pg_temp.task(105) and role = 'main'), 'T7 timeout recorded as ambiguous');
select pg_temp.mx('update square set lose_response = false where variation_id = ''VARSYNTH0000000000000005''');
select pg_temp.confirm(pg_temp.task(105));
select pg_temp.ok(pg_temp.mq(pg_temp.v(105), 'puts') = 1 and (select apply_state = 'applied' from delivery_tasks where id = pg_temp.task(105)), 'T7 retry completes without a second write');
select pg_temp.ok((select price_op_key(id, gen) = (select idem_key from t7) from price_apply_op where task_id = pg_temp.task(105) and role = 'main'), 'T7 operation key unchanged');
-- T8 definite failure -> new operation generation; retry succeeds
select pg_temp.cand(106, 5.40); select produce_price_items('inv-1', array[106::bigint], false);
select pg_temp.mx('update square set fail_put = true where variation_id = ''VARSYNTH0000000000000006''');
select pg_temp.confirm(pg_temp.task(106));
select pg_temp.ok((select state = 'failed' and gen = 1 from price_apply_op where task_id = pg_temp.task(106) and role = 'main'), 'T8 definite failure moves to a new operation generation');
select pg_temp.mx('update square set fail_put = false where variation_id = ''VARSYNTH0000000000000006''');
select pg_temp.confirm(pg_temp.task(106));
select pg_temp.ok((select apply_state from delivery_tasks where id = pg_temp.task(106)) = 'applied', 'T8 retry succeeds');
-- T9 over-ceiling move stays with Josh; staff cannot apply it
select pg_temp.cand(107, 9.90, true); select pg_temp.deliver('inv-1', array[107]);
select pg_temp.ok((select status from retail_price_proposal where stock_item_id = 107) = 'pending', 'T9 over-ceiling stays pending (owner)');
select pg_temp.ok(not exists (select 1 from delivery_tasks where stock_item_id = 107 and kind = 'tag'), 'T9 no staff tag job for owner-only move');
select pg_temp.ok((pg_temp.confirm((select id from delivery_tasks where kind = 'hold' and stock_item_id = 107))->>'ok')::boolean = false, 'T9 staff confirm refuses an owner hold job');
-- T10 claimed job reports busy, no write
select pg_temp.cand(108, 5.40); select produce_price_items('inv-1', array[108::bigint], false);
select delivery_tag_claim(pg_temp.task(108), 'Staff A');
select pg_temp.ok((pg_temp.confirm(pg_temp.task(108), 'Staff B')->>'status') = 'busy' and pg_temp.mq(pg_temp.v(108), 'puts') = 0, 'T10 claimed job reports busy, no write');
-- T11 owner approval authorises; register waits for the tag
select delivery_price_decide((select id from delivery_tasks where kind = 'hold' and stock_item_id = 107), 'approve', 9.50, 'Josh');
select pg_temp.ok(pg_temp.mq(pg_temp.v(107), 'puts') = 0 and (select status from retail_price_proposal where stock_item_id = 107 order by id desc limit 1) = 'authorised',
                  'T11 owner approval authorises without writing');
select pg_temp.confirm(pg_temp.task(107));
select pg_temp.ok(pg_temp.mq(pg_temp.v(107), 'cents') = 950, 'T11 staff confirm applies the owner price');
-- T12 nightly rules and approved queue create tag jobs, never write
delete from v_price_rule_candidates; select pg_temp.cand(109, 5.40); select price_rules_scan(false);
select pg_temp.ok(pg_temp.mq(pg_temp.v(109), 'puts') = 0 and pg_temp.task(109) is not null, 'T12 nightly auto lane creates a tag job, no write');
insert into retail_price_proposal (stock_item_id, lane, method, old_price, proposed_price, status) values (111, 'approve', 'band', 5.00, 5.30, 'approved');
delete from v_price_rule_candidates;
select price_proposal_apply(false);
select pg_temp.ok(pg_temp.mq(pg_temp.v(111), 'puts') = 0 and pg_temp.task(111) is not null, 'T12 approved queue creates a tag job, no write');

-- B1 half/quarter failures keep the job open (partial), retry only what is unresolved
select pg_temp.cand(101, 5.40); select produce_price_items('inv-1', array[101::bigint], false);   -- half is at 2.60, frozen expected 2.50
select pg_temp.ok((pg_temp.confirm(pg_temp.task(101))->>'ok')::boolean = false, 'B1 confirm with a conflicting half does not report success');
select pg_temp.ok((select status = 'open' and apply_state = 'partial' from delivery_tasks where id = pg_temp.task(101)), 'B1 job stays open as partial');
select pg_temp.ok(pg_temp.mq(pg_temp.v(101), 'cents') = 540 and pg_temp.mq('VARHALF101XXXXXXXXXXXX', 'puts') = 0, 'B1 main applied, conflicting half untouched');
select pg_temp.ok((select status = 'authorised' from retail_price_proposal where id = (select proposal_id from delivery_tasks where id = pg_temp.task(101))), 'B1 proposal not marked applied');
select pg_temp.ok(exists (select 1 from price_apply_audit where task_id = pg_temp.task(101) and outcome = 'conflict' and square_variation_id = 'VARHALF101XXXXXXXXXXXX'), 'B1 half conflict audited');
select pg_temp.cand(102, 5.40); select produce_price_items('inv-1', array[102::bigint], false);
select pg_temp.mx('update square set fail_put = true where variation_id = ''VARHALF102XXXXXXXXXXXX''');
select pg_temp.confirm(pg_temp.task(102));
select pg_temp.ok((select apply_state = 'partial' from delivery_tasks where id = pg_temp.task(102)), 'B1 failed half -> partial');
select pg_temp.mx('update square set fail_put = false where variation_id = ''VARHALF102XXXXXXXXXXXX''');
select pg_temp.confirm(pg_temp.task(102));
select pg_temp.ok(pg_temp.mq(pg_temp.v(102), 'puts') = 1 and pg_temp.mq('VARHALF102XXXXXXXXXXXX', 'cents') = 270
                  and (select status = 'done' from delivery_tasks where id = pg_temp.task(102)), 'B1 retry writes only the half, then completes');
-- B2 crash after Square accepted the write: the operation identity and the claim survive the rollback
select pg_temp.cand(112, 5.40); select produce_price_items('inv-1', array[112::bigint], false);
create temp table b2 as select pg_temp.task(112) id, (delivery_tag_claim(pg_temp.task(112), 'Staff A')->>'token')::uuid token;
begin;
select delivery_tag_apply((select id from b2), (select token from b2), 'Staff A');
rollback;   -- simulated crash/rollback after the external write
select pg_temp.ok(pg_temp.mq(pg_temp.v(112), 'cents') = 540, 'B2 (setup) Square took the write before the rollback');
select pg_temp.ok((select state = 'applying' and gen = 0 from price_apply_op where task_id = (select id from b2) and role = 'main'), 'B2 claimed operation survives the rollback');
select pg_temp.ok(exists (select 1 from price_apply_audit where task_id = (select id from b2) and outcome = 'claimed' and idem_key is not null), 'B2 claim audit survives the rollback');
select pg_temp.ok((pg_temp.confirm((select id from b2))->>'status') = 'busy', 'B2 immediate retry waits for the claim to expire');
update price_apply_op set claimed_at = now() - interval '3 minutes' where task_id = (select id from b2);
update delivery_tasks set claimed_at = now() - interval '3 minutes' where id = (select id from b2);
select pg_temp.confirm((select id from b2));
select pg_temp.ok(pg_temp.mq(pg_temp.v(112), 'puts') = 1 and (select apply_state = 'applied' from delivery_tasks where id = (select id from b2)), 'B2 retry reconciles, no second write');
select pg_temp.ok(exists (select 1 from price_apply_audit where task_id = (select id from b2) and outcome = 'applied_already'), 'B2 reconciliation audited');
select pg_temp.cand(113, 5.40); select produce_price_items('inv-1', array[113::bigint], false);
select pg_temp.mx('update square set raise_after_write = true where variation_id = ''VARSYNTH0000000000000013''');
select pg_temp.confirm(pg_temp.task(113));
select pg_temp.ok((select state = 'ambiguous' from price_apply_op where task_id = pg_temp.task(113) and role = 'main')
                  and (select apply_state = 'failed' and status = 'open' from delivery_tasks where id = pg_temp.task(113)), 'B2 error after write recorded as ambiguous, job open');
select pg_temp.mx('update square set raise_after_write = false where variation_id = ''VARSYNTH0000000000000013''');
select pg_temp.confirm(pg_temp.task(113));
select pg_temp.ok(pg_temp.mq(pg_temp.v(113), 'puts') = 1 and (select apply_state = 'applied' from delivery_tasks where id = pg_temp.task(113)), 'B2 retry after error: no second write');
-- B3 chronology and replay
select pg_temp.cand(114, 5.60); select pg_temp.deliver('inv-2', array[114]);
select pg_temp.cand(114, 5.40); select pg_temp.deliver('inv-0', array[114]);                     -- older invoice booked later
select pg_temp.ok(not exists (select 1 from delivery_tasks where stock_item_id = 114 and source_id = 'inv-0'), 'B3 older invoice creates no tag job');
select pg_temp.ok((select status = 'open' and apply_state = 'ready' from delivery_tasks where stock_item_id = 114 and source_id = 'inv-2'), 'B3 newer job still current');
select pg_temp.ok((select status = 'skipped' from retail_price_proposal where stock_item_id = 114 and source = 'inv-0'), 'B3 older proposal recorded as skipped');
select pg_temp.cand(115, 5.40); select produce_price_items('inv-1', array[115::bigint], false);
create temp table b3 as select pg_temp.task(115) id;
select pg_temp.cand(115, 9.90, true); select pg_temp.deliver('inv-2', array[115]);           -- newer, over the ceiling
select pg_temp.ok((select status = 'superseded' from delivery_tasks where id = (select id from b3)), 'B3 newer held price supersedes the authorised job');
select pg_temp.confirm((select id from b3));
select pg_temp.ok(pg_temp.mq(pg_temp.v(115), 'puts') = 0, 'B3 old job cannot apply after a newer held price');
select delivery_price_decide((select id from delivery_tasks where kind = 'hold' and stock_item_id = 115 and status = 'open'), 'keep', null, 'Josh');
select pg_temp.cand(115, 5.20); select produce_price_items('inv-0', array[115::bigint], false);   -- older invoice after Keep
select pg_temp.ok(not exists (select 1 from delivery_tasks where stock_item_id = 115 and status = 'open'), 'B3 nothing reopens after Keep');
select produce_price_items('inv-1', array[115::bigint], false);                                   -- replay of the superseded invoice
select pg_temp.ok((select count(*) = 1 from retail_price_proposal where stock_item_id = 115 and source = 'inv-1'), 'B3 replay does not recreate a proposal');
select pg_temp.ok(pg_temp.mq(pg_temp.v(115), 'puts') = 0, 'B3 register untouched throughout');
-- B3 newer proposal between claim and apply -> apply refuses before any write
select pg_temp.cand(116, 5.40); select produce_price_items('inv-1', array[116::bigint], false);
create temp table b3b as select pg_temp.task(116) id, (delivery_tag_claim(pg_temp.task(116), 'Staff A')->>'token')::uuid token;
select pg_temp.cand(116, 5.60); select produce_price_items('inv-2', array[116::bigint], false);
select pg_temp.ok((delivery_tag_apply((select id from b3b), (select token from b3b), 'Staff A')->>'status') = 'superseded' and pg_temp.mq(pg_temp.v(116), 'puts') = 0,
                  'B3 apply after a newer price arrived does not write');
select pg_temp.ok((select bool_and(state = 'superseded') from price_apply_op o join retail_price_proposal q on q.id = o.proposal_id
                    where o.task_id = (select id from b3b)), 'B3 claimed operations closed as not written (not left in doubt)');
select pg_temp.ok(exists (select 1 from price_apply_audit where task_id = (select id from b3b) and outcome = 'superseded_before_write'), 'B3 stop before write audited');
-- B4 half with no recorded price is blocked for Josh, never overwritten blindly
select pg_temp.cand(110, 5.40); select produce_price_items('inv-1', array[110::bigint], false);
select pg_temp.ok((select state = 'blocked' from price_apply_op where task_id = pg_temp.task(110) and role = 'part'), 'B4 unknown half price is blocked');
select pg_temp.confirm(pg_temp.task(110));
select pg_temp.ok(pg_temp.mq('VARHALF110XXXXXXXXXXXX', 'puts') = 0 and pg_temp.mq('VARHALF110XXXXXXXXXXXX', 'cents') = 999
                  and (select apply_state = 'partial' from delivery_tasks where id = pg_temp.task(110)), 'B4 main applied, blocked half untouched, job partial');
select price_op_resolve((select id from price_apply_op where task_id = pg_temp.task(110) and role = 'part'), 'overwrite', 999, 'Josh');
select pg_temp.confirm(pg_temp.task(110));
select pg_temp.ok(pg_temp.mq('VARHALF110XXXXXXXXXXXX', 'cents') = 270 and (select status = 'done' from delivery_tasks where id = pg_temp.task(110)),
                  'B4 after Josh confirms the current half price, the tag confirm applies it');
-- B5 transition: an older open tag-only reminder is closed by a newer authorised price (and never writes); a newer
--    held (owner) price leaves it, because the register still shows that price
insert into delivery_tasks (source_id, kind, stock_item_id, square_variation_id, price_mode, info) values
  ('old-120', 'tag', 120, pg_temp.v(120), 'tag_only', '{"old": 4.5, "new": 5}'), ('old-121', 'tag', 121, pg_temp.v(121), 'tag_only', '{"old": 4.5, "new": 5}');
select pg_temp.cand(120, 5.40); select produce_price_items('inv-1', array[120::bigint], false);
select pg_temp.ok((select status = 'superseded' from delivery_tasks where source_id = 'old-120'), 'B5 older tag-only reminder superseded by a newer authorised price');
select pg_temp.ok((pg_temp.confirm((select id from delivery_tasks where source_id = 'old-120'))->>'status') = 'superseded'
                  and (select status = 'superseded' from delivery_tasks where source_id = 'old-120'), 'B5 superseded reminder cannot be ticked back to done');
select pg_temp.cand(121, 9.90, true); select produce_price_items('inv-1', array[121::bigint], false);
select pg_temp.ok((select status = 'open' from delivery_tasks where source_id = 'old-121'), 'B5 a held owner price leaves the current reminder open');
select pg_temp.ok(pg_temp.mq(pg_temp.v(120), 'puts') = 0 and pg_temp.mq(pg_temp.v(121), 'puts') = 0, 'B5 no register writes from tag-only jobs');
-- B6 unknown-price half: owner 'skip' closes it without inventing a price; job completes
insert into square_variation_identity values ('VARHALF122XXXXXXXXXXXX', 'Synthetic produce 22', 'Half'), ('VARHALF123XXXXXXXXXXXX', 'Synthetic produce 23', 'Half'),
  ('VARHALF124XXXXXXXXXXXX', 'Synthetic produce 24', 'Half'), ('VARHALF125XXXXXXXXXXXX', 'Synthetic produce 25', 'Half');
insert into test_part_prices values (122, 'VARHALF122XXXXXXXXXXXX', 2.70), (123, 'VARHALF123XXXXXXXXXXXX', 2.70), (124, 'VARHALF124XXXXXXXXXXXX', 2.70), (125, 'VARHALF125XXXXXXXXXXXX', 2.70);
select pg_temp.mx('insert into square (variation_id, cents) values (''VARHALF122XXXXXXXXXXXX'', 300), (''VARHALF123XXXXXXXXXXXX'', 300), (''VARHALF124XXXXXXXXXXXX'', 300), (''VARHALF125XXXXXXXXXXXX'', 300)');
select pg_temp.cand(122, 5.40); select produce_price_items('inv-1', array[122::bigint], false);
select pg_temp.confirm(pg_temp.task(122));
select pg_temp.ok((price_op_resolve((select id from price_apply_op where task_id = pg_temp.task(122) and role = 'part'), 'skip', 300, 'Josh')->'task'->>'status') = 'restore',
                  'B6 owner skip after staff changed the tags: staff asked to put the half tag back');
select pg_temp.ok((select (p->>'restore')::boolean and (p->>'restore_to')::numeric = 3.00
                     from jsonb_array_elements(delivery_tasks_list()) c, jsonb_array_elements(c->'tasks') t, jsonb_array_elements(t->'parts') p
                    where (t->>'id')::bigint = pg_temp.task(122)), 'B6 list tells staff the register price to put back ($3.00)');
select pg_temp.ok((pg_temp.confirm(pg_temp.task(122))->>'status') = 'done', 'B6 staff confirm the tag is back: job completes');
select pg_temp.ok(exists (select 1 from price_apply_audit where task_id = pg_temp.task(122) and outcome = 'tag_restored'), 'B6 restore audited');
select pg_temp.ok((select state = 'skipped' and expected_cents is null from price_apply_op where task_id = pg_temp.task(122) and role = 'part')
                  and pg_temp.mq('VARHALF122XXXXXXXXXXXX', 'puts') = 0, 'B6 half left as is, no price invented');
-- B7 unknown-price half superseded by a newer price (blocked -> superseded is allowed)
select pg_temp.cand(123, 5.40); select produce_price_items('inv-1', array[123::bigint], false);
create temp table b7 as select pg_temp.task(123) id;
select pg_temp.cand(123, 5.60); select produce_price_items('inv-2', array[123::bigint], false);
select pg_temp.ok((select state = 'superseded' from price_apply_op where task_id = (select id from b7) and role = 'part'), 'B7 blocked half superseded by a newer price');
-- B7b owner Keep on a newer held price also closes an older authorised job with a blocked half
select pg_temp.cand(124, 5.40); select produce_price_items('inv-1', array[124::bigint], false);
create temp table b7b as select pg_temp.task(124) id;
select pg_temp.cand(124, 9.90, true); select pg_temp.deliver('inv-2', array[124]);
select delivery_price_decide((select id from delivery_tasks where kind = 'hold' and stock_item_id = 124 and status = 'open'), 'keep', null, 'Josh');
select pg_temp.ok((select state = 'superseded' from price_apply_op where task_id = (select id from b7b) and role = 'part'), 'B7 newer held price + Keep close the blocked half');
-- B8 a delivery card reused by a newer revision: the job only ever reads its CURRENT proposal's operations
select price_propose(jsonb_build_object('mode', 'authorised', 'item', 125, 'variation', pg_temp.v(125), 'old', 5.00, 'new', 5.40, 'source', 'rev:1',
       'task_source', 'card-125', 'basis_date', '2026-11-21', 'label', jsonb_build_object('name', 'Synthetic produce 25', 'per', 'per kg')));
create temp table b8 as select id, proposal_id from delivery_tasks where source_id = 'card-125';
select price_propose(jsonb_build_object('mode', 'authorised', 'item', 125, 'variation', pg_temp.v(125), 'old', 5.00, 'new', 5.60, 'source', 'rev:2',
       'task_source', 'card-125', 'basis_date', '2026-11-22', 'label', jsonb_build_object('name', 'Synthetic produce 25', 'per', 'per kg')));
select pg_temp.ok((select id = (select id from b8) and proposal_id <> (select proposal_id from b8) and status = 'open' from delivery_tasks where source_id = 'card-125'),
                  'B8 same card reused with the newer proposal');
select pg_temp.ok((select count(*) = 4 from price_apply_op where task_id = (select id from b8)), 'B8 older revision operations kept as history');
select pg_temp.ok((select jsonb_array_length(t->'parts') = 1 and (t->'main'->>'new')::numeric = 5.60
                     from jsonb_array_elements(delivery_tasks_list()) c, jsonb_array_elements(c->'tasks') t where (t->>'id')::bigint = (select id from b8)),
                  'B8 list shows only the current revision');
select pg_temp.confirm((select id from b8));
select price_op_resolve((select id from price_apply_op where task_id = (select id from b8) and role = 'part' and state = 'blocked'), 'skip', null, 'Josh');
select pg_temp.confirm((select id from b8));   -- tag put back
select pg_temp.ok((select status = 'done' from delivery_tasks where id = (select id from b8)) and pg_temp.mq(pg_temp.v(125), 'cents') = 560,
                  'B8 job completes on the current revision (old superseded operations do not hold it open)');
-- B9 main price changed elsewhere, Josh keeps the register price: staff put the main AND half tags back; no writes
select pg_temp.cand(127, 5.40); insert into square_variation_identity values ('VARHALF127XXXXXXXXXXXX', 'Synthetic produce 27', 'Half');
insert into retail_part_variation_price values ('VARHALF127XXXXXXXXXXXX', 127, 2.50); insert into test_part_prices values (127, 'VARHALF127XXXXXXXXXXXX', 2.70);
select pg_temp.mx('insert into square (variation_id, cents) values (''VARHALF127XXXXXXXXXXXX'', 250)');
select produce_price_items('inv-1', array[127::bigint], false);
select pg_temp.mx('update square set cents = 520 where variation_id = ''VARSYNTH0000000000000027''');
select pg_temp.confirm(pg_temp.task(127));
select pg_temp.ok((select apply_state = 'conflict' from delivery_tasks where id = pg_temp.task(127)), 'B9 (setup) conflict');
select pg_temp.ok((price_op_resolve((select id from price_apply_op where task_id = pg_temp.task(127) and role = 'main'), 'skip', 520, 'Josh')->'task'->>'status') = 'restore',
                  'B9 keep after confirm asks staff to restore tags');
select pg_temp.ok((select (t->'main'->>'restore_to')::numeric = 5.20 and (t->'parts'->0->>'restore_to')::numeric = 2.50
                     from jsonb_array_elements(delivery_tasks_list()) c, jsonb_array_elements(c->'tasks') t where (t->>'id')::bigint = pg_temp.task(127)),
                  'B9 main back to $5.20 (register), half back to $2.50');
select pg_temp.confirm(pg_temp.task(127));
select pg_temp.ok((select status = 'kept' from delivery_tasks where id = pg_temp.task(127)) and pg_temp.mq(pg_temp.v(127), 'puts') = 0
                  and pg_temp.mq('VARHALF127XXXXXXXXXXXX', 'puts') = 0, 'B9 tags restored, job kept, no register writes');
-- B10 Josh keeps before staff ever confirmed: nothing to put back, job closes as kept
select pg_temp.cand(128, 5.40); select produce_price_items('inv-1', array[128::bigint], false);
update price_apply_op set state = 'conflict' where task_id = pg_temp.task(128) and role = 'main';
select pg_temp.ok((price_op_resolve((select id from price_apply_op where task_id = pg_temp.task(128) and role = 'main'), 'skip', null, 'Josh')->'task'->>'status') = 'kept',
                  'B10 keep before any confirm: closed, no restore step');
-- leave one authorised job with a blocked half open, for the rollback check
select pg_temp.cand(126, 5.40); insert into square_variation_identity values ('VARHALF126XXXXXXXXXXXX', 'Synthetic produce 26', 'Half');
insert into test_part_prices values (126, 'VARHALF126XXXXXXXXXXXX', 2.70); select produce_price_items('inv-1', array[126::bigint], false);
select pg_temp.ok(delivery_tasks_list()::text !~ 'VARHALF', 'T13 no half/quarter Square ids anywhere in the staff list');
-- T13 staff list: price fields and named half/quarter rows, no Square ids in what staff see
select pg_temp.ok((select delivery_tasks_list()::text like '%"price_mode": "apply_on_confirm"%'), 'T13 list shows price mode');
select pg_temp.ok((select bool_and(p->>'name' is not null and (p->>'old' is not null or p->>'state' in ('blocked', 'skipped', 'superseded')) and p->>'new' is not null and not (p ? 'variation'))
                     from jsonb_array_elements(delivery_tasks_list()) c, jsonb_array_elements(c->'tasks') t, jsonb_array_elements(case when jsonb_typeof(t->'parts') = 'array' then t->'parts' else '[]' end) p), 'T13 parts named, priced, no ids');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(delivery_tasks_list()) c, jsonb_array_elements(c->'tasks') t where t->'info' ? 'parts'), 'T13 no raw parts in info');
select pg_temp.ok(pg_temp.mq('VARHALF101XXXXXXXXXXXX', 'puts') = 0, 'no unexpected write to a conflicting half');
