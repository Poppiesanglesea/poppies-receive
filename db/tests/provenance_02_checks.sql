-- Checks after applying provenance_02 to a database seeded with tests/provenance_02_seed.sql.
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
  begin if not coalesce(c, false) then raise exception 'FAIL: %', msg; end if; raise notice 'pass: %', msg; end $$;
select pg_temp.ok((select supplier_key = 'supplier a' and invoice_exact_key = '00123' and invoice_near_key = '123' and kind_key = 'invoice'
                     from processed_invoices where source_id = 's2'), '02 alias supplier, exact and near keys');
select pg_temp.ok((select kind_key = 'credit' from processed_invoices where source_id = 's4'), '02 credit kind');
select pg_temp.ok((select kind_key = 'duplicate' from processed_invoices where source_id = 's6'), '02 duplicate-noted kind');
select pg_temp.ok((select processed_invoice_ids from invoice_identity_exception where kind = 'exact_duplicate') = array[1,2]::bigint[], '02 exact duplicate group seeded');
select pg_temp.ok((select processed_invoice_ids from invoice_identity_exception where kind = 'near_number') = array[1,2,3]::bigint[], '02 near-number group seeded');
select pg_temp.ok((select sources_with_stock from invoice_identity_exception where kind = 'exact_duplicate') = 2, '02 stock evidence counted');
select pg_temp.ok((select count(*) from invoice_identity_exception where status = 'open') = 2, '02 exceptions open, nothing auto-resolved');
insert into processed_invoices (source_id, supplier, invoice_number, invoice_date, note) values ('s7', 'Supplier A Trading', ' 0456 ', '2026-10-09', 'INVOICE');
select pg_temp.ok((select supplier_key = 'supplier a' and invoice_near_key = '456' from processed_invoices where source_id = 's7'), '02 trigger sets keys on insert');
