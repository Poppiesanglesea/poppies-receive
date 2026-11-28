-- Local stand-ins (default PUBLIC grant, like production before 20261128_square_writers_lockdown) for the
-- Square-reaching functions that base.sql does not define. Each body mentions square_api( as production's do.
DO $s$
DECLARE d text;
BEGIN
  FOREACH d IN ARRAY ARRAY[
    'backfill_square_order_money(p_start timestamptz, p_end timestamptz)',
    'grocer_cat_fix_apply_20261007(p_dry_run boolean)',
    'gvc_apply_20260929(p_limit integer, p_dry_run boolean)',
    'h2g_sync_costs(p_dry_run boolean)',
    'produce_tiles_attach_next(p_n integer)',
    'square_selftest()',
    'sync_guard(p_dry_run boolean)',
    'sync_part_variation_prices(p_stock_item_id bigint, p_dry_run boolean)',
    'sync_square_team_members()',
    'sync_square_variation_identity()',
    'nightly_close()',
    'price_proposal_decide(p_ids bigint[], p_decision text, p_by text)'
  ] LOOP
    IF to_regprocedure('public.' || regexp_replace(d, '\(.*', '') || '(' ||
         coalesce((select string_agg(split_part(trim(a), ' ', 2), ',') from unnest(string_to_array(substring(d from '\((.*)\)'), ',')) a where trim(a) <> ''), '') || ')') IS NULL THEN
      EXECUTE format('create function public.%s returns jsonb language plpgsql as $f$ begin return square_api(''GET'', ''/x'', null); end $f$', d);
    END IF;
  END LOOP;
END $s$;
