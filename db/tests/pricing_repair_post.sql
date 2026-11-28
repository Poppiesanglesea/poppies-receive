-- pricing_repair_01 test, part 5 of 5 (after the rollback file ran inside the same transaction): the rollback restored
-- every replaced definition byte-for-byte and removed the new objects; then report and roll everything back.
do $P$
begin
  perform pg_temp.ck('rollback: view and all 7 replaced functions restored exactly; preserved functions unchanged',
                     not exists (select 1 from pr_pre_fn f where f.h is not null and f.sig <> 'view'
                                   and md5(case when f.sig <> 'view' and f.h is not null then pg_get_functiondef(f.sig::regprocedure) end) <> f.h)
                     and md5(pg_get_viewdef('public.v_price_rule_candidates'::regclass)) = (select h from pr_pre_fn where sig = 'view'),
                     (select string_agg(f.sig, ', ') from pr_pre_fn f where f.h is not null and f.sig <> 'view'
                        and md5(case when f.sig <> 'view' and f.h is not null then pg_get_functiondef(f.sig::regprocedure) end) <> f.h));
  perform pg_temp.ck('rollback: new functions dropped, attempts table archived',
                     not exists (select 1 from pg_proc where proname in ('retail_price_for_pack', 'price_current_calc', 'price_proposal_staleness', 'price_guard_applies'))
                     and to_regclass('public.produce_price_attempts') is null and to_regclass('public.produce_price_attempts_archived') is not null);
end $P$;

do $$ begin
  raise exception 'PR-RESULTS %', (select jsonb_build_object('passed', count(*) filter (where ok), 'failed', count(*) filter (where not ok),
    'failures', coalesce(jsonb_agg(jsonb_build_object('n', n, 'name', name, 'detail', left(detail, 700)) order by n) filter (where not ok), '[]'),
    'checks', jsonb_agg(n || ' ' || name order by n),
    'query_md5', md5(current_query()), 'query_len', length(current_query())) from pr_t);
end $$;
