-- 28 Nov 2026 — applied live (Supabase migrations, in order):
--   20261128122331 unmatched_square_tile_hint
--   20261128122359 unmatched_square_tile_hint_tighten
--   20261128122422 unmatched_square_tile_hint_regular
--   20261128122512 engine_health_square_tile_unlinked   (also created backup engine_health_bak_20261128, postgres-only)
--   20261128123315 unmatched_square_tile_hint_materialize
--   20261128123329 engine_health_square_tile_single_read
-- This file is the FINAL applied state of those six, written so it can be re-run (create or replace).
-- Live check after apply: md5(pg_get_functiondef('public.engine_health()'::regprocedure)) = 4dc9e62b79314b658acb95eeaba30c3f
--                         md5(pg_get_viewdef('public.v_unmatched_square_tile_hint'::regclass)) = 6c1a7efff03ceb94ddc70a6cdf17029e
--
-- Why: Square produce tiles existed with no stock item / square_sales_map link, so supplier lines queued as
-- "new product", the staff app showed no Square match, and sales of those tiles depleted nothing.
-- v_unmatched_square_tile_hint lists open retail invoice lines that look like a live, UNLINKED Square tile in the
-- same department; engine_health() lists them under square_tile_unlinked and adds an alert reason only when a
-- matching line was seen in the last 3 days.

create or replace function public.retail_name_stems(p text)
returns text[] language sql immutable parallel safe set search_path = public as $$
  select coalesce(array(
    select distinct case when length(w) > 3 then regexp_replace(w, '(es|s)$', '') else w end
    from regexp_split_to_table(lower(regexp_replace(coalesce(p,''), '[^A-Za-z]+', ' ', 'g')), ' ') w
    where length(w) >= 3), '{}'::text[]);
$$;
revoke all on function public.retail_name_stems(text) from public, anon, authenticated;
grant execute on function public.retail_name_stems(text) to service_role;

create or replace view public.v_unmatched_square_tile_hint as
with tiles as materialized (
  select v.variation_id, v.item_id, v.item_name, nullif(v.variation_name, '') as variation_name, v.price,
         split_part(c.path_text, ' > ', 1) as department,
         retail_name_stems(v.item_name) as item_stems,
         retail_name_stems(v.variation_name) as var_stems,
         lower(regexp_replace(v.item_name || ' ' || coalesce(v.variation_name, ''), '[^A-Za-z]+', ' ', 'g')) as nm
  from square_variation_identity v
  join square_categories c on c.square_category_id = v.reporting_category_id
  where v.live and not v.is_archived
    and split_part(c.path_text, ' > ', 1) in ('Grocer', 'Garden', 'Gift Store')
    and not exists (select 1 from square_sales_map sm where sm.square_variation_id = v.variation_id and sm.active)
), lines as materialized (
  select u.id as unmatched_id, u.supplier, u.department, u.description, u.qty, u.unit, u.unit_price, u.invoice_date, u.seen_at,
         retail_name_stems(u.description) as stems,
         lower(regexp_replace(u.description, '[^A-Za-z]+', ' ', 'g')) as nm
  from ingest_unmatched u
  where u.resolved_at is null and u.department in ('Grocer', 'Garden', 'Gift Store')
), scored as materialized (
  select l.*, t.variation_id, t.item_id, t.item_name, t.variation_name, t.price,
         (cardinality(t.item_stems) > 0 and t.item_stems <@ l.stems) as name_words_match,
         (cardinality(t.var_stems) > 0 and t.var_stems && l.stems) as variation_words_match,
         (cardinality(t.var_stems) = 0 or t.var_stems = array['regular']) as default_tile,
         extensions.similarity(t.nm, l.nm) as sim
  from lines l join tiles t on t.department = l.department
)
select unmatched_id, supplier, department, description, qty, unit, unit_price, invoice_date,
       variation_id as square_variation_id, item_id as square_item_id, item_name as square_item_name,
       variation_name as square_variation_name, price as square_price,
       round(sim::numeric, 2) as similarity, name_words_match, variation_words_match,
       'Square tile exists but is not linked in Supabase: link it (stock item + square_sales_map) and map the line, instead of creating a new product' as action,
       seen_at
from scored
where sim >= 0.6
   or (name_words_match and (variation_words_match or (default_tile and sim >= 0.3)));

revoke all on public.v_unmatched_square_tile_hint from public, anon, authenticated;
grant select on public.v_unmatched_square_tile_hint to service_role;
comment on view public.v_unmatched_square_tile_hint is
  'Open retail invoice lines that look like an existing live Square tile with no active square_sales_map link (28 Nov 2026 grapes/thyme defect). Surfaced by engine_health().square_tile_unlinked.';

-- engine_health(): before replacing, live applied a backup of the previous body as public.engine_health_bak_20261128()
-- (postgres-only; EXECUTE revoked from public, anon, authenticated, service_role). Body below = live, md5 above.
CREATE OR REPLACE FUNCTION public.engine_health()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  v_daily timestamptz; v_poll timestamptz; v_poll_bad int; v_last_order timestamptz;
  v_refresh timestamptz; v_catsync timestamptz; v_snapshot timestamptz;
  v_watchdog timestamptz; v_filing timestamptz; v_wastage timestamptz; v_sweep timestamptz;
  v_orphan timestamptz; v_poll_last_bad timestamptz;
  v_cron jsonb; v_pipeline jsonb; v_cost jsonb; v_review jsonb; v_intake jsonb;
  v_tile jsonb; v_tile_new int;
  v_reasons text[] := '{}'; v_thresh numeric;
begin
  select max(ran_at) into v_daily from engine_runs where notes like 'DAILY %';
  select max(ran_at) into v_poll from square_poll_log where not dry_run and status = 'ok' and error is null and not coalesce(partial,false);
  select count(*) into v_poll_bad from square_poll_log where not dry_run and ran_at > now() - interval '24 hours' and (status is distinct from 'ok' or error is not null or coalesce(partial,false));
  select max(ran_at) into v_poll_last_bad from square_poll_log
   where not dry_run and (status is distinct from 'ok' or error is not null or coalesce(partial,false));
  select max(processed_at) into v_last_order from processed_orders;
  select max(ran_at) into v_refresh from engine_runs where notes like 'WEEKLY-REFRESH sales_agg%';
  select max(ran_at) into v_catsync from engine_runs where notes like 'CATALOG-SYNC%';
  select max(snapshot_date)::timestamptz into v_snapshot from forecast_snapshot;

  -- heartbeats from the agent-side scheduled tasks
  select max(ran_at) into v_watchdog from engine_runs where notes like 'WATCHDOG%';
  select max(ran_at) into v_filing   from engine_runs where notes like 'FILING%';

  -- heartbeats from pg_cron jobs that write no engine_runs row of their own
  select max(d.start_time) into v_wastage from cron.job_run_details d join cron.job j on j.jobid = d.jobid
   where j.jobname = 'daily_wastage' and d.status = 'succeeded';
  select max(d.start_time) into v_sweep from cron.job_run_details d join cron.job j on j.jobid = d.jobid
   where j.jobname = 'sweep_square_returns_hourly' and d.status = 'succeeded';

  -- a daily run that claimed the lock and never finished: no DAILY row at any time after it (27 Nov 2026: any later completed run clears it; was same Melbourne day only)
  select max(e.ran_at) into v_orphan
    from engine_runs e
   where e.notes like 'STARTED%'
     and e.ran_at < now() - interval '2 hours'
     and e.ran_at > now() - interval '48 hours'
     and not exists (
           select 1 from engine_runs f
            where f.ran_at > e.ran_at
              and f.notes like 'DAILY %');

  select coalesce(jsonb_agg(jsonb_build_object('job', j.jobname, 'status', d.status, 'start', d.start_time, 'msg', left(d.return_message, 200)) order by d.start_time desc), '[]'::jsonb)
    into v_cron
    from cron.job_run_details d join cron.job j on j.jobid = d.jobid
   where d.status = 'failed' and d.start_time > now() - interval '24 hours';

  select coalesce(jsonb_agg(jsonb_build_object('check', check_name, 'status', status, 'detail', detail) order by sort), '[]'::jsonb)
    into v_pipeline from v_pipeline_health where status <> 'ok';

  select cost_change_alert_pct into v_thresh from costing_settings where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('ingredient', ingredient, 'supplier', supplier, 'old', old_cost, 'new', new_cost, 'pct', round(pct_change,1), 'on', changed_on) order by pct_change desc), '[]'::jsonb)
    into v_cost from v_recent_cost_changes
   where changed_on >= current_date - 1 and pct_change >= coalesce(v_thresh, 5);

  select coalesce(jsonb_agg(jsonb_build_object('ingredient', ingredient, 'supplier', supplier, 'current', current_cost_per_unit, 'new', new_cost_per_unit, 'pct', pct_diff, 'pack', pack_label) order by abs(pct_diff) desc), '[]'::jsonb)
    into v_review from v_prices_to_review;

  -- 27 Nov 2026: supplier bills in Xero (last 21 days, 2+ days old) never read into stock / the delivery app
  select coalesce(jsonb_agg(jsonb_build_object('supplier', supplier, 'bill', bill_number, 'date', bill_date, 'total', amount_total, 'days_old', days_old) order by bill_date), '[]'::jsonb)
    into v_intake from v_invoice_intake_overdue;

  -- 28 Nov 2026: open retail invoice lines that look like an existing Square tile with no Supabase link
  -- (grapes/thyme defect: staff saw "new product" for items already in Square). Listed always; alerts only on fresh lines.
  select coalesce(jsonb_agg(jsonb_build_object('unmatched_id', h.unmatched_id, 'supplier', h.supplier, 'line', h.description,
                                               'square', h.square_item_name || coalesce(' › ' || h.square_variation_name, ''),
                                               'square_variation_id', h.square_variation_id, 'similarity', h.similarity, 'seen_at', h.seen_at)
                            order by h.unmatched_id), '[]'::jsonb)
    into v_tile from v_unmatched_square_tile_hint h;
  select count(distinct (x->>'unmatched_id')) into v_tile_new
    from jsonb_array_elements(v_tile) x
   where (x->>'seen_at')::timestamptz > now() - interval '3 days';

  if v_daily is null or v_daily < now() - interval '26 hours' then
    v_reasons := v_reasons || ('daily engine heartbeat stale: ' || coalesce(v_daily::text, 'never')); end if;
  if v_poll is null or v_poll < now() - interval '2 hours' then
    v_reasons := v_reasons || ('square poll stale: ' || coalesce(v_poll::text, 'never')); end if;
  -- Keep recovered isolated errors in diagnostics; alert on unresolved or repeated failures.
  if v_poll_last_bad > coalesce(v_poll, '-infinity'::timestamptz) then
    v_reasons := v_reasons || ('square poll failure unresolved: ' || v_poll_last_bad::text);
  elsif v_poll_bad >= 3 then
    v_reasons := v_reasons || (v_poll_bad || ' poll failures in 24h: repeated instability despite recovery');
  end if;
  if v_last_order is null or v_last_order < now() - interval '30 hours' then
    v_reasons := v_reasons || ('no orders processed since ' || coalesce(v_last_order::text, 'never')); end if;
  if v_refresh is null or v_refresh < now() - interval '36 hours' then
    v_reasons := v_reasons || ('sales_agg_backfill refresh stale: ' || coalesce(v_refresh::text, 'never')); end if;
  if v_snapshot is null or v_snapshot < (current_date - 2) then
    v_reasons := v_reasons || ('forecast snapshot stale: ' || coalesce(v_snapshot::date::text, 'never')); end if;

  -- NEW: a run that started and never finished. Half the invoices may be booked.
  if v_orphan is not null then
    v_reasons := v_reasons || ('daily engine run started ' || v_orphan::text || ' and never completed - invoices for that day may be part-booked'); end if;

  -- NEW: the alerting task itself, and the Gmail filing task, must prove they are alive.
  -- Self-arming: only checked once a first heartbeat has ever been recorded.
  if v_watchdog is not null and v_watchdog < now() - interval '30 hours' then
    v_reasons := v_reasons || ('watchdog heartbeat stale: ' || v_watchdog::text || ' - alerting may be down'); end if;
  if v_filing is not null and v_filing < now() - interval '30 hours' then
    v_reasons := v_reasons || ('gmail invoice filing heartbeat stale: ' || v_filing::text); end if;

  -- NEW: pg_cron jobs that previously had no staleness check at all (only exceptions were caught)
  if v_catsync is not null and v_catsync < now() - interval '30 hours' then
    v_reasons := v_reasons || ('square catalog sync stale: ' || v_catsync::text); end if;
  if v_wastage is not null and v_wastage < now() - interval '30 hours' then
    v_reasons := v_reasons || ('daily wastage job stale: ' || v_wastage::text); end if;
  if v_sweep is not null and v_sweep < now() - interval '4 hours' then
    v_reasons := v_reasons || ('square returns sweep stale: ' || v_sweep::text); end if;

  if jsonb_array_length(v_intake) > 0 then
    v_reasons := v_reasons || (jsonb_array_length(v_intake) || ' supplier invoice(s) in Xero not read into stock (oldest '
                 || (select min((x->>'date')) from jsonb_array_elements(v_intake) x) || '): '
                 || (select string_agg(distinct x->>'supplier', ', ') from jsonb_array_elements(v_intake) x)
                 || ' - see v_invoice_intake_overdue'); end if;

  if v_tile_new > 0 then
    v_reasons := v_reasons || (v_tile_new || ' new invoice line(s) look like an existing Square tile that is not linked in Supabase'
                 || ' - link the tile instead of creating a new product; see v_unmatched_square_tile_hint'); end if;

  if jsonb_array_length(v_cron) > 0 then
    v_reasons := v_reasons || (jsonb_array_length(v_cron) || ' pg_cron failure(s) in 24h'); end if;
  if exists (select 1 from jsonb_array_elements(v_pipeline) p where p->>'status' in ('alert','fail')) then
    v_reasons := array_append(v_reasons, (select string_agg(p->>'check' || ': ' || (p->>'detail'), '; ')
                                        from jsonb_array_elements(v_pipeline) p
                                       where p->>'status' in ('alert','fail'))); end if;

  return jsonb_build_object(
    'alert', cardinality(v_reasons) > 0,
    'reasons', to_jsonb(v_reasons),
    'checked_at', now(),
    'daily_engine_last', v_daily, 'poll_last', v_poll, 'poll_bad_24h', v_poll_bad, 'poll_last_error', v_poll_last_bad, 'poll_recovered', (v_poll_last_bad is not null and v_poll > v_poll_last_bad), 'last_order_processed', v_last_order,
    'sales_agg_refresh_last', v_refresh, 'catalog_sync_last', v_catsync, 'forecast_snapshot_last', v_snapshot,
    'watchdog_last', v_watchdog, 'filing_last', v_filing, 'wastage_last', v_wastage, 'returns_sweep_last', v_sweep,
    'orphan_run', v_orphan,
    'cron_failures_24h', v_cron,
    'pipeline_warnings', v_pipeline,
    'invoices_not_read', v_intake,
    'square_tile_unlinked', v_tile,
    'cost_rises_today', v_cost,
    'prices_to_review', v_review);
end $function$
;
