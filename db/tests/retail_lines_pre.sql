-- retail_lines_01 integration test, part 0: run BEFORE the migration in the same rolled-back query
--   cat db/tests/retail_lines_pre.sql db/migrations/20261128_retail_lines_01.sql db/tests/retail_lines_rollback_test.sql
-- Captures production functions this change must not touch (barcode lookup, name matching, fixed-price writers).
create temp table rl_pre on commit drop as
select p.oid::regprocedure::text sig, md5(pg_get_functiondef(p.oid)) h
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('delivery_line_known', 'delivery_name_close', 'price_square_put', 'square_set_variation_price',
                     'delivery_item_option', 'delivery_item_eligible', 'map_unmatched', 'new_stock_wire', 'ingest_invoice_line',
                     'delivery_tasks_list', 'delivery_count_answer');
