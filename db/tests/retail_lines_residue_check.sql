-- Run after db/tests/retail_lines_rollback_test.sql (before retail_lines_01 is applied): every value must be 0/false/null
-- and new_stock_mode unchanged. Verified 28 Nov 2026: all clean, new_stock_mode = dry_run.
select
 (select count(*) from function_backup where label = 'pre-retail-lines-2026-11-28') backups,
 to_regclass('public.delivery_retail_answers') answers_tbl, to_regclass('public.delivery_retail_ops') ops_tbl,
 (select count(*) from information_schema.columns where table_name = 'delivery_receipts' and column_name = 'origin') origin_col,
 (select count(*) from pg_proc where proname like 'delivery_retail%' or proname in ('delivery_gtin_ok', 'delivery_gtin_inner')) new_fns,
 (select pg_get_functiondef('new_stock_apply(bigint,boolean)'::regprocedure) like '%staff_units_per_invoice_unit%') nsa_patched,
 (select pg_get_functiondef('delivery_recent_list(text)'::regprocedure) like '%r.origin%') recent_patched,
 (select pg_get_functiondef(oid) like '%rl_square%' from pg_proc where proname = 'square_api') square_stubbed,
 (select prosecdef from pg_proc where proname = 'square_api') square_secdef_kept,
 (select pg_get_functiondef('ingest_invoice_line(text,text,numeric,date,numeric,text,text,text,text)'::regprocedure) like '%select null%') iil_stubbed,
 (select count(*) from stock_items where name like 'RLTest%') fixture_items,
 (select count(*) from processed_invoices where source_id like 'RLTEST%') fixture_invoices,
 (select count(*) from delivery_receipts where source_id like 'retail-line:%') rl_receipts,
 (select value from app_config where key = 'new_stock_mode') new_stock_mode,
 (select count(*) from engine_runs where notes like '%RLTest%') fixture_runs;
