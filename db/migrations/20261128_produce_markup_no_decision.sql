-- 28 Nov 2026 — Josh: produce prices that needed his decision now just take the markup (produce only).
DO $b$ BEGIN
  EXECUTE replace(pg_get_functiondef('public.produce_price_items(text,bigint[],boolean)'::regprocedure),
                  'public.produce_price_items(', 'public.produce_price_items_bak_20261128(');
  REVOKE ALL ON FUNCTION public.produce_price_items_bak_20261128(text,bigint[],boolean) FROM public, anon, authenticated;
END $b$;

CREATE OR REPLACE FUNCTION public.produce_price_items(p_source_id text, p_item_ids bigint[], p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  pi record; r record; v_lbl jsonb; res jsonb; p jsonb;
  v_applied jsonb := '[]'; v_held jsonb := '[]'; v_failed jsonb := '[]'; v_noprice jsonb := '[]'; v_skipped jsonb := '[]';
begin
  select * into pi from processed_invoices where source_id = p_source_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'invoice not booked'); end if;

  for r in
    select c.* from v_price_rule_candidates c
     where c.stock_item_id = any (coalesce(p_item_ids, '{}'))
       and c.retail_category = 'Produce' and c.policy_source = 'retail_category' and c.method = 'band'
       and c.lane <> 'never'
       and (c.skip_reason is null or (c.skip_reason = 'item has no current shelf price' and c.proposed_price is not null))
     order by c.stock_item_id
  loop
    v_lbl := produce_price_label(r.stock_item_id, r.square_variation_id)
             || jsonb_build_object('stock_item_id', r.stock_item_id, 'square_variation_id', r.square_variation_id,
                                   'old', r.old_price, 'new', r.proposed_price, 'pct', r.price_pct);
    if p_dry_run then
      v_applied := v_applied || v_lbl;
      continue;
    end if;
    p := jsonb_build_object('item', r.stock_item_id, 'variation', r.square_variation_id, 'old', r.old_price, 'new', r.proposed_price,
           'method', r.method, 'old_cost', r.anchor_cost, 'new_cost', r.new_cost, 'cost_pct', r.cost_pct, 'price_pct', r.price_pct,
           'cogs_after', r.cogs_pct_after, 'below_floor', r.below_floor, 'source', p_source_id,
           'basis_date', coalesce(pi.invoice_date, pi.processed_at::date), 'basis_seq', pi.id);
    if r.square_variation_id !~ '^[A-Z0-9]{20,}$' then
      v_failed := v_failed || (v_lbl || jsonb_build_object('error', 'no real Square variation id'));
    else
      res := price_propose(p || jsonb_build_object('mode', 'authorised', 'lane', 'auto', 'label', v_lbl,
               'supplier', canonical_supplier(pi.supplier), 'invoice_number', pi.invoice_number, 'invoice_date', pi.invoice_date,
               'department', canonical_department(pi.department),
               'authorised_by', 'auto (markup, Josh 28 Nov): invoice ' || coalesce(pi.invoice_number, p_source_id)));
      if res->>'outcome' = 'authorised' or (res->>'outcome' = 'replay' and coalesce((res->>'task_open')::boolean, false)) then
        v_applied := v_applied || v_lbl;
      else
        v_skipped := v_skipped || (v_lbl || jsonb_build_object('outcome', res->>'outcome', 'status', res->>'status'));
      end if;
    end if;
  end loop;

  select coalesce(jsonb_agg(produce_price_label(c.stock_item_id, c.square_variation_id)
                            || jsonb_build_object('stock_item_id', c.stock_item_id, 'square_variation_id', c.square_variation_id) order by c.name), '[]')
    into v_noprice
    from v_price_rule_candidates c
   where c.stock_item_id = any (coalesce(p_item_ids, '{}')) and c.skip_reason = 'item has no current shelf price'
     and not (c.retail_category = 'Produce' and c.policy_source = 'retail_category' and c.method = 'band'
              and c.lane <> 'never' and c.proposed_price is not null);

  return jsonb_build_object('ok', true, 'applied', v_applied, 'held', v_held, 'failed', v_failed, 'no_price', v_noprice, 'skipped', v_skipped);
end
$function$;
