#!/usr/bin/env bash
# Reproducible local validation of staged migrations 02 and 03. Needs a DISPOSABLE PostgreSQL (16+) with dblink
# available; never point this at production. Uses PGHOST/PGPORT/PGUSER from the environment.
#   PGHOST=/tmp PGPORT=54329 PGUSER=postgres db/tests/run_local.sh            # 02 + 03 + rollbacks
#   MIGRATION_03=path/to/older_03.sql db/tests/run_local.sh pricing           # run the pricing suite against another 03
set -uo pipefail
cd "$(dirname "$0")/.."
SUITES=${1:-all}
M03=${MIGRATION_03:-migrations/20261126_pricing_03_tag_confirm.sql}
P="psql -X -q -v ON_ERROR_STOP=1"
fail=0
fresh() { dropdb --if-exists "$1" >/dev/null; createdb "$1"; $P -d "$1" -f tests/local/base.sql >/dev/null; $P -d "$1" -f migrations/20261126_provenance_01_function_backup.sql >/dev/null; }
count() { local out="$1" label="$2"; local p e; p=$(grep -c 'pass:' <<<"$out"); e=$(grep -cE 'ERROR|FAIL' <<<"$out");
  echo "$label: $p passed, $e failed"; grep -E 'ERROR|FAIL' <<<"$out" | sed 's/^psql:[^ ]* //' | head -40; [ "$e" -eq 0 ] || fail=1; }

if [ "$SUITES" = all ] || [ "$SUITES" = provenance ]; then
  D=poppies_t02; fresh $D
  $P -d $D -f tests/provenance_02_seed.sql >/dev/null
  $P -1 -d $D -f migrations/20261126_provenance_02_schema.sql >/dev/null || { echo "02 did not apply"; exit 1; }
  out=$($P -d $D -f tests/provenance_02_checks.sql 2>&1); count "$out" "provenance_02"
  psql -X -q -d $D -c "update invoice_identity_exception set status = 'resolved' where id = (select min(id) from invoice_identity_exception)" >/dev/null
  if $P -1 -d $D -f rollback/20261126_provenance_02_schema_rollback.sql >/dev/null 2>&1; then echo "FAIL: 02 rollback ran with a reviewed exception"; fail=1;
  else echo "pass: 02 rollback refused with a reviewed exception"; fi
  [ "$(psql -X -At -d $D -c "select count(*) from invoice_identity_exception")" = 2 ] && echo "pass: 02 refused rollback changed nothing" || { echo "FAIL: 02 refused rollback changed data"; fail=1; }
  psql -X -q -d $D -c "update invoice_identity_exception set status = 'open'" >/dev/null
  $P -1 -d $D -f rollback/20261126_provenance_02_schema_rollback.sql >/dev/null && [ "$(psql -X -At -d $D -c "select to_regclass('invoice_identity_exception') is null")" = t ] \
    && echo "pass: 02 rollback clean" || { echo "FAIL: 02 rollback"; fail=1; }
  $P -1 -d $D -f migrations/20261126_provenance_02_schema.sql >/dev/null && echo "pass: 02 re-applies after rollback" || { echo "FAIL: 02 re-apply"; fail=1; }
fi

if [ "$SUITES" = all ] || [ "$SUITES" = pricing ]; then
  fresh poppies_t03; dropdb --if-exists poppies_square_mock >/dev/null; createdb poppies_square_mock
  $P -d poppies_square_mock -f tests/local/square_mock_store.sql >/dev/null
  $P -d poppies_t03 -c "create extension if not exists dblink" >/dev/null
  $P -1 -d poppies_t03 -f migrations/20261126_provenance_02_schema.sql >/dev/null
  if ! $P -1 -d poppies_t03 -f "$M03" >/dev/null; then echo "03 did not apply"; exit 1; fi
  conn="dbname=poppies_square_mock host=${PGHOST:-/tmp} port=${PGPORT:-5432} user=${PGUSER:-postgres}"
  out=$(psql -X -q -v mock_conn="$conn" -d poppies_t03 -f tests/pricing_03_selftest.sql 2>&1); count "$out" "pricing_03"
  if [ "$M03" = migrations/20261126_pricing_03_tag_confirm.sql ]; then
    out=$(tests/pricing_03_concurrency.sh poppies_t03 "$conn" 2>&1); count "$out" "pricing_03 concurrency"
    D=poppies_t03; R=rollback/20261126_pricing_03_tag_confirm_rollback.sql
    psql -X -q -d $D -c "update price_apply_op set state = 'ambiguous' where id = (select min(id) from price_apply_op where state = 'applied')" >/dev/null
    if $P -1 -d $D -f $R >/dev/null 2>&1; then echo "FAIL: 03 rollback ran with an in-doubt register update"; fail=1;
    else echo "pass: 03 rollback refused while a register update is in doubt"; fi
    psql -X -q -d $D -c "update price_apply_op set state = 'applied' where state = 'ambiguous'; update price_apply_op set state = 'superseded' where state = 'applying'; update delivery_tasks set apply_state = 'failed' where apply_state = 'applying'" >/dev/null
    psql -X -q -d $D -c "create table audit_before as select count(*) n from price_apply_audit; create table ops_before as select count(*) n from price_apply_op; create table applied_before as select count(*) n from retail_price_proposal where status = 'applied'" >/dev/null
    if $P -1 -d $D -f $R >/dev/null; then echo "pass: 03 rollback ran"; else echo "FAIL: 03 rollback"; fail=1; fi
    out=$(psql -X -q -d $D -f tests/pricing_03_rollback_checks.sql 2>&1); count "$out" "pricing_03 rollback"
  fi
fi

# 28 Nov 2026: Square price writers set FIXED_PRICING (migrations/20261128_price_write_fixed_pricing.sql), applied on
# top of 03; the 03 selftest is re-run with it in place, then the writers are exercised against a recording stub.
if [ "$SUITES" = all ] || [ "$SUITES" = fixedprice ]; then
  F=migrations/20261128_price_write_fixed_pricing.sql
  fresh poppies_tfp; dropdb --if-exists poppies_square_mock >/dev/null; createdb poppies_square_mock
  $P -d poppies_square_mock -f tests/local/square_mock_store.sql >/dev/null
  $P -d poppies_tfp -c "create extension if not exists dblink" >/dev/null
  $P -1 -d poppies_tfp -f migrations/20261126_provenance_02_schema.sql >/dev/null
  $P -1 -d poppies_tfp -f "$M03" >/dev/null || { echo "03 did not apply"; exit 1; }
  $P -1 -d poppies_tfp -f "$F" >/dev/null || { echo "fixed-pricing migration did not apply"; exit 1; }
  conn="dbname=poppies_square_mock host=${PGHOST:-/tmp} port=${PGPORT:-5432} user=${PGUSER:-postgres}"
  out=$(psql -X -q -v mock_conn="$conn" -d poppies_tfp -f tests/pricing_03_selftest.sql 2>&1); count "$out" "pricing_03 with fixed-pricing writers"
  out=$(psql -X -q -d poppies_tfp -f tests/price_write_fixed_pricing.sql 2>&1); count "$out" "fixed-pricing writers"
fi
exit $fail
