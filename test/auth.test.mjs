// delivery-app auth (26 Nov 2026): config failures fail closed as 503, never cached, never reported as a bad key.
// Run with: node --experimental-strip-types --test test/*.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ConfigUnavailable, makeCfg, whoFromHeaders, constantTimeEq } from '../supabase/functions/delivery-app/auth.ts';

const DEV = 'd'.repeat(48), OWN = 'e'.repeat(48);
const hdr = (o) => ({ get: (n) => o[n] ?? null });
function store(over = {}) {
  const calls = [];
  const values = { delivery_device_key: DEV, delivery_owner_key: OWN, ...over.values };
  const read = async (key) => {
    calls.push(key);
    if (over.fail && over.fail(key, calls.length)) return { value: null, error: { message: 'timeout' } };
    if (over.throws && over.throws(key, calls.length)) throw new Error('network');
    return { value: values[key] ?? null, error: null };
  };
  return { read, calls };
}

test('valid device key is authorised; wrong and malformed keys are 401-style (device=false), not errors', async () => {
  const s = store(); const cfg = makeCfg(s.read);
  assert.deepEqual(await whoFromHeaders(hdr({ 'x-device-key': DEV }), cfg), { device: true, owner: false });
  assert.deepEqual(await whoFromHeaders(hdr({ 'x-device-key': 'f'.repeat(48) }), cfg), { device: false, owner: false });
  const before = s.calls.length;
  assert.deepEqual(await whoFromHeaders(hdr({ 'x-device-key': 'not-a-key' }), cfg), { device: false, owner: false });
  assert.deepEqual(await whoFromHeaders(hdr({}), cfg), { device: false, owner: false });
  assert.equal(s.calls.length, before, 'malformed/missing keys never read config');
});

test('owner key implies device; wrong owner key falls back to device key check', async () => {
  const s = store(); const cfg = makeCfg(s.read);
  assert.deepEqual(await whoFromHeaders(hdr({ 'x-owner-key': OWN }), cfg), { device: true, owner: true });
  assert.deepEqual(await whoFromHeaders(hdr({ 'x-owner-key': 'f'.repeat(48), 'x-device-key': DEV }), cfg), { device: true, owner: false });
});

test('a config read error throws ConfigUnavailable (=> 503), and is not cached', async () => {
  let failing = true;
  const s = store({ fail: () => failing }); const cfg = makeCfg(s.read);
  await assert.rejects(whoFromHeaders(hdr({ 'x-device-key': DEV }), cfg), ConfigUnavailable);
  failing = false; // recovery: next request reads again and succeeds
  assert.deepEqual(await whoFromHeaders(hdr({ 'x-device-key': DEV }), cfg), { device: true, owner: false });
});

test('a thrown read and an empty/missing value are also ConfigUnavailable, never "invalid device"', async () => {
  const t = store({ throws: () => true });
  await assert.rejects(whoFromHeaders(hdr({ 'x-device-key': DEV }), makeCfg(t.read)), ConfigUnavailable);
  const e = store({ values: { delivery_device_key: '' } });
  await assert.rejects(whoFromHeaders(hdr({ 'x-device-key': DEV }), makeCfg(e.read)), ConfigUnavailable);
});

test('successful reads are cached for the TTL; expiry re-reads', async () => {
  let t = 0; const s = store(); const cfg = makeCfg(s.read, { ttlMs: 1000, now: () => t });
  await cfg('delivery_device_key'); await cfg('delivery_device_key');
  assert.equal(s.calls.length, 1);
  t = 1001; await cfg('delivery_device_key');
  assert.equal(s.calls.length, 2);
});

test('concurrent requests share one read; a concurrent failure fails all of them and the next call recovers', async () => {
  let release, n = 0;
  const gate = new Promise((r) => (release = r));
  const read = async (key) => { n++; await gate; return n === 1 ? { value: null, error: { message: 'blip' } } : { value: DEV, error: null }; };
  const cfg = makeCfg(read);
  const ps = Array.from({ length: 5 }, () => whoFromHeaders(hdr({ 'x-device-key': DEV }), cfg));
  release();
  const results = await Promise.allSettled(ps);
  assert.equal(n, 1, 'one shared read');
  assert.ok(results.every((r) => r.status === 'rejected' && r.reason instanceof ConfigUnavailable));
  assert.deepEqual(await whoFromHeaders(hdr({ 'x-device-key': DEV }), cfg), { device: true, owner: false });
  assert.equal(n, 2);
});

test('constant-time compare basics', () => {
  assert.equal(constantTimeEq('abc', 'abc'), true);
  assert.equal(constantTimeEq('abc', 'abd'), false);
  assert.equal(constantTimeEq('', ''), false);
  assert.equal(constantTimeEq('ab', 'abc'), false);
});
