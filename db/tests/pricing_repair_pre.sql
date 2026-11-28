-- pricing_repair_01 test, part 2 of 5 (before the migration). Run order: db/tests/run_pricing_repair_local.sh (local only).
-- Captures the state the migration must not change, and the pre-repair calculations for the unaffected-price check.
create temp table pr_t (n serial, name text, ok boolean, detail text) on commit drop;
create function pg_temp.ck(p_name text, p_ok boolean, p_detail text default null) returns void language sql
  as $$ insert into pr_t (name, ok, detail) values (p_name, coalesce(p_ok, false), p_detail) $$;

-- definitions: the seven replaced functions + the view (restored by the rollback) and the functions that must not change
create temp table pr_pre_fn on commit drop as
select p.oid::regprocedure::text sig, md5(pg_get_functiondef(p.oid)) h, pg_get_functiondef(p.oid) def
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
   and p.proname in ('produce_price_items', 'produce_price_sweep', 'price_proposal_decide', 'price_proposal_apply', 'delivery_price_decide',
                     'sync_part_variation_prices', 'price_rules_scan',
                     'price_propose', 'produce_price_for_invoice', 'delivery_tasks_add', 'delivery_tag_claim', 'delivery_tag_apply',
                     'price_op_run', 'price_square_get', 'price_square_put', 'square_set_variation_price', 'square_api',
                     'round_up_5c', 'retail_price', 'retail_price_for', 'retail_price_for_item', 'produce_price_label', 'delivery_owner_decide');
insert into pr_pre_fn values ('view', md5(pg_get_viewdef('public.v_price_rule_candidates'::regclass)), null);

-- the calculation before the repair (all categories) and every half/quarter's would-be price
create temp table pr_before on commit drop as select * from v_price_rule_candidates;
create temp table pr_parts_before on commit drop as
select i.id stock_item_id, sync_part_variation_prices(i.id, true)::text r
  from (select distinct sm.retail_stock_item_id id from square_sales_map sm
          join square_sync_map ssm on ssm.stock_item_id = sm.retail_stock_item_id
         where sm.active and sm.square_variation_id <> ssm.square_variation_id) i;

-- records the migration must leave alone
create function pg_temp.state() returns jsonb language sql as $$
  select jsonb_build_object(
    'shelf', (select md5(string_agg(id || ':' || coalesce(retail_sell_price::text, '-'), ',' order by id)) from stock_items),
    'parts', (select md5(coalesce(string_agg(square_variation_id || ':' || price, ',' order by square_variation_id), '')) from retail_part_variation_price),
    'proposals', (select md5(string_agg(id || ':' || status || ':' || coalesce(proposed_price::text, '-'), ',' order by id)) from retail_price_proposal),
    'tasks', (select md5(string_agg(id || ':' || coalesce(status, '-') || ':' || coalesce(info::text, '-'), ',' order by id)) from delivery_tasks),
    'ops', (select md5(coalesce(string_agg(id || ':' || state, ',' order by id), '')) from price_apply_op),
    'runs', (select count(*) from produce_price_runs),
    'history', (select count(*) from retail_price_history),
    'costs', (select count(*) from supplier_prices),
    'config', (select md5(string_agg(key || '=' || coalesce(value, ''), ',' order by key)) from app_config))
$$;
create temp table pr_state0 on commit drop as select pg_temp.state() s;
