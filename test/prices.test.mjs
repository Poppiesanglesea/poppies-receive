// Shelf prices screen (26 Nov 2026): read-only lookup of live Square prices.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const script = readFileSync(new URL('../index.html', import.meta.url), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
const rows = [
  { item: 'Strawberries', variation: 'Punnet (Organic)', category: 'Fruit', price: 10.8, per: 'each', sold_out: false },
  { item: 'Tomatoes', variation: 'Red', category: 'Fruit', price: 9, per: 'kg', sold_out: false },
  { item: 'Tomatoes', variation: 'Heirloom', category: 'Fruit', price: null, per: 'kg', sold_out: false },
  { item: 'Bad <b>', variation: null, category: null, price: 1, per: 'each', sold_out: true },
];
function app(q, body = { ok: true, rows }) {
  const els = new Map(), reqs = [];
  const el = id => { if (!els.has(id)) els.set(id, { value: '', innerHTML: '' }); return els.get(id); };
  const ctx = vm.createContext({
    location: { hash: '' }, localStorage: { getItem: () => 'a'.repeat(48) }, window: { scrollTo() {} },
    document: { getElementById: el, addEventListener() {}, querySelector: () => null },
    fetch: async (url, o) => {
      if (!url.includes('/prices')) return { ok: true, status: 200, json: async () => ({ owner: false, items: [], staff: [], cards: [] }) };
      reqs.push({ url, method: o?.method || 'GET' });
      return { ok: body.ok !== false, status: body.ok === false ? 400 : 200, json: async () => body };
    },
    setTimeout: () => 0, clearTimeout() {}, history: { replaceState() {} }, encodeURIComponent,
  });
  vm.runInContext(script, ctx);
  el('pq').value = q;
  return { ctx, el, reqs };
}
test('searches with a GET only and shows prices with units', async () => {
  const { ctx, el, reqs } = app('tomato');
  await vm.runInContext('priceSearch()', ctx);
  assert.equal(reqs.length, 1); assert.equal(reqs[0].method, 'GET'); assert.match(reqs[0].url, /\/prices\?q=tomato$/);
  const h = el('pres').innerHTML;
  assert.match(h, /\$10\.80<\/b> each/); assert.match(h, /\$9\.00<\/b> \/ kg/); assert.match(h, /Price at register/);
  assert.match(h, /\(sold out\)/); assert.doesNotMatch(h, /<b>Bad/); assert.match(h, /Bad &lt;b&gt;/);
});
test('short queries do not call the server', async () => {
  const { ctx, reqs, el } = app('s');
  await vm.runInContext('priceSearch()', ctx);
  assert.equal(reqs.length, 0); assert.equal(el('pres').innerHTML, '');
});
test('errors are shown, not swallowed', async () => {
  const { ctx, el } = app('zz', { ok: false, error: 'Square is not answering right now.' });
  await vm.runInContext('priceSearch()', ctx);
  assert.match(el('pres').innerHTML, /Square is not answering/);
});
