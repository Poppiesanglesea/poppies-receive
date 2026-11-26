-- Rollback for db/migrations/20261126_pricing_03_tag_confirm.sql.
-- Restores the six replaced functions from function_backup (label 'pre-tag-confirm-2026-11-26') and drops what 03 added.
-- Refuses to run while an apply-on-confirm job is mid-flight ('applying'). Authorised proposals that were never confirmed are
-- marked superseded (their register price was never changed); applied ones stay as history.
do $guard$ begin
  if exists (select 1 from public.delivery_tasks where apply_state = 'applying') then
    raise exception 'rollback refused: a register update is in progress';
  end if;
end $guard$;
select fn_backup_restore(f, 'pre-tag-confirm-2026-11-26')
  from unnest(array['produce_price_items','delivery_price_decide','price_rules_scan','price_proposal_apply',
                    'delivery_task_tick','delivery_tasks_list']) f;

update public.retail_price_proposal set status = 'superseded', decided_at = now(), decided_by = 'rollback of tag-confirm pricing'
 where status = 'authorised';
update public.delivery_tasks set status = 'closed', done_by = 'system', done_at = now()
 where price_mode = 'apply_on_confirm' and status = 'open';
update public.delivery_tasks set status = 'closed' where status = 'superseded';

drop function if exists public.delivery_tag_confirm(bigint, text);
drop function if exists public.price_parts_apply(jsonb, bigint, bigint, uuid);
drop function if exists public.price_propose_for_tag(bigint,text,numeric,numeric,text,text,numeric,numeric,numeric,numeric,numeric,boolean,text,text,text,date,text,text,jsonb);
drop function if exists public.price_square_put(text, bigint, integer, text);
drop function if exists public.price_square_get(text);
drop table if exists public.price_apply_audit;

drop index if exists public.retail_price_proposal_authorised_uniq;
alter table public.retail_price_proposal drop constraint if exists retail_price_proposal_status_check;
alter table public.retail_price_proposal add constraint retail_price_proposal_status_check
  check (status = any (array['pending','approved','rejected','applied','skipped','superseded']));
alter table public.retail_price_proposal drop column if exists parts, drop column if exists source, drop column if exists authorised_by, drop column if exists authorised_at;

alter table public.delivery_tasks drop constraint if exists delivery_tasks_status_check;
alter table public.delivery_tasks add constraint delivery_tasks_status_check
  check (status = any (array['open','done','approved','kept','escalated','closed']));
alter table public.delivery_tasks
  drop column if exists op_key, drop column if exists apply_result, drop column if exists attempts, drop column if exists claimed_at,
  drop column if exists claim_token, drop column if exists apply_state, drop column if exists proposal_id,
  drop column if exists price_mode;
