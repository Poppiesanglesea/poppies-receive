-- Rollback for migrations/20261128_square_tile_hint.sql
-- Restores engine_health() from public.engine_health_bak_20261128() (created live 28 Nov 2026), then drops the view
-- and helper. No data is touched. Stock items, sales links and maps created on 28 Nov are data, not part of this file.
begin;
do $$ declare d text; begin
  if to_regprocedure('public.engine_health_bak_20261128()') is null then
    raise exception 'backup engine_health_bak_20261128() missing — refusing to roll back';
  end if;
  d := pg_get_functiondef('public.engine_health_bak_20261128()'::regprocedure);
  d := replace(d, 'FUNCTION public.engine_health_bak_20261128()', 'FUNCTION public.engine_health()');
  execute d;
end $$;
drop view if exists public.v_unmatched_square_tile_hint;
drop function if exists public.retail_name_stems(text);
commit;
-- Check: engine_health() returns no 'square_tile_unlinked' key.
