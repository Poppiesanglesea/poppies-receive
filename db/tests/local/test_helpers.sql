-- Session helpers for the pricing tests (synthetic items 100-119).
create function pg_temp.v(p_item int) returns text language sql immutable as $$ select 'VARSYNTH' || lpad((p_item - 100)::text, 16, '0') $$;
create function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
  begin if not coalesce(c, false) then raise exception 'FAIL: %', msg; end if; raise notice 'pass: %', msg; end $$;
create function pg_temp.cand(p_item int, p_new numeric, p_exceeds boolean default false) returns void language sql as $$
  delete from v_price_rule_candidates where stock_item_id = p_item;
  insert into v_price_rule_candidates (stock_item_id, name, retail_category, lane, method, policy_source, square_variation_id, anchor_cost, new_cost,
    cost_pct, old_price, proposed_price, price_pct, cogs_pct_after, below_floor, skip_reason, exceeds_max_pct)
  select p_item, 'Synthetic produce ' || (p_item - 100), 'Produce', 'auto', 'band', 'retail_category', pg_temp.v(p_item),
         2.8, 3.0, 7, s.retail_sell_price, p_new, round((p_new - s.retail_sell_price) / s.retail_sell_price * 100, 2), 55, false, null, p_exceeds
    from stock_items s where s.id = p_item $$;
create function pg_temp.task(p_item int) returns bigint language sql as $$
  select id from delivery_tasks where stock_item_id = p_item and kind = 'tag' order by id desc limit 1 $$;
create function pg_temp.confirm(p_task bigint, p_by text default 'Staff A') returns jsonb language sql as $$ select delivery_task_tick(p_task, p_by) $$;
create function pg_temp.deliver(p_src text, p_items int[]) returns jsonb language sql as $$
  insert into stock_ledger (stock_item_id, qty_base, movement_type, source) select i, 1, 'delivery', 'invoice:' || p_src from unnest(p_items) i;
  select produce_price_for_invoice(p_src, false) $$;

