-- Rollback for db/migrations/20261126_provenance_02_schema.sql. Removes only what that migration added.
-- Safe while invoice_line_stock / ingest_unmatched_line are unused; if later steps have written to them,
-- roll those steps back first (their rollback files restore the prior functions from function_backup).
drop index if exists public.processed_invoices_canonical_uidx;
drop trigger if exists processed_invoices_keys_trg on public.processed_invoices;
drop function if exists public.processed_invoices_set_keys();
drop function if exists public.processed_invoice_keys(text, text, text);
alter table public.processed_invoices
  drop column if exists dup_review,
  drop column if exists kind_key,
  drop column if exists invoice_no_key,
  drop column if exists supplier_key;
drop table if exists public.ingest_unmatched_line;
drop table if exists public.invoice_line_stock;
