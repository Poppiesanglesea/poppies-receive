// Tag-confirm pricing UI (staged with db/migrations/20261126_pricing_03_tag_confirm.sql). Forward-compatible:
// without price_mode the old "Done" behaviour is unchanged.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const script = readFileSync(new URL('../index.html', import.meta.url), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
const base = { source_id: 'inv-1', supplier: 'Supplier A', invoice_number: 'INV-0001', invoice_date: '2026-11-26', open: 1 };
function app(tasks, tickReply = { ok: true, status: 'done', register: 'updated' }) {
  const els = new Map(), reqs = [];
  const el = id => { if (!els.has(id)) els.set(id, { value: '', innerHTML: '', className: '', disabled: false, textContent: '' }); return els.get(id); };
  let card = { ...base, tasks };
  const ctx = vm.createContext({
    location: { hash: '' }, localStorage: { getItem: () => 'a'.repeat(48) }, window: { scrollTo() {} },
    document: { getElementById: el, addEventListener() {}, querySelector: () => null },
    fetch: async (url, o) => {
      const path = url.replace(/^.*delivery-app/, ''); reqs.push({ path, method: o?.method || 'GET' });
      if (path === '/deliveries') return { ok: true, status: 200, json: async () => ({ owner: false, staff: ['Fern'], cards: [card] }) };
      if (/\/tasks\/\d+\/tick$/.test(path)) return { ok: tickReply.ok, status: tickReply.ok ? 200 : 400, json: async () => tickReply };
      return { ok: true, status: 200, json: async () => ({ owner: false, items: [], recent: [], months: [] }) };
    },
    setTimeout: () => 0, clearTimeout() {}, history: { replaceState() {} }, encodeURIComponent, Date,
  });
  vm.runInContext(script, ctx);
  return { ctx, el, reqs };
}
const settle = async (n = 6) => { for (let i = 0; i < n; i++) await new Promise(r => setImmediate(r)); };
const tag = (o) => ({ id: 7, kind: 'tag', status: 'open', info: { name: 'Apples', old: 5, new: 5.4, per: 'per kg' }, ...o });

test('legacy tag job (no price_mode) keeps the plain Done button and old wording', async () => {
  const { ctx, el } = app([tag({})]);
  await settle(); await vm.runInContext('fetchDeliveries()', ctx); vm.runInContext('deliveryScreen("inv-1")', ctx);
  const h = el('app').innerHTML;
  assert.match(h, />Done</); assert.match(h, /Prices are already changed in Square/); assert.doesNotMatch(h, /update register/);
});
test('apply-on-confirm job shows "Tag changed — update register" and explains the register updates on confirm', async () => {
  const { ctx, el } = app([tag({ price_mode: 'apply_on_confirm', apply_state: 'ready' })]);
  await settle(); await vm.runInContext('fetchDeliveries()', ctx); vm.runInContext('deliveryScreen("inv-1")', ctx);
  const h = el('app').innerHTML;
  assert.match(h, /Tag changed — update register/); assert.match(h, /that updates the register price/);
});
test('failed / conflict / applied / superseded states render clearly; conflict has no button', async () => {
  for (const [state, re, button] of [['failed', /Try again — update register/, true], ['conflict', /Josh needs to check/, false],
                                     ['applied', /Register updated/, false], ['superseded', /Replaced by a newer price/, false]]) {
    const { ctx, el } = app([tag({ price_mode: 'apply_on_confirm', apply_state: state, status: state === 'applied' ? 'done' : 'open', done_by: 'Fern' })]);
    await settle(); await vm.runInContext('fetchDeliveries()', ctx); vm.runInContext('deliveryScreen("inv-1")', ctx);
    const h = el('app').innerHTML;
    assert.match(h, re, state);
    assert.equal(/onclick="tickTag\(7\)"/.test(h), button, state + ' button');
  }
});
test('a second tap while the first is in flight does not send a second request', async () => {
  const { ctx, reqs } = app([tag({ price_mode: 'apply_on_confirm', apply_state: 'ready' })]);
  await settle(); await vm.runInContext('fetchDeliveries()', ctx); vm.runInContext('deliveryScreen("inv-1")', ctx);
  vm.runInContext('WHO = "Fern"; pickName = (f) => f();', ctx);
  const a = vm.runInContext('tickTag(7)', ctx); vm.runInContext('tickTag(7)', ctx);
  await settle(10);
  assert.equal(reqs.filter(r => /\/tasks\/7\/tick$/.test(r.path)).length, 1);
});

const parts = [{ name: 'Pumpkin – Half', per: 'per kg', old: 2.5, new: 2.7, state: 'ready' }, { name: 'Pumpkin – Quarter', per: 'per kg', old: null, new: 1.4, state: 'blocked' }];
test('grouped job shows each smaller tag by name with old -> new, and asks to confirm the whole group', async () => {
  const { ctx, el } = app([tag({ price_mode: 'apply_on_confirm', apply_state: 'ready', parts })]);
  await settle(); await vm.runInContext('fetchDeliveries()', ctx); vm.runInContext('deliveryScreen("inv-1")', ctx);
  const h = el('app').innerHTML;
  assert.match(h, /Pumpkin – Half/); assert.match(h, /\$2\.50/); assert.match(h, /\$2\.70/);
  assert.match(h, /Pumpkin – Quarter/); assert.match(h, /Josh to check/);
  assert.match(h, /All 3 tags changed — update register/); assert.match(h, /Change the main tag and the smaller tags first/);
  assert.doesNotMatch(h, /VAR[A-Z0-9]{10,}/);
});
test('partial job: retry only when a smaller tag can be retried; otherwise Josh', async () => {
  for (const [state, re] of [['failed', /Try again — smaller tags/], ['conflict', /Josh needs to check a smaller tag/]]) {
    const { ctx, el } = app([tag({ price_mode: 'apply_on_confirm', apply_state: 'partial', parts: [{ ...parts[0], state }] })]);
    await settle(); await vm.runInContext('fetchDeliveries()', ctx); vm.runInContext('deliveryScreen("inv-1")', ctx);
    assert.match(el('app').innerHTML, re, state);
    assert.match(el('app').innerHTML, /Main price is in the register/);
  }
});
test('superseded tag-only reminder no longer asks staff to change the label; kept job says leave it', async () => {
  for (const [t, re] of [[tag({ status: 'superseded', price_mode: 'tag_only' }), /Replaced by a newer price/],
                         [tag({ status: 'kept', price_mode: 'apply_on_confirm', apply_state: 'kept' }), /Josh kept the register price/]]) {
    const { ctx, el } = app([t]);
    await settle(); await vm.runInContext('fetchDeliveries()', ctx); vm.runInContext('deliveryScreen("inv-1")', ctx);
    assert.match(el('app').innerHTML, re); assert.doesNotMatch(el('app').innerHTML, /onclick="tickTag/);
  }
});

test('Josh sees conflicting / unknown register prices and can resolve them (posts the register price he saw)', async () => {
  const t = tag({ price_mode: 'apply_on_confirm', apply_state: 'partial', main: { op: 41, state: 'applied', old: 5, new: 5.4 },
    parts: [{ op: 42, name: 'Pumpkin – Half', per: 'per kg', old: 2.5, new: 2.7, state: 'conflict', register_now: 2.6 },
            { op: 43, name: 'Pumpkin – Quarter', per: 'per kg', old: null, new: 1.4, state: 'blocked', register_now: null }] });
  const { ctx, el, reqs } = app([t]);
  await settle(); vm.runInContext('DLV.owner = true', ctx);
  await vm.runInContext('joshScreen()', ctx);
  const h = el('app').innerHTML;
  assert.match(h, /Register prices to check/); assert.match(h, /Pumpkin – Half/); assert.match(h, /register showed \$2\.60/i);
  assert.match(h, /No price has been recorded/); assert.match(h, /resolveOp\(42,'overwrite'\)/); assert.match(h, /resolveOp\(43,'skip'\)/);
  assert.doesNotMatch(h, /resolveOp\(41/);
  el('rn42').value = '2.60';
  await vm.runInContext("resolveOp(42, 'overwrite')", ctx); await settle();
  const r = reqs.find(x => x.path === '/owner/price-ops/42/resolve');
  assert.ok(r, 'resolve request sent'); assert.equal(r.method, 'POST');
});

test('after Josh keeps a register price, staff are told which tags to put back and to what price', async () => {
  const t = tag({ price_mode: 'apply_on_confirm', apply_state: 'restore', main: { op: 1, state: 'skipped', restore: true, restore_to: 5.2 },
    parts: [{ op: 2, name: 'Pumpkin – Half', per: 'per kg', old: 2.5, new: 2.7, state: 'skipped', restore: true, restore_to: 2.5 },
            { op: 3, name: 'Pumpkin – Quarter', per: 'per kg', old: null, new: 1.4, state: 'skipped', restore: true, restore_to: null }] });
  const { ctx, el } = app([t]);
  await settle(); await vm.runInContext('fetchDeliveries()', ctx); vm.runInContext('deliveryScreen("inv-1")', ctx);
  const h = el('app').innerHTML;
  assert.match(h, /Put these tags back/); assert.match(h, /Apples → <b>\$5\.20/); assert.match(h, /Pumpkin – Half → <b>\$2\.50/);
  assert.match(h, /Pumpkin – Quarter → <b>the price the register shows/); assert.match(h, /Tags put back — done/);
});
