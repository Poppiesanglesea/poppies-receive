// Review fixes (28 Nov 2026): a photo delivery read but not yet checked can be reopened from Recent deliveries,
// and Home asks before leaving a half-checked delivery.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const script = readFileSync(new URL('../index.html', import.meta.url), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
const ID = '11111111-2222-3333-4444-555555555555';
const recent = [{ kind: 'photo', id: ID, supplier: 'Supplier C', invoice_number: null, date: '2026-11-25', depts: ['Gift Store'], lines: 2, booked: null, open_jobs: 0 }];
const rec = { id: ID, status: 'ready', supplier: 'Supplier C', department: 'Gift Store', extraction: { invoice_number: 'D-1', lines: [{ description: 'Candle <big>', qty: 2, unit_price: 5 }] } };

function app({ status = 'ready', confirmAnswer = true } = {}) {
  const els = new Map(), reqs = [], asked = [];
  const el = id => { if (!els.has(id)) els.set(id, { value: '', innerHTML: '', className: '', disabled: false, dataset: {} }); return els.get(id); };
  const ctx = vm.createContext({
    location: { hash: '' }, localStorage: { getItem: () => 'a'.repeat(48) }, window: { scrollTo() {} },
    document: { getElementById: el, addEventListener() {}, querySelector: () => null },
    confirm: (q) => { asked.push(q); return confirmAnswer; },
    fetch: async (url, o) => {
      const path = url.replace(/^.*delivery-app/, '');
      reqs.push({ path, method: o?.method || 'GET' });
      const body = path === '/recent' ? { owner: false, items: [{ id: ID, supplier: 'Supplier C', department: 'Gift Store', status, setup_status: null, created_at: '2026-11-25T01:00:00Z' }] }
        : path === '/recent-deliveries' ? { recent, months: [] }
        : path === '/receipts/' + ID ? { ...rec, status }
        : { owner: false, staff: [], cards: [] };
      return { ok: true, status: 200, json: async () => body };
    },
    setTimeout: () => 0, clearTimeout() {}, history: { replaceState() {} }, encodeURIComponent, Date,
  });
  vm.runInContext(script, ctx);
  return { ctx, el, reqs, asked };
}
const settle = () => new Promise(r => setImmediate(r));

test('a read delivery "waiting for a check" can be tapped and opens its lines', async () => {
  const a = app(); await settle(); await settle();
  const h = a.el('recent').innerHTML;
  assert.match(h, /waiting for a check/);
  assert.match(h, new RegExp(`onclick="openReceipt\\(&quot;${ID}&quot;\\)"`));
  await vm.runInContext(`openReceipt(${JSON.stringify(ID)})`, a.ctx);
  const page = a.el('app').innerHTML;
  assert.match(page, /What came in\?/);
  assert.match(a.el('ln').innerHTML, /Candle &lt;big&gt;/);
  assert.equal(vm.runInContext('S.receipt', a.ctx), ID);
});

test('Home on a half-checked delivery asks first; saying no keeps the lines', async () => {
  const a = app({ confirmAnswer: false }); await settle(); await settle();
  await vm.runInContext(`openReceipt(${JSON.stringify(ID)})`, a.ctx);
  vm.runInContext('homeScreen()', a.ctx);
  assert.equal(a.asked.length, 1);
  assert.match(a.el('app').innerHTML, /What came in\?/);
  assert.equal(vm.runInContext('S.receipt', a.ctx), ID);
});

test('Cancel on the lines screen does not ask the Home question', async () => {
  const a = app(); await settle(); await settle();
  await vm.runInContext(`openReceipt(${JSON.stringify(ID)})`, a.ctx);
  await vm.runInContext('cancelRec()', a.ctx);
  assert.equal(a.asked.length, 0);
  assert.ok(a.reqs.some(r => r.path === `/receipts/${ID}/cancel` && r.method === 'POST'));
});
