-- STATUS: STAGED FOR REVIEW. NOT APPLIED. (Revision 2, after review: no silent exemptions, no unique index.)
-- Purpose: (1) visible invoice-identity keys and an exceptions register so a second copy of a supplier invoice that
-- arrives under an alias or a reformatted number is caught and quarantined, never silently exempted; (2) per-line
-- stock provenance tables (empty until the line-aware booking functions in a later file use them).
--
-- Identity policy (enforced by the later ingest change, under an advisory lock taken before any line is booked):
--   exact key  = canonical supplier + lower(number with whitespace removed)       -> same kind within 365 days = duplicate (not booked)
--   near key   = exact key with leading zeros stripped                             -> near match only = QUARANTINE (held, listed)
--   blank no.  = canonical supplier + invoice date + printed total + line count    -> match = QUARANTINE
--   different kind (invoice vs credit) never collides; statements are never booked.
-- A uniqueness index cannot express the 365-day window or the near/quarantine split, so none is created; the lock +
-- policy check is the guard, and the exceptions table is the visible record.
--
-- EXACT INTENDED MUTATIONS
--   processed_invoices: ADD COLUMN supplier_key, invoice_exact_key, invoice_near_key, kind_key (text, nullable).
--     UPDATE those 4 columns on every row (derived values only; no existing column changes).
--   CREATE trigger processed_invoices_keys_trg (BEFORE INSERT/UPDATE OF supplier, invoice_number, note).
--   CREATE TABLE invoice_identity_exception; INSERT one 'open' row per existing collision group found by the policy
--     above (count and ids reported in the restricted record, not here). Nothing about the colliding invoices,
--     their lines or stock is changed.
--   CREATE TABLE invoice_line_stock, ingest_unmatched_line (empty).
--   CREATE FUNCTION processed_invoice_keys, processed_invoices_set_keys.
--   All new objects: RLS on / no anon or authenticated access.
-- NO deletes. NO changes to stock_ledger, invoice_lines, prices, Square or email.
-- Rollback: db/rollback/20261126_provenance_02_schema_rollback.sql (asserts the new tables are unused first).

alter table public.processed_invoices
  add column if not exists supplier_key text,
  add column if not exists invoice_exact_key text,
  add column if not exists invoice_near_key text,
  add column if not exists kind_key text;

create or replace function public.processed_invoice_keys(p_supplier text, p_invno text, p_note text)
returns table (supplier_key text, invoice_exact_key text, invoice_near_key text, kind_key text)
language sql stable set search_path to 'public', 'pg_temp' as $$
  with n as (select nullif(lower(regexp_replace(coalesce(p_invno, ''), '\s+', '', 'g')), '') as x)
  select lower(btrim(canonical_supplier(p_supplier))),
         n.x,
         case when n.x is null then null else coalesce(nullif(ltrim(n.x, '0'), ''), '0') end,
         case when coalesce(p_note, '') ilike 'CREDIT%' then 'credit'
              when coalesce(p_note, '') ilike 'STATEMENT%' then 'statement'
              when coalesce(p_note, '') like 'DUPLICATE%' then 'duplicate'
              else 'invoice' end
    from n;
$$;

create or replace function public.processed_invoices_set_keys()
returns trigger language plpgsql set search_path to 'public', 'pg_temp' as $$
begin
  select k.supplier_key, k.invoice_exact_key, k.invoice_near_key, k.kind_key
    into new.supplier_key, new.invoice_exact_key, new.invoice_near_key, new.kind_key
    from processed_invoice_keys(new.supplier, new.invoice_number, new.note) k;
  return new;
end $$;

update public.processed_invoices p
   set (supplier_key, invoice_exact_key, invoice_near_key, kind_key) =
       (select k.supplier_key, k.invoice_exact_key, k.invoice_near_key, k.kind_key
          from public.processed_invoice_keys(p.supplier, p.invoice_number, p.note) k);

drop trigger if exists processed_invoices_keys_trg on public.processed_invoices;
create trigger processed_invoices_keys_trg before insert or update of supplier, invoice_number, note
  on public.processed_invoices for each row execute function public.processed_invoices_set_keys();

create table if not exists public.invoice_identity_exception (
  id bigserial primary key,
  kind text not null check (kind in ('exact_duplicate', 'near_number', 'blank_number_fingerprint')),
  supplier_key text not null,
  match_key text not null,
  processed_invoice_ids bigint[] not null,
  sources_with_stock int not null default 0,
  status text not null default 'open' check (status in ('open', 'resolved')),
  note text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by text
);
alter table public.invoice_identity_exception enable row level security;
revoke all on public.invoice_identity_exception from public, anon, authenticated;
grant select on public.invoice_identity_exception to service_role;

-- Seed: existing collision groups (booked invoices/credits only; DUPLICATE-noted rows are already handled).
insert into public.invoice_identity_exception (kind, supplier_key, match_key, processed_invoice_ids, sources_with_stock, note)
select g.kind, g.supplier_key, g.match_key, g.ids,
       (select count(*) from unnest(g.ids) i(id) join public.processed_invoices p on p.id = i.id
         where exists (select 1 from public.stock_ledger sl where sl.source = 'invoice:' || p.source_id and sl.movement_type = 'delivery')),
       'seeded by provenance_02: existing collision found by identity policy'
  from (
    select 'exact_duplicate'::text kind, supplier_key, invoice_exact_key match_key, array_agg(id order by id) ids
      from public.processed_invoices
     where invoice_exact_key is not null and kind_key in ('invoice', 'credit')
     group by supplier_key, invoice_exact_key, kind_key having count(*) > 1
    union all
    select 'near_number', supplier_key, invoice_near_key, array_agg(id order by id)
      from public.processed_invoices
     where invoice_near_key is not null and kind_key in ('invoice', 'credit')
     group by supplier_key, invoice_near_key, kind_key
    having count(*) > 1 and count(distinct invoice_exact_key) > 1
  ) g;

create table if not exists public.invoice_line_stock (
  ledger_id bigint not null references public.stock_ledger(id),
  invoice_line_id bigint not null references public.invoice_lines(id),
  unmatched_id bigint references public.ingest_unmatched(id),
  line_qty numeric not null,
  qty_base numeric not null,
  method text not null check (method in ('ingest', 'resolve')),
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
  method text not null check (method in ('ingest', 'backfill_exact')),
  created_at timestamptz not null default now(),
  primary key (unmatched_id, invoice_line_id)
);
create unique index if not exists ingest_unmatched_line_line_uidx on public.ingest_unmatched_line (invoice_line_id);
alter table public.ingest_unmatched_line enable row level security;
revoke all on public.ingest_unmatched_line from public, anon, authenticated;
grant select on public.ingest_unmatched_line to service_role;

revoke all on function public.processed_invoice_keys(text, text, text) from public, anon, authenticated;
revoke all on function public.processed_invoices_set_keys() from public, anon, authenticated;
