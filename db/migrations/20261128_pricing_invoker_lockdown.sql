-- 28 Nov 2026 (Josh: "Repair and harden"). delivery_app_selfcheck() listed three invoker pricing functions still
-- callable by anon/authenticated through the default PUBLIC grant. None is called over the REST API (no rpc calls in
-- the last 24 h of edge logs; the app's Edge function does not use them); nightly_close runs from cron as postgres.
-- Rollback: GRANT EXECUTE ON FUNCTION <each> TO PUBLIC;
DO $l$
DECLARE f regprocedure;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.nightly_close()',
    'public.price_proposal_decide(bigint[],text,text)',
    'public.produce_price_label(bigint,text)'
  ]::regprocedure[] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $l$;
