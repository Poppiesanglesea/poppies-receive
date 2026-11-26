-- Run after a successful 03 rollback in the test database (see run_local.sh).
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
  begin if not coalesce(c, false) then raise exception 'FAIL: %', msg; end if; raise notice 'pass: %', msg; end $$;
select pg_temp.ok(to_regclass('public.price_apply_audit') is not null and to_regclass('public.price_apply_op') is not null, '03 rollback keeps audit and operation tables');
select pg_temp.ok((select count(*) from price_apply_audit) >= (select n from audit_before) + 1, '03 rollback keeps every audit row (+1 rollback marker)');
select pg_temp.ok((select count(*) from price_apply_op) = (select n from ops_before), '03 rollback keeps every operation row');
select pg_temp.ok(to_regprocedure('public.delivery_tag_claim(bigint,text)') is null and to_regprocedure('public.price_propose(jsonb)') is null, '03 rollback drops added functions');
select pg_temp.ok(pg_get_functiondef('public.delivery_task_tick(bigint,text)'::regprocedure) not like '%delivery_tag_confirm%', '03 rollback restores the previous tick');
select pg_temp.ok(not exists (select 1 from delivery_tasks where price_mode = 'apply_on_confirm' and status = 'open'), '03 rollback leaves no open apply-on-confirm job');
select pg_temp.ok(not exists (select 1 from retail_price_proposal where status = 'authorised'), '03 rollback leaves no authorised proposal');
select pg_temp.ok((select count(*) from retail_price_proposal where status = 'applied') = (select n from applied_before), '03 rollback keeps applied history');
select pg_temp.ok(not exists (select 1 from price_apply_op where state in ('ready', 'blocked', 'failed', 'conflict')), '03 rollback closes open operations (incl. unknown-price halves) without inventing prices');
