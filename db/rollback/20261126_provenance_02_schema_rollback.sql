-- Rollback for db/migrations/20261126_provenance_02_schema.sql. Removes only what that migration added.
-- Refuses to run if the provenance tables hold data or if any exception has been worked on (resolved), so that no
-- line provenance or review decision is lost. Roll back later steps first if they have written to these tables.
do $guard$
begin
  if exists (select 1 from public.invoice_line_stock) then
    raise exception 'rollback refused: invoice_line_stock has rows';
  end if;
  if exists (select 1 from public.ingest_unmatched_line) then
    raise exception 'rollback refused: ingest_unmatched_line has rows';
  end if;
  if exists (select 1 from public.invoice_identity_exception where status <> 'open') then
    raise exception 'rollback refused: invoice_identity_exception has reviewed rows';
  end if;
end $guard$;

drop trigger if exists processed_invoices_keys_trg on public.processed_invoices;
drop function if exists public.processed_invoices_set_keys();
drop function if exists public.processed_invoice_keys(text, text, text);
alter table public.processed_invoices
  drop column if exists kind_key,
  drop column if exists invoice_near_key,
  drop column if exists invoice_exact_key,
  drop column if exists supplier_key;
drop table if exists public.ingest_unmatched_line;
drop table if exists public.invoice_line_stock;
drop table if exists public.invoice_identity_exception;
