-- Tests for migrations/20261128_price_write_fixed_pricing.sql (run by tests/run_local.sh fixedprice).
-- Square is replaced by a recording stub: GET serves rows from fp_square, POST records the body and stores it.
\set ON_ERROR_STOP 0
create table fp_square (id text primary key, obj jsonb not null);
create table fp_posts (n serial, idem text, obj jsonb);
drop function if exists public.square_api(text, text, jsonb);
create function public.square_api(m text, p text, b jsonb default null) returns jsonb language plpgsql as $$
declare v_id text; o jsonb;
begin
  if m = 'GET' then
    v_id := split_part(split_part(p, '/v2/catalog/object/', 2), '?', 1);
    select obj into o from fp_square where id = v_id;
    if o is null then return jsonb_build_object('status', 404); end if;
    return jsonb_build_object('status', 200, 'body', jsonb_build_object('object', o));
  end if;
  o := b->'object';
  insert into fp_posts (idem, obj) values (b->>'idempotency_key', o);
  o := jsonb_set(o, '{version}', to_jsonb((o->>'version')::bigint + 1));
  update fp_square set obj = o where id = o->>'id';
  return jsonb_build_object('status', 200, 'body', jsonb_build_object('catalog_object', o));
end $$;

insert into fp_square values
 ('VARV', '{"type":"ITEM_VARIATION","id":"VARV","version":10,"item_variation_data":{"item_id":"I1","name":"Organic","sku":"72551","pricing_type":"VARIABLE_PRICING","item_variation_vendor_info_ids":["VI1"]}}'),
 ('FIXV', '{"type":"ITEM_VARIATION","id":"FIXV","version":20,"item_variation_data":{"item_id":"I2","name":"Regular","pricing_type":"FIXED_PRICING","price_money":{"amount":505,"currency":"AUD"}}}'),
 ('LEGV', '{"type":"ITEM_VARIATION","id":"LEGV","version":30,"item_variation_data":{"item_id":"I3","name":"Organic","pricing_type":"VARIABLE_PRICING"}}');

create function pg_temp.ck(label text, ok boolean) returns void language plpgsql as $$
begin if ok then raise notice 'pass: %', label; else raise warning 'FAIL: %', label; end if; end $$;

-- 1) price_square_put on a variable-priced variation (the kale / silverbeet / iceberg case)
select pg_temp.ck('put: returns ok with new version', r->>'ok' = 'true' and (r->>'version')::bigint = 11)
  from (select price_square_put('VARV', 10, 450, 'k1') r) x;
select pg_temp.ck('put: variable variation becomes FIXED_PRICING', obj->'item_variation_data'->>'pricing_type' = 'FIXED_PRICING') from fp_square where id = 'VARV';
select pg_temp.ck('put: price written', (obj->'item_variation_data'->'price_money'->>'amount')::int = 450
                    and obj->'item_variation_data'->'price_money'->>'currency' = 'AUD') from fp_square where id = 'VARV';
select pg_temp.ck('put: name, sku, item and vendor links kept',
                  obj->'item_variation_data'->>'name' = 'Organic' and obj->'item_variation_data'->>'sku' = '72551'
                  and obj->'item_variation_data'->>'item_id' = 'I1'
                  and obj->'item_variation_data'->'item_variation_vendor_info_ids' = '["VI1"]') from fp_square where id = 'VARV';
select pg_temp.ck('put: caller idempotency key used unchanged', idem = 'k1') from fp_posts where n = 1;

-- 2) already fixed: stays fixed, price changes
select pg_temp.ck('put: fixed variation ok', (price_square_put('FIXV', 20, 550, 'k2'))->>'ok' = 'true');
select pg_temp.ck('put: fixed stays FIXED_PRICING at new price',
                  obj->'item_variation_data'->>'pricing_type' = 'FIXED_PRICING'
                  and (obj->'item_variation_data'->'price_money'->>'amount')::int = 550) from fp_square where id = 'FIXV';

-- 3) version changed since the job was read: conflict, nothing posted
select pg_temp.ck('put: stale version is a conflict', r->>'ok' = 'false' and r->>'conflict' = 'true')
  from (select price_square_put('FIXV', 20, 600, 'k3') r) x;
select pg_temp.ck('put: conflict posts nothing', count(*) = 2) from fp_posts;

-- 4) missing object: definite failure, nothing posted
select pg_temp.ck('put: missing variation fails without a write', (price_square_put('NOPE', 1, 100, 'k4'))->>'ok' = 'false');
select pg_temp.ck('put: still two posts', count(*) = 2) from fp_posts;

-- 5) legacy writer square_set_variation_price
select pg_temp.ck('legacy: ok', (square_set_variation_price('LEGV', 630))->>'ok' = 'true');
select pg_temp.ck('legacy: variable variation becomes FIXED_PRICING at price',
                  obj->'item_variation_data'->>'pricing_type' = 'FIXED_PRICING'
                  and (obj->'item_variation_data'->'price_money'->>'amount')::int = 630) from fp_square where id = 'LEGV';
select pg_temp.ck('legacy: new idempotency key (-fixed suffix)', idem = 'poppies-rules-LEGV-630-fixed') from fp_posts where n = 3;

-- 6) backups exist and are not callable by service_role
select pg_temp.ck('backups exist', to_regprocedure('public.price_square_put_bak_20261128(text,bigint,integer,text)') is not null
                  and to_regprocedure('public.square_set_variation_price_bak_20261128(text,integer)') is not null);
select pg_temp.ck('backups not executable by service_role',
                  not has_function_privilege('service_role', 'public.price_square_put_bak_20261128(text,bigint,integer,text)', 'execute')
                  and not has_function_privilege('service_role', 'public.square_set_variation_price_bak_20261128(text,integer)', 'execute'));
