#!/usr/bin/env bash
# Local validation of pricing_repair_01 on a DISPOSABLE PostgreSQL 16+ (never production). Uses PGHOST/PGPORT/PGUSER.
#   PGHOST=/tmp PGPORT=54330 PGUSER=postgres db/tests/run_pricing_repair_local.sh
# Builds base.sql + provenance_01/02 + pricing_03 + tests/local/pricing_repair_overlay.sql (production definitions of
# everything the migration touches, md5-identical to production on 28 Nov 2026; synthetic config, no business data), then:
#   1. the integration test in ONE transaction (seed, pre, migration, test, rollback, post) -> PR-RESULTS, all rolled back
#   2. residue: the database is back to its pre-test state
#   3. apply for real, rollback restores byte-for-byte, the guard refuses a changed function
#   4. concurrency (two real sessions, committed, on a copy): a decision committed while apply waits for the item lock
#      is not overwritten by apply
set -uo pipefail
cd "$(dirname "$0")/.."
P="psql -X -q -v ON_ERROR_STOP=1"; D=${PRR_DB:-poppies_prr}; fail=0
dropdb --if-exists "$D" >/dev/null 2>&1; createdb "$D"
$P -d "$D" -f tests/local/base.sql >/dev/null && $P -d "$D" -f migrations/20261126_provenance_01_function_backup.sql >/dev/null \
  && $P -1 -d "$D" -f migrations/20261126_provenance_02_schema.sql >/dev/null 2>&1 && $P -1 -d "$D" -f migrations/20261126_pricing_03_tag_confirm.sql >/dev/null \
  && $P -1 -d "$D" -f tests/local/pricing_repair_overlay.sql >/dev/null || { echo "FAIL: could not build the local database"; exit 1; }
h() { psql -X -At -d "$D" -c "select md5(string_agg(x, '|' order by x)) from (select p.oid::regprocedure::text || md5(pg_get_functiondef(p.oid)) x from pg_proc p where pronamespace = 'public'::regnamespace union all select 'view' || md5(pg_get_viewdef('public.v_price_rule_candidates'::regclass)) union all select 'tables' || count(*) from pg_tables where schemaname = 'public' union all select 'rows' || (select count(*) from stock_items) || '/' || (select count(*) from retail_price_proposal) || '/' || (select count(*) from function_backup)) s"; }
before=$(h)
out=$(cat tests/pricing_repair_seed.sql tests/pricing_repair_pre.sql migrations/20261128_pricing_repair_01.sql tests/pricing_repair_rollback_test.sql \
          rollback/20261128_pricing_repair_01_rollback.sql tests/pricing_repair_post.sql | psql -X -q -1 -v ON_ERROR_STOP=1 -d "$D" 2>&1)
res=$(grep -o 'PR-RESULTS .*' <<<"$out" | head -1 | sed 's/^PR-RESULTS //')
if [ -z "$res" ]; then echo "FAIL: the test did not reach its report"; echo "$out" | grep -E 'ERROR|CONTEXT' | head -20; exit 1; fi
echo "$res" | python3 tests/local/pr_report.py || fail=1
[ "$(h)" = "$before" ] && echo "pass: residue — the database is exactly as before the test" || { echo "FAIL: residue"; fail=1; }

# real apply / guard / rollback / re-apply (committed, on the disposable database)
$P -d "$D" -f tests/pricing_repair_seed.sql >/dev/null
seeded=$(h)
$P -1 -d "$D" -f migrations/20261128_pricing_repair_01.sql >/dev/null && echo "pass: migration applies" || { echo "FAIL: migration apply"; fail=1; }
# rollback order (28 Nov review): the 03 rollback would drop price_item_lock / price_propose that the repair uses
if $P -1 -d "$D" -f rollback/20261126_pricing_03_tag_confirm_rollback.sql >/dev/null 2>&1; then echo "FAIL: 03 rollback ran while the repair is applied"; fail=1;
else echo "pass: 03 rollback refuses while the repair is applied"; fi
$P -1 -d "$D" -f rollback/20261128_pricing_repair_01_rollback.sql >/dev/null && echo "pass: rollback runs" || { echo "FAIL: rollback"; fail=1; }
psql -X -q -d "$D" -c "drop table produce_price_attempts_archived; delete from function_backup where label = 'pre-pricing-repair-2026-11-28'" >/dev/null
[ "$(h)" = "$seeded" ] && echo "pass: rollback restores every definition byte-for-byte" || { echo "FAIL: rollback left differences"; fail=1; }
# 4. concurrency on a copy of the rolled-back database
C="${D}_conc"; dropdb --if-exists "$C" >/dev/null 2>&1; createdb -T "$D" "$C"
$P -1 -d "$C" -f migrations/20261128_pricing_repair_01.sql >/dev/null || { echo "FAIL: apply on concurrency copy"; fail=1; }
$P -d "$C" >/dev/null <<'SQL'
do $c$ declare i bigint; begin
  insert into stock_items (name, department, count_unit, grams_per_count_unit, retail_sell_price) values ('PRConc Item', 'Grocer', 'each', 1, 5.00) returning id into i;
  insert into square_sync_map (stock_item_id, square_variation_id, square_item_name, retail_category, taxable) values (i, 'PRCONCMAIN' || lpad(i::text, 12, '0'), 'PRConc Item', 'Produce', false);
  insert into square_sales_map (square_variation_id, square_item_name, square_variation_name, retail_stock_item_id, retail_units_base) values ('PRCONCMAIN' || lpad(i::text, 12, '0'), 'PRConc Item', 'Regular', i, 1);
  insert into supplier_prices (stock_item_id, supplier, pack_label, pack_grams, pack_cost, effective_from) values (i, 'PRConc supplier', 'PRConc pack', 1, 3.00, current_date - 1);
  insert into retail_price_proposal (stock_item_id, lane, method, old_price, proposed_price, status, source, basis_date, basis_seq)
  values (i, 'approve', 'band', 5.00, 5.40, 'approved', 'PRCONC', current_date, 0);
end $c$;
SQL
item=$(psql -X -At -d "$C" -c "select id from stock_items where name = 'PRConc Item'")
( psql -X -q -d "$C" -c "begin; select price_item_lock($item); select pg_sleep(3); update retail_price_proposal set status = 'rejected', decided_by = 'PRConc other session', decided_at = now() where source = 'PRCONC'; commit;" >/dev/null 2>&1 ) &
sleep 1
applied=$(psql -X -At -d "$C" -c "select price_proposal_apply(false)->>'applied'")
wait
st=$(psql -X -At -d "$C" -c "select status || '/' || decided_by from retail_price_proposal where source = 'PRCONC'")
tags=$(psql -X -At -d "$C" -c "select count(*) from delivery_tasks where stock_item_id = $item")
if [ "$st" = "rejected/PRConc other session" ] && [ "$applied" = 0 ] && [ "$tags" = 0 ]; then
  echo "pass: concurrency — a decision committed while apply waited for the item lock is kept (apply skipped it, no tag job)"
else echo "FAIL: concurrency — status $st, applied $applied, tag jobs $tags"; fail=1; fi
dropdb "$C"

psql -X -q -d "$D" -c "create or replace function public.produce_price_sweep() returns jsonb language sql as \$\$ select '{}'::jsonb \$\$" >/dev/null
if $P -1 -d "$D" -f migrations/20261128_pricing_repair_01.sql >/dev/null 2>&1; then echo "FAIL: migration applied over a changed function"; fail=1;
else echo "pass: the guard refuses when a reviewed function has changed"; fi
exit $fail
