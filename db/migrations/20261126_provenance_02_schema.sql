-- STATUS: STAGED FOR REVIEW. NOT APPLIED (an earlier attempt was declined at the approval prompt on 26 Nov 2026).
-- Purpose: (1) canonical invoice identity so a second copy of the same supplier invoice cannot be booked again
-- when it arrives under a supplier alias or a differently formatted number; (2) per-line stock provenance tables.
--
-- EXACT INTENDED MUTATIONS (preview measured read-only 26 Nov 2026, 21:3x):
--   processed_invoices: ADD COLUMN supplier_key, invoice_no_key, kind_key (text, nullable), dup_review (boolean,
--     default false). Existing columns and values are NOT changed.
--   processed_invoices: UPDATE the 3 new key columns on all rows (1,039 at preview time) from canonical_supplier(),
--     normalised invoice number, and kind derived from note (CREDIT% / STATEMENT% / DUPLICATE% / otherwise invoice).
--   processed_invoices: UPDATE dup_review = true on the later rows of existing conflicts (3 rows at preview time:
--     ids 811, 838, 905). Nothing else about those rows changes; nothing is deleted; no stock is touched.
--   CREATE trigger processed_invoices_keys_trg (BEFORE INSERT/UPDATE OF supplier, invoice_number, note) to fill keys.
--   CREATE UNIQUE INDEX processed_invoices_canonical_uidx on (supplier_key, invoice_no_key, kind_key)
--     WHERE invoice_no_key IS NOT NULL AND kind_key IN ('invoice','credit') AND NOT dup_review.
--     Effect on future ingestion: inserting a second invoice (or credit) with the same canonical supplier + number
--     raises a unique violation, so that whole ingest transaction rolls back (fails closed, nothing booked).
--     Credit notes do not collide with invoices; statements and blank numbers are outside the index.
--   CREATE TABLE invoice_line_stock, ingest_unmatched_line (empty; RLS on; service_role select only).
--   CREATE FUNCTION processed_invoice_keys, processed_invoices_set_keys (no anon/authenticated execute).
-- NO deletes, NO changes to stock_ledger rows, invoice_lines rows, prices, Square or email.
-- Rollback: db/rollback/20261126_provenance_02_schema_rollback.sql

alter table public.processed_invoices
  add column if not exists supplier_key text,
  add column if not exists invoice_no_key text,
  add column if not exists kind_key text,
  add column if not exists dup_review boolean not null default false;

create or replace function public.processed_invoice_keys(p_supplier text, p_invno text, p_note text)
returns table (supplier_key text, invoice_no_key text, kind_key text)
language sql stable set search_path to 'public', 'pg_temp' as $$
  select lower(btrim(canonical_supplier(p_supplier))),
         nullif(ltrim(lower(regexp_replace(btrim(coalesce(p_invno,'')), '\s+', '', 'g')), '0'), ''),
         case when coalesce(p_note,'') ilike 'CREDIT%' then 'credit'
              when coalesce(p_note,'') ilike 'STATEMENT%' then 'statement'
              when coalesce(p_note,'') like 'DUPLICATE%' then 'duplicate'
              else 'invoice' end;
$$;

create or replace function public.processed_invoices_set_keys()
returns trigger language plpgsql set search_path to 'public', 'pg_temp' as $$
begin
  select k.supplier_key, k.invoice_no_key, k.kind_key into new.supplier_key, new.invoice_no_key, new.kind_key
    from processed_invoice_keys(new.supplier, new.invoice_number, new.note) k;
  return new;
end $$;

update public.processed_invoices p
   set supplier_key = k.supplier_key, invoice_no_key = k.invoice_no_key, kind_key = k.kind_key
  from lateral processed_invoice_keys(p.supplier, p.invoice_number, p.note) k;

update public.processed_invoices p set dup_review = true
 where p.invoice_no_key is not null and p.kind_key in ('invoice','credit')
   and exists (select 1 from public.processed_invoices e
                where e.supplier_key = p.supplier_key and e.invoice_no_key = p.invoice_no_key
                  and e.kind_key = p.kind_key and e.id < p.id);

drop trigger if exists processed_invoices_keys_trg on public.processed_invoices;
create trigger processed_invoices_keys_trg before insert or update of supplier, invoice_number, note
  on public.processed_invoices for each row execute function public.processed_invoices_set_keys();

create unique index if not exists processed_invoices_canonical_uidx
  on public.processed_invoices (supplier_key, invoice_no_key, kind_key)
  where invoice_no_key is not null and kind_key in ('invoice','credit') and not dup_review;

create table if not exists public.invoice_line_stock (
  ledger_id bigint not null references public.stock_ledger(id),
  invoice_line_id bigint not null references public.invoice_lines(id),
  unmatched_id bigint references public.ingest_unmatched(id),
  line_qty numeric not null,
  qty_base numeric not null,
  method text not null check (method in ('ingest','resolve')),
  created_at timestamptz not null default now(),
  primary key (ledger_id, invoice_line_id)
);
create unique index if not exists invoice_line_stock_line_uidx on public.invoice_line_stock (invoice_line_id);
alter table public.invoice_line_stock enable row level security;
revoke all on public.invoice_line_stock from public, anon, authenticated;
grant select on public.invoice_line_stock to service_role;

create table if not exists public.ingest_unmatched_line (
  unmatched_id bigint not null references public.ingest_unmatched(id),
  invoice_line_id bigint not null references public.invoice_lines(id),
  qty numeric,
  method text not null check (method in ('ingest','backfill_exact')),
  created_at timestamptz not null default now(),
  primary key (unmatched_id, invoice_line_id)
);
create unique index if not exists ingest_unmatched_line_line_uidx on public.ingest_unmatched_line (invoice_line_id);
alter table public.ingest_unmatched_line enable row level security;
revoke all on public.ingest_unmatched_line from public, anon, authenticated;
grant select on public.ingest_unmatched_line to service_role;

revoke all on function public.processed_invoice_keys(text,text,text) from public, anon, authenticated;
revoke all on function public.processed_invoices_set_keys() from public, anon, authenticated;
