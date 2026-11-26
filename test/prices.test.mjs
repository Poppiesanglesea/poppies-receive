// Shelf prices screen (26 Nov 2026): full read-only list of Square prices by department, with a filter.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const script = readFileSync(new URL('../index.html', import.meta.url), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
const rows = [
  { d: 'Grocer', s: 'Fruit', i: 'Strawberries', v: 'Punnet (Organic)', p: 10.8, u: 'each', x: false },
  { d: 'Grocer', s: 'Fruit', i: 'Strawberries', v: 'Punnet', p: 8.1, u: 'each', x: false },
  { d: 'Grocer', s: 'Vegetables', i: 'Tomatoes', v: 'Red', p: 9, u: 'kg', x: false },
  { d: 'Grocer', s: 'Vegetables', i: 'Tomatoes', v: 'Heirloom', p: null, u: 'kg', x: false },
  { d: 'Gift Store', s: 'Candles', i: 'Bad <b>', v: null, p: 1, u: 'each', x: true },
];
function app(body = { ok: true, rows, checked_at: '2026-11-26T09:16:04Z' }) {
  const els = new Map(), reqs = [];
  const el = id => { if (!els.has(id)) els.set(id, { value: '', innerHTML: '', className: '' }); return els.get(id); };
  const ctx = vm.createContext({
    location: { hash: '' }, localStorage: { getItem: () => 'a'.repeat(48) }, window: { scrollTo() {} },
    document: { getElementById: el, addEventListener() {}, querySelector: () => null },
    fetch: async (url, o) => {
      if (!url.includes('/prices')) return { ok: true, status: 200, json: async () => ({ owner: false, items: [], staff: [], cards: [] }) };
      reqs.push({ url, method: o?.method || 'GET' });
      return { ok: body.ok !== false, status: body.ok === false ? 500 : 200, json: async () => body };
    },
    setTimeout: () => 0, clearTimeout() {}, history: { replaceState() {} }, encodeURIComponent, Date,
  });
  vm.runInContext(script, ctx);
  return { ctx, el, reqs };
}
test('loads the list once with a GET and shows the Grocer department by section', async () => {
  const { ctx, el, reqs } = app();
  await vm.runInContext('pricesScreen()', ctx);
  assert.deepEqual(reqs.map(r => [r.method, r.url.replace(/^.*delivery-app/, '')]), [['GET', '/prices/all']]);
  const h = el('pres').innerHTML;
  assert.match(h, />Fruit</); assert.match(h, />Vegetables</);
  assert.match(h, /\$10\.80<\/b>/); assert.match(h, /\$9\.00<\/b> \/ kg/); assert.match(h, /Price at register/);
  assert.doesNotMatch(h, /Bad/); assert.match(h, /4 items/);
});
test('other departments stay hidden; output is escaped', async () => {
  const { ctx, el } = app();
  await vm.runInContext('pricesScreen()', ctx);
  vm.runInContext('PL.dept="Gift Store";priceDraw()', ctx);
  const h = el('pres').innerHTML;
  assert.match(h, /Bad &lt;b&gt;/); assert.doesNotMatch(h, /<b>Bad/); assert.match(h, /\(sold out\)/);
});
test('typing filters across all departments', async () => {
  const { ctx, el } = app();
  await vm.runInContext('pricesScreen()', ctx);
  el('pq').value = 'straw organic';
  vm.runInContext('priceDraw()', ctx);
  const h = el('pres').innerHTML;
  assert.match(h, /Punnet \(Organic\)/); assert.doesNotMatch(h, /— Punnet</); assert.match(h, />Fruit</); assert.match(h, /1 items/);
});
test('a failed load says so', async () => {
  const { ctx, el } = app({ ok: false, error: 'Price list isn\'t working right now.' });
  await vm.runInContext('pricesScreen()', ctx);
  assert.match(el('app').innerHTML, /isn&#39;t working right now/);
});
