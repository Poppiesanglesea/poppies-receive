-- 28 Nov 2026 (Josh: "Repair and harden").
-- Eleven invoker functions that reach Square (square_api / square_set_variation_price) still had the default
-- PUBLIC execute grant, so anon and authenticated could call them. square_api itself is postgres-only, so a call from
-- those roles would fail at that point, but they should not be callable at all. Lock them to postgres + service_role
-- (service_role keeps what it had; cron runs as postgres; the app's Edge function calls none of them directly).
-- Rollback: GRANT EXECUTE ON FUNCTION <each> TO PUBLIC;
DO $l$
DECLARE f regprocedure;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.backfill_square_order_money(timestamptz,timestamptz)',
    'public.grocer_cat_fix_apply_20261007(boolean)',
    'public.gvc_apply_20260929(integer,boolean)',
    'public.h2g_sync_costs(boolean)',
    'public.produce_tiles_attach_next(integer)',
    'public.square_selftest()',
    'public.square_set_variation_price(text,integer)',
    'public.sync_guard(boolean)',
    'public.sync_part_variation_prices(bigint,boolean)',
    'public.sync_square_team_members()',
    'public.sync_square_variation_identity()'
  ]::regprocedure[] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
  -- square_api is already postgres-only in production; restate it so the guard below holds everywhere.
  REVOKE ALL ON FUNCTION public.square_api(text,text,jsonb) FROM PUBLIC, anon, authenticated, service_role;
END $l$;

-- Guard: fail loudly if anything that reaches Square is callable by anon/authenticated again.
CREATE OR REPLACE FUNCTION public.square_writer_exposure()
 RETURNS TABLE(fn text, anon_exec boolean, authenticated_exec boolean)
 LANGUAGE sql STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select p.oid::regprocedure::text, has_function_privilege('anon', p.oid, 'execute'), has_function_privilege('authenticated', p.oid, 'execute')
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname = 'square_api' or p.prosrc ~ 'square_api\s*\(' or p.prosrc ~ 'square_set_variation_price\s*\(' or p.prosrc ~ 'price_square_put\s*\(')
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
$function$;
REVOKE ALL ON FUNCTION public.square_writer_exposure() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.square_writer_exposure() TO service_role;
