-- Rollback for pricing_repair_01 (28 Nov 2026). Run as ONE transaction.
-- Restores v_price_rule_candidates and the seven functions from function_backup label 'pre-pricing-repair-2026-11-28',
-- then drops the three new functions. produce_price_attempts is kept as evidence (renamed *_archived, RLS on).
-- Proposals, tasks and prices made while the repair was live are NOT undone (ordinary records; owner decision).
-- If any replaced object was changed again after this migration, restoring the backup would drop that later change:
-- the guard refuses unless each live definition still carries this migration's marker.
do $$
declare x text;
begin
  foreach x in array array['produce_price_items(text,bigint[],boolean)', 'produce_price_sweep()', 'price_proposal_decide(bigint[],text,text)',
                           'price_proposal_apply(boolean)', 'delivery_price_decide(bigint,text,numeric,text)',
                           'sync_part_variation_prices(bigint,boolean)', 'price_rules_scan(boolean)'] loop
    if pg_get_functiondef(('public.' || x)::regprocedure) not like '%pricing-repair-2026-11-28%' then
      raise exception 'pricing_repair_01 rollback refused: % changed after the repair; restore by hand', x;
    end if;
  end loop;
  if pg_get_viewdef('public.v_price_rule_candidates'::regclass) not like '%retail_price_for_pack(b.pack_cost%' then
    raise exception 'pricing_repair_01 rollback refused: v_price_rule_candidates changed after the repair; restore by hand';
  end if;
  if (select count(*) from function_backup where label = 'pre-pricing-repair-2026-11-28') < 8 then
    raise exception 'pricing_repair_01 rollback refused: expected the 8 backups under pre-pricing-repair-2026-11-28';
  end if;
end $$;

select fn_backup_restore('v_price_rule_candidates', 'pre-pricing-repair-2026-11-28');
select fn_backup_restore('produce_price_items', 'pre-pricing-repair-2026-11-28');
select fn_backup_restore('produce_price_sweep', 'pre-pricing-repair-2026-11-28');
select fn_backup_restore('price_proposal_decide', 'pre-pricing-repair-2026-11-28');
select fn_backup_restore('price_proposal_apply', 'pre-pricing-repair-2026-11-28');
select fn_backup_restore('delivery_price_decide', 'pre-pricing-repair-2026-11-28');
select fn_backup_restore('sync_part_variation_prices', 'pre-pricing-repair-2026-11-28');
select fn_backup_restore('price_rules_scan', 'pre-pricing-repair-2026-11-28');

drop function if exists public.price_proposal_staleness(bigint);
drop function if exists public.price_current_calc(bigint);
drop function if exists public.retail_price_for_pack(numeric, numeric, numeric, text, boolean);

alter table public.produce_price_attempts rename to produce_price_attempts_archived;

-- readback (expect: view without retail_price_for_pack, no new functions, archived table present)
select pg_get_viewdef('public.v_price_rule_candidates'::regclass) like '%retail_price_for(b.new_cost%' as view_restored,
       (select count(*) from pg_proc where proname in ('retail_price_for_pack', 'price_current_calc', 'price_proposal_staleness')) as new_fns_left,
       to_regclass('public.produce_price_attempts_archived') is not null as attempts_archived;
