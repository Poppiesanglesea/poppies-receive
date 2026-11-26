// Edge shelf-tag confirm (supabase/functions/delivery-app/tags.ts): two calls, legacy fallback only when the claim
// function verifiably does not exist.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { confirmTag } from '../supabase/functions/delivery-app/tags.ts';

const rpcWith = (claim, apply = { data: { ok: true, status: 'done' }, error: null }) => {
  const calls = [];
  const rpc = async (fn, args) => {
    calls.push(fn);
    if (fn === 'delivery_tag_claim') return claim;
    if (fn === 'delivery_tag_apply') return typeof apply === 'function' ? apply(args) : apply;
    if (fn === 'delivery_task_tick') return { data: { ok: true, status: 'done', register: 'unchanged' }, error: null };
    throw new Error('unexpected ' + fn);
  };
  return { rpc, calls };
};

test('claim then apply (two calls, token passed through)', async () => {
  const { rpc, calls } = rpcWith({ data: { ok: true, phase: 'apply', token: 'tok-1' }, error: null },
    (args) => ({ data: { ok: args.p_token === 'tok-1', status: 'done' }, error: null }));
  const out = await confirmTag(rpc, 7, 'Fern');
  assert.deepEqual(calls, ['delivery_tag_claim', 'delivery_tag_apply']); assert.equal(out.status, 200);
});
test('legacy tick only when the claim function is verifiably missing (PGRST202 / 42883 naming it)', async () => {
  for (const err of [{ code: 'PGRST202', message: 'Could not find the function public.delivery_tag_claim(p_by, p_task_id) in the schema cache' },
                     { code: '42883', message: 'function delivery_tag_claim(bigint, text) does not exist' }]) {
    const { rpc, calls } = rpcWith({ data: null, error: err });
    const out = await confirmTag(rpc, 7, 'Fern');
    assert.deepEqual(calls, ['delivery_tag_claim', 'delivery_task_tick']); assert.equal(out.status, 200);
  }
});
test('any other claim failure is a retryable error and never falls back', async () => {
  for (const err of [{ code: '42501', message: 'permission denied for function delivery_tag_claim' },
                     { code: 'PGRST202', message: 'Could not find the function public.price_item_lock(p_stock_item_id)' },
                     { message: 'TypeError: fetch failed' }, { code: '57014', message: 'canceling statement due to statement timeout' }]) {
    const { rpc, calls } = rpcWith({ data: null, error: err });
    const out = await confirmTag(rpc, 7, 'Fern');
    assert.deepEqual(calls, ['delivery_tag_claim'], err.message); assert.equal(out.status, 502); assert.equal(out.body.retry, true);
  }
});
test('apply failure after a committed claim: retryable error, no fallback, claim left to expire', async () => {
  const { rpc, calls } = rpcWith({ data: { ok: true, phase: 'apply', token: 't' }, error: null }, { data: null, error: { message: 'fetch failed' } });
  const out = await confirmTag(rpc, 7, 'Fern');
  assert.deepEqual(calls, ['delivery_tag_claim', 'delivery_tag_apply']); assert.equal(out.status, 502); assert.match(out.body.error, /won't be changed twice/);
});
test('claim answers without an apply phase (busy, superseded, tag-only done) are returned as they are', async () => {
  const { rpc, calls } = rpcWith({ data: { ok: false, status: 'busy', error: 'Already being updated.' }, error: null });
  const out = await confirmTag(rpc, 7, 'Fern');
  assert.deepEqual(calls, ['delivery_tag_claim']); assert.equal(out.status, 400); assert.equal(out.body.status, 'busy');
});
