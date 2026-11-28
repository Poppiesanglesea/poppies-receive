#!/usr/bin/env bash
# Local validation of pricing_repair_01 on a DISPOSABLE PostgreSQL 16+ (never production). Uses PGHOST/PGPORT/PGUSER.
#   PGHOST=/tmp PGPORT=54330 PGUSER=postgres db/tests/run_pricing_repair_local.sh
# Builds base.sql + provenance_01/02 + pricing_03 + tests/local/pricing_repair_overlay.sql (production definitions of
# everything the migration touches, md5-identical to production on 28 Nov 2026; synthetic config, no business data), then:
#   1. the integration test in ONE transaction (seed, pre, migration, test, rollback, post) -> PR-RESULTS, all rolled back
#   2. residue: the database is back to its pre-test state
#   3. apply for real, the guard refuses a changed function, rollback restores byte-for-byte, re-apply works
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
$P -1 -d "$D" -f rollback/20261128_pricing_repair_01_rollback.sql >/dev/null && echo "pass: rollback runs" || { echo "FAIL: rollback"; fail=1; }
psql -X -q -d "$D" -c "drop table produce_price_attempts_archived; delete from function_backup where label = 'pre-pricing-repair-2026-11-28'" >/dev/null
[ "$(h)" = "$seeded" ] && echo "pass: rollback restores every definition byte-for-byte" || { echo "FAIL: rollback left differences"; fail=1; }
psql -X -q -d "$D" -c "create or replace function public.produce_price_sweep() returns jsonb language sql as \$\$ select '{}'::jsonb \$\$" >/dev/null
if $P -1 -d "$D" -f migrations/20261128_pricing_repair_01.sql >/dev/null 2>&1; then echo "FAIL: migration applied over a changed function"; fail=1;
else echo "pass: the guard refuses when a reviewed function has changed"; fi
exit $fail
