-- APPLIED to production 27 Nov 2026 (Supabase migration "delivery_line_known"). Read-only.
-- Josh: show staff the barcode Square already holds for a delivery line that matches an existing product.
-- Same matching rule the invoice booking uses (match_product_map rank 1); barcode from the nightly Square copy
-- (square_variation_identity). Callable by service_role only (the Edge function).
create or replace function public.delivery_line_known(p_supplier text, p_department text, p_lines jsonb)
returns jsonb
language sql stable security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(k.known order by l.ord), '[]'::jsonb)
    from jsonb_array_elements(case when jsonb_typeof(p_lines) = 'array' then p_lines else '[]'::jsonb end) with ordinality l(line, ord)
    left join lateral (
      select jsonb_build_object(
               'stock_item_id', m.stock_item_id,
               'name', coalesce(v.item_name || case when coalesce(v.variation_name, '') not in ('', 'Regular') then ' – ' || v.variation_name else '' end, s.name),
               'upc', nullif(btrim(v.upc), '')) as known
        from match_product_map(canonical_supplier(p_supplier), l.line->>'description', nullif(l.line->>'sku', ''), canonical_department(p_department)) m
        join stock_items s on s.id = m.stock_item_id and s.archived is not true
        left join lateral (
          select vi.item_name, vi.variation_name, vi.upc
            from square_variation_identity vi
           where vi.variation_id in (select ssm.square_variation_id from square_sync_map ssm where ssm.stock_item_id = m.stock_item_id
                                     union select sm.square_variation_id from square_sales_map sm where sm.retail_stock_item_id = m.stock_item_id and sm.active)
             and vi.live is not false and vi.is_archived is not true
           order by (nullif(btrim(vi.upc), '') is null), vi.variation_id
           limit 1) v on true
       where m.rank = 1
       limit 1) k on true;
$$;
revoke all on function public.delivery_line_known(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.delivery_line_known(text, text, jsonb) to service_role;
-- Rollback: drop function public.delivery_line_known(text, text, jsonb);  (Edge v18 treats a failed lookup as "no matches")
