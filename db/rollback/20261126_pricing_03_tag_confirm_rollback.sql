-- Rollback for db/migrations/20261126_pricing_03_tag_confirm.sql (revision 2). Apply as ONE transaction.
-- Function-level rollback: restores the six replaced functions from function_backup (label 'pre-tag-confirm-2026-11-26')
-- and drops the functions 03 added. Financial-action evidence is KEPT: price_apply_op, price_apply_audit, the added
-- proposal/task columns and status values all stay (the restored functions ignore them).
-- Refuses while staff still have a tag to put back ('restore'), or while any register update is in flight or in doubt
-- ('applying' / 'ambiguous'): settle those first by
-- confirming again (which reads Square) or by Josh's decision, so no outcome is left unknown.
-- Order (added 28 Nov 2026 review): later changes build on 03, so they must be undone FIRST.
--   * pricing_repair_01 calls price_item_lock and price_propose, which this rollback drops, and replaces
--     produce_price_items / delivery_price_decide / price_proposal_apply, which this rollback would overwrite.
--     Run db/rollback/20261128_pricing_repair_01_rollback.sql first.
--   * 20261128_produce_markup_no_decision (applied 28 Nov, Josh's produce markup decision) replaced produce_price_items;
--     restoring the pre-03 backup would silently undo that decision. Restore it by hand (produce_price_items_bak_20261128)
--     or confirm with Josh before rolling 03 back.
do $order$
declare n int;
begin
  select count(*) into n from pg_proc
   where pronamespace = 'public'::regnamespace and prosrc like '%pricing-repair-2026-11-28%';
  if n > 0 or to_regprocedure('public.retail_price_for_pack(numeric,numeric,numeric,text,boolean)') is not null then
    raise exception 'rollback refused: pricing_repair_01 is applied (% functions carry its marker). Run its rollback first.', n;
  end if;
  if pg_get_functiondef('public.produce_price_items(text,bigint[],boolean)'::regprocedure) like '%auto (markup, Josh 28 Nov)%' then
    raise exception 'rollback refused: produce_price_items carries the 28 Nov produce markup decision; restoring the pre-03 copy would undo it. Settle with Josh first.';
  end if;
end $order$;

do $guard$ begin
  if exists (select 1 from public.delivery_tasks where apply_state = 'restore' and status = 'open') then
    raise exception 'rollback refused: staff still have a shelf tag to put back (finish that job first)';
  end if;
  if exists (select 1 from public.delivery_tasks where apply_state = 'applying')
     or exists (select 1 from public.price_apply_op where state in ('applying', 'ambiguous')) then
    raise exception 'rollback refused: a register update is in progress or its outcome is not yet confirmed';
  end if;
end $guard$;

select fn_backup_restore(f, 'pre-tag-confirm-2026-11-26')
  from unnest(array['produce_price_items','delivery_price_decide','price_rules_scan','price_proposal_apply',
                    'delivery_task_tick','delivery_tasks_list']) f;

-- close what the restored functions cannot act on; nothing is deleted
update public.price_apply_op set state = 'superseded', claim_token = null, updated_at = now(),
       last_result = coalesce(last_result, '{}') || '{"closed_by": "rollback of tag-confirm pricing"}'
 where state in ('ready', 'blocked', 'failed', 'conflict');
update public.retail_price_proposal set status = 'superseded', decided_at = now(), decided_by = 'rollback of tag-confirm pricing'
 where status = 'authorised';
update public.delivery_tasks set status = 'closed', done_by = 'system', done_at = now(),
       answer = coalesce(answer, '{}'::jsonb) || '{"closed_note": "rollback of tag-confirm pricing"}'
 where price_mode = 'apply_on_confirm' and status = 'open';
insert into public.price_apply_audit (outcome, by) values ('rollback_of_tag_confirm', 'migration');

drop function if exists public.price_op_resolve(bigint, text, integer, text);
drop function if exists public.delivery_tag_confirm(bigint, text);
drop function if exists public.delivery_tag_apply(bigint, uuid, text);
drop function if exists public.delivery_tag_claim(bigint, text);
drop function if exists public.price_task_settle(bigint, text);
drop function if exists public.price_op_run(bigint, text);
drop function if exists public.price_propose(jsonb);
drop function if exists public.price_square_put(text, bigint, integer, text);
drop function if exists public.price_square_get(text);
drop function if exists public.price_op_key(bigint, integer);
drop function if exists public.price_item_lock(bigint);
