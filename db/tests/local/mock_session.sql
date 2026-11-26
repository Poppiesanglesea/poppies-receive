-- Session hooks used by price_square_get/put in tests (see square_mock_store.sql). Needs test.mock_conn set.
-- session mock hooks picked up by price_square_get / price_square_put (they never call Square when these exist)
create function pg_temp.square_mock_get(p_var text) returns jsonb language sql as $$
  select r from dblink(current_setting('test.mock_conn'), format('select mock_get(%L)', p_var)) t(r jsonb) $$;
create function pg_temp.square_mock_put(p_var text, p_version bigint, p_cents int, p_key text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  select x into r from dblink(current_setting('test.mock_conn'), format('select mock_put(%L,%s,%s,%L)', p_var, p_version, p_cents, p_key)) t(x jsonb);
  if coalesce((r->>'raise')::boolean, false) then raise exception 'mock: connection dropped after Square accepted the write'; end if;
  return r;
end $$;
create function pg_temp.mx(p_sql text) returns void language sql as $$ select dblink_exec(current_setting('test.mock_conn'), p_sql) $$;
create function pg_temp.mq(p_var text, p_col text) returns int language sql as $$
  select v from dblink(current_setting('test.mock_conn'), format('select %I from square where variation_id = %L', p_col, p_var)) t(v int) $$;
