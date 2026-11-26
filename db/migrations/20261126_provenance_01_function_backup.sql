-- STATUS: APPLIED 26 Nov 2026 (Supabase migration "provenance_01_function_backup").
-- Rollback point: copies current definitions of the functions the provenance work will change.
-- Mutations: creates table function_backup (RLS on, no anon/authenticated access) and inserts 8 rows;
-- creates helper fn_backup_restore(fn, label) (no anon/authenticated access). Changes no business data.
create table if not exists public.function_backup (
  id bigserial primary key,
  label text not null,
  fn_name text not null,
  signature text not null,
  definition text not null,
  captured_at timestamptz not null default now()
);
alter table public.function_backup enable row level security;
revoke all on public.function_backup from public, anon, authenticated;

insert into public.function_backup (label, fn_name, signature, definition)
select 'pre-provenance-2026-11-26', p.proname, p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
   and p.proname in ('ingest_invoice','ingest_invoice_line','queue_unmatched','map_unmatched','sweep_unmatched_mappable',
                     'new_stock_wire','invoice_line_mark_booked_from_unmatched','delivery_recent_list');

create or replace function public.fn_backup_restore(p_fn text, p_label text)
returns text language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare d text;
begin
  select definition into d from function_backup where fn_name = p_fn and label = p_label order by id desc limit 1;
  if d is null then raise exception 'no backup % for %', p_label, p_fn; end if;
  execute d;
  return 'restored ' || p_fn || ' from ' || p_label;
end $$;
revoke all on function public.fn_backup_restore(text, text) from public, anon, authenticated;
