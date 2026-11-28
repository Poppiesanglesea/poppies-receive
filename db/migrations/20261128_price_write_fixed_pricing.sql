-- 28 Nov 2026 — fix: writing a price to a Square variation that was VARIABLE_PRICING left it variable,
-- so the register still asked for a price (organic kale / silverbeet, apply ops 20/21).
-- Both Square price writers now set pricing_type = FIXED_PRICING together with price_money.
-- Backups: price_square_put_bak_20261128, square_set_variation_price_bak_20261128.
DO $b$ BEGIN
  EXECUTE replace(pg_get_functiondef('public.price_square_put(text,bigint,integer,text)'::regprocedure),
                  'public.price_square_put(', 'public.price_square_put_bak_20261128(');
  EXECUTE replace(pg_get_functiondef('public.square_set_variation_price(text,integer)'::regprocedure),
                  'public.square_set_variation_price(', 'public.square_set_variation_price_bak_20261128(');
  REVOKE ALL ON FUNCTION public.price_square_put_bak_20261128(text,bigint,integer,text) FROM public, anon, authenticated, service_role;
  REVOKE ALL ON FUNCTION public.square_set_variation_price_bak_20261128(text,integer) FROM public, anon, authenticated, service_role;
END $b$;

CREATE OR REPLACE FUNCTION public.price_square_put(p_var text, p_version bigint, p_cents integer, p_idem text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare g jsonb; obj jsonb; r jsonb; v_status int;
begin
  if to_regprocedure('pg_temp.square_mock_put(text,bigint,integer,text)') is not null then
    execute 'select pg_temp.square_mock_put($1, $2, $3, $4)' into r using p_var, p_version, p_cents, p_idem;
    return r;
  end if;
  g := square_api('GET', '/v2/catalog/object/' || p_var || '?include_related_objects=false', null);
  if coalesce((g->>'status')::int, 0) <> 200 then return jsonb_build_object('ok', false, 'error', 'GET ' || coalesce(g->>'status', 'no response')); end if;
  obj := g->'body'->'object';
  if (obj->>'version')::bigint <> p_version then return jsonb_build_object('ok', false, 'conflict', true, 'error', 'version changed'); end if;
  obj := jsonb_set(obj, '{item_variation_data,price_money}', jsonb_build_object('amount', p_cents, 'currency', 'AUD'));
  obj := jsonb_set(obj, '{item_variation_data,pricing_type}', '"FIXED_PRICING"'::jsonb);
  r := square_api('POST', '/v2/catalog/object', jsonb_build_object('idempotency_key', p_idem, 'object', obj));
  v_status := coalesce((r->>'status')::int, 0);
  if v_status = 200 then return jsonb_build_object('ok', true, 'version', (r->'body'->'catalog_object'->>'version')::bigint); end if;
  return jsonb_build_object('ok', false, 'conflict', coalesce(r::text ~* 'VERSION_MISMATCH', false),
                            'ambiguous', v_status = 0 or v_status >= 500 or v_status = 429,
                            'error', 'POST ' || coalesce(r->>'status', 'no response'), 'body', r->'body');
end $function$;

CREATE OR REPLACE FUNCTION public.square_set_variation_price(p_variation_id text, p_cents integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_get jsonb; v_obj jsonb; v_resp jsonb;
begin
  v_get := square_api('GET','/v2/catalog/object/'||p_variation_id||'?include_related_objects=false');
  if (v_get->>'status')::int <> 200 then
    return jsonb_build_object('ok',false,'stage','get','status',(v_get->>'status')::int,'body',v_get->'body');
  end if;
  v_obj := jsonb_set(v_get->'body'->'object','{item_variation_data,price_money}',
                     jsonb_build_object('amount',p_cents,'currency','AUD'));
  v_obj := jsonb_set(v_obj, '{item_variation_data,pricing_type}', '"FIXED_PRICING"'::jsonb);
  v_resp := square_api('POST','/v2/catalog/object', jsonb_build_object(
              'idempotency_key','poppies-rules-'||p_variation_id||'-'||p_cents::text||'-fixed',
              'object', v_obj));
  return jsonb_build_object('ok',(v_resp->>'status')::int = 200,'stage','upsert',
                            'status',(v_resp->>'status')::int,
                            'body', case when (v_resp->>'status')::int = 200 then null else v_resp->'body' end);
end $function$;
