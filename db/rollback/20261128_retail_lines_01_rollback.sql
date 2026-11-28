-- Rollback for retail_lines_01 (28 Nov 2026). Run as ONE transaction.
-- Refuses (raises, nothing changed) while staff answers exist that are still in flight:
--   * a "new" answer whose receipt has not finished set-up (setup_status pending/failed/dry_run), or
--   * any invoice_line receipt with new_stock_lines in square_created (in Square, not yet linked).
-- Finished answers are kept as evidence in delivery_retail_answers_archived / delivery_retail_ops_archived (renamed,
-- RLS on, no anon/authenticated). Stock bookings and mappings made through the app are NOT undone: they are ordinary
-- ledger rows and supplier_product_map rows, reversible only by a stock correction (owner decision).
-- Restores new_stock_apply and delivery_recent_list from function_backup label 'pre-retail-lines-2026-11-28'.
-- If either function was changed again after this migration, restoring the backup would drop that later change:
-- the guard below refuses unless the live definition still contains this migration's patch markers.
do $$
begin
  if exists (select 1 from delivery_retail_answers a join delivery_receipts r on r.id = a.receipt_id
              where a.action = 'new' and coalesce(r.setup_status, 'pending') in ('pending', 'failed', 'dry_run')) then
    raise exception 'retail_lines_01 rollback refused: a "new" product set-up from the app is still in flight';
  end if;
  if exists (select 1 from new_stock_lines l join delivery_receipts r on r.id = l.receipt_id
              where r.origin = 'invoice_line' and l.status = 'square_created') then
    raise exception 'retail_lines_01 rollback refused: a product is in Square but not yet linked (square_created)';
  end if;
  if pg_get_functiondef('public.new_stock_apply(bigint, boolean)'::regprocedure) not like '%staff_new_but_known%' then
    raise exception 'retail_lines_01 rollback refused: new_stock_apply changed after this migration; restore by hand';
  end if;
  if pg_get_functiondef('public.delivery_recent_list(text)'::regprocedure) not like '%r.origin = ''photo''%' then
    raise exception 'retail_lines_01 rollback refused: delivery_recent_list changed after this migration; restore by hand';
  end if;
end $$;

select fn_backup_restore('new_stock_apply', 'pre-retail-lines-2026-11-28');
select fn_backup_restore('delivery_recent_list', 'pre-retail-lines-2026-11-28');

drop function if exists public.delivery_retail_answer(bigint, text, jsonb, uuid, text);
drop function if exists public.delivery_retail_lines_list();
drop function if exists public.delivery_retail_line_json(bigint, boolean);
drop function if exists public.delivery_retail_search(bigint, text);
drop function if exists public.delivery_retail_candidates(bigint);
drop function if exists public.delivery_retail_candidates_bulk(bigint[]);
drop function if exists public.delivery_retail_option(bigint, bigint);
drop function if exists public.delivery_retail_facts(bigint, bigint);
drop function if exists public.delivery_retail_item_eligible(bigint, bigint);
drop function if exists public.delivery_retail_line_ok(bigint, text[]);
drop function if exists public.delivery_retail_produce_suppliers();
drop function if exists public.delivery_retail_printed_pack(text);
drop function if exists public.delivery_gtin_inner(text);
drop function if exists public.delivery_gtin_ok(text);

alter table public.delivery_retail_answers rename to delivery_retail_answers_archived;
alter table public.delivery_retail_ops rename to delivery_retail_ops_archived;
-- receipts created by the flow stay (they are referenced by new_stock_lines); the origin column stays so they remain
-- distinguishable, and the restored delivery_recent_list simply lists them again as photo deliveries.
