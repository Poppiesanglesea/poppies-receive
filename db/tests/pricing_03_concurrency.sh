#!/usr/bin/env bash
# Concurrency check for staged 03 (run by run_local.sh after the selftest, same databases). A staff confirm holds the
# item lock across a slow Square write (3 s) while a newer invoice for that item and another item (listed in reverse
# order) and a staff confirm for the other item run at the same time. Expect: no deadlock or error, exactly one write
# for the slow item, the newer invoice's job created after the confirm finished, the other item applied once or
# superseded unwritten. Prints pass/FAIL lines.
D=${1:-poppies_t03}; CONN=$2; HERE=$(cd "$(dirname "$0")" && pwd)
sess() { { echo "\\set ON_ERROR_STOP on"; echo "select set_config('test.mock_conn', :'mock_conn', false);";
           echo "\\i '$HERE/local/mock_session.sql'"; echo "\\i '$HERE/local/test_helpers.sql'"; echo "$1"; } > "$2"
         psql -X -q -At -v mock_conn="$CONN" -d $D -f "$2" 2>&1; }
q() { psql -X -q -At -d $D -c "$1"; }
mock() { q "select v from dblink('$CONN', \$\$$1\$\$) t(v int)"; }
W=$(mktemp -d)
sess "insert into processed_invoices (source_id, supplier, invoice_number, invoice_date, note, booked_count, department)
      values ('inv-c1', 'Supplier P', 'P-C1', '2026-11-23', 'INVOICE', 1, 'Grocer'), ('inv-c2', 'Supplier P', 'P-C2', '2026-11-24', 'INVOICE', 1, 'Grocer');
      delete from v_price_rule_candidates; select pg_temp.cand(117, 5.40); select pg_temp.cand(118, 5.40);
      select produce_price_items('inv-c1', array[117::bigint, 118::bigint], false);
      select pg_temp.mx('update square set put_delay = 3 where variation_id = ''VARSYNTH0000000000000017''');" $W/s.sql >/dev/null
T117=$(q "select id from delivery_tasks where stock_item_id = 117 and source_id = 'inv-c1'")
T118=$(q "select id from delivery_tasks where stock_item_id = 118 and source_id = 'inv-c1'")
sess "select delivery_tag_confirm($T117, 'Staff A');" $W/a.sql > $W/a.out & A=$!
sleep 1
sess "select pg_temp.cand(117, 5.60); select pg_temp.cand(118, 5.60); select produce_price_items('inv-c2', array[118::bigint, 117::bigint], false);" $W/b.sql > $W/b.out & B=$!
sess "select delivery_tag_confirm($T118, 'Staff B');" $W/c.sql > $W/c.out & C=$!
wait $A $B $C
if grep -qi deadlock $W/*.out; then echo "FAIL: concurrency deadlock"; else echo "pass: concurrency no deadlock"; fi
if grep -q ERROR $W/*.out; then echo "FAIL: concurrency errors"; grep ERROR $W/*.out | head -5; else echo "pass: concurrency no errors"; fi
[ "$(q "select status from delivery_tasks where id = $T117")" = done ] && echo "pass: concurrency slow confirm completed" || echo "FAIL: concurrency slow confirm"
[ "$(mock "select puts from square where variation_id = 'VARSYNTH0000000000000017'")" = 1 ] && echo "pass: concurrency one write for the slow item" || echo "FAIL: concurrency write count"
[ "$(q "select count(*) from delivery_tasks where stock_item_id = 117 and source_id = 'inv-c2' and status = 'open' and apply_state = 'ready'")" = 1 ] \
  && echo "pass: concurrency newer invoice queued after the confirm" || echo "FAIL: concurrency newer invoice job"
s118=$(q "select status from delivery_tasks where id = $T118"); p118=$(mock "select puts from square where variation_id = 'VARSYNTH0000000000000018'")
{ [ "$s118" = done ] && [ "$p118" = 1 ]; } || { [ "$s118" = superseded ] && [ "$p118" = 0 ]; } \
  && echo "pass: concurrency other item applied once or superseded unwritten ($s118)" || echo "FAIL: concurrency other item ($s118, $p118 writes)"
rm -rf $W
