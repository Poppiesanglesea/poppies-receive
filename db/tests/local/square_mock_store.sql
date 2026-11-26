-- Test-only stand-in for Square, kept in a SEPARATE database and reached through dblink so that its writes survive a
-- rollback in the database under test (exactly like a real external call). Emulates Square catalog semantics the
-- pricing code relies on: optimistic version check, and idempotency keys (same key -> same stored response, no 2nd write).
create table square (variation_id text primary key, cents int, version bigint not null default 1, puts int not null default 0,
  fail_get boolean not null default false, fail_put boolean not null default false,
  lose_response boolean not null default false, raise_after_write boolean not null default false, put_delay numeric not null default 0);
create table idem (key text primary key, variation_id text, cents int, response jsonb);
create function mock_get(p_var text) returns jsonb language plpgsql as $$
declare m square%rowtype;
begin
  select * into m from square where variation_id = p_var;
  if not found or m.fail_get then return jsonb_build_object('ok', false, 'error', 'mock get failure'); end if;
  return jsonb_build_object('ok', true, 'cents', m.cents, 'version', m.version, 'mock', true);
end $$;
create function mock_put(p_var text, p_version bigint, p_cents int, p_key text) returns jsonb language plpgsql as $$
declare m square%rowtype; r jsonb;
begin
  select response into r from idem where key = p_key;
  if found then return r || '{"replayed": true}'; end if;          -- Square returns the stored outcome for a reused key
  select * into m from square where variation_id = p_var for update;
  if not found or m.fail_put then return jsonb_build_object('ok', false, 'ambiguous', false, 'error', 'mock put failure'); end if;
  if m.version <> p_version then return jsonb_build_object('ok', false, 'conflict', true, 'error', 'version changed'); end if;
  perform pg_sleep(m.put_delay);                                    -- slow Square, for the concurrency test
  update square set cents = p_cents, version = version + 1, puts = puts + 1 where variation_id = p_var;
  insert into idem values (p_key, p_var, p_cents, jsonb_build_object('ok', true, 'mock', true));
  if m.lose_response then return jsonb_build_object('ok', false, 'ambiguous', true, 'error', 'mock timeout after write'); end if;
  if m.raise_after_write then return jsonb_build_object('raise', true); end if;
  return jsonb_build_object('ok', true, 'mock', true);
end $$;
