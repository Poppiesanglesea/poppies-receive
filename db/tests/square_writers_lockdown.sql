-- Tests for migrations/20261128_square_writers_lockdown.sql (run_local.sh fixedprice).
\set ON_ERROR_STOP 0
create function pg_temp.ck(label text, ok boolean) returns void language plpgsql as $$
begin if ok then raise notice 'pass: %', label; else raise warning 'FAIL: %', label; end if; end $$;

select pg_temp.ck('exposure guard is empty after lockdown', count(*) = 0) from square_writer_exposure();
select pg_temp.ck('square_set_variation_price: anon cannot execute', not has_function_privilege('anon', 'public.square_set_variation_price(text,integer)', 'execute'));
select pg_temp.ck('square_set_variation_price: authenticated cannot execute', not has_function_privilege('authenticated', 'public.square_set_variation_price(text,integer)', 'execute'));
select pg_temp.ck('square_set_variation_price: service_role can execute', has_function_privilege('service_role', 'public.square_set_variation_price(text,integer)', 'execute'));
select pg_temp.ck('sync_part_variation_prices locked to service_role',
  not has_function_privilege('anon', 'public.sync_part_variation_prices(bigint,boolean)', 'execute')
  and has_function_privilege('service_role', 'public.sync_part_variation_prices(bigint,boolean)', 'execute'));
select pg_temp.ck('guard itself not callable by anon', not has_function_privilege('anon', 'public.square_writer_exposure()', 'execute'));

select pg_temp.ck('pricing invokers (nightly_close, price_proposal_decide, produce_price_label) locked to service_role',
  bool_and(not has_function_privilege('anon', f, 'execute') and not has_function_privilege('authenticated', f, 'execute')
           and has_function_privilege('service_role', f, 'execute')))
  from unnest(array['public.nightly_close()', 'public.price_proposal_decide(bigint[],text,text)', 'public.produce_price_label(bigint,text)']::regprocedure[]) f;

-- the guard actually detects a regression
create function public.zz_square_leak() returns jsonb language plpgsql as $$ begin return square_api('GET', '/x', null); end $$;
select pg_temp.ck('guard flags a new PUBLIC function that reaches Square', count(*) = 1) from square_writer_exposure() where fn like '%zz_square_leak%';
drop function public.zz_square_leak();

-- anon really is refused
set role anon;
do $$ begin perform square_set_variation_price('X', 1); raise warning 'FAIL: anon call was allowed';
exception when insufficient_privilege then raise notice 'pass: anon call refused'; end $$;
reset role;
