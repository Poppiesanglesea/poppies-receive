// Deliveries screen (26 Nov 2026): staff tick tags and count boxes; Josh decides held prices.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const script = readFileSync(new URL('../index.html', import.meta.url), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];

const card = {
  source_id: 'inv-1', supplier: 'Biodynamic', invoice_number: '1035493', invoice_date: '2026-11-26', open: 3,
  tasks: [
    { id: 1, kind: 'tag', status: 'open', info: { name: 'Beetroots – Gold (Organic)', old: 9.4, new: 7.2, per: 'per kg' } },
    { id: 2, kind: 'count', status: 'open', info: { description: 'Leeks DEC - Foothill', qty: 1, unit: 'DEC', unit_price: 60 },
      candidates: [{ stock_item_id: 1860, name: 'Leeks – Organic', count_unit: 'each', last_count: 36 }] },
    { id: 3, kind: 'hold', status: 'open', info: { name: 'Zucchini – Organic', old: 16.2, new: 8.1, pct: -50, per: 'per kg' } },
  ],
};

function app({ owner = false, checked = null, count = '' } = {}) {
  const elements = new Map();
  const requests = [];
  const el = id => { if (!elements.has(id)) elements.set(id, { value: '', innerHTML: '', disabled: false, dataset: {}, textContent: '', insertAdjacentHTML() {} }); return elements.get(id); };
  const ctx = vm.createContext({
    location: { hash: '' }, localStorage: { getItem: () => 'a'.repeat(48) }, window: { scrollTo() {} },
    document: { getElementById: el, addEventListener() {}, querySelector: () => checked },
    fetch: async (url, options) => {
      requests.push({ url, method: options?.method || 'GET', body: options?.body ? JSON.parse(options.body) : null });
      if (url.endsWith('/deliveries')) return { ok: true, status: 200, json: async () => ({ owner, staff: ['Fern', 'Rach'], cards: [structuredClone(card)] }) };
      return { ok: true, status: 200, json: async () => ({ ok: true }) };
    },
  });
  vm.runInContext(script, ctx);
  el('n2').value = count;
  return { run: c => vm.runInContext(c, ctx), requests, el };
}

test('ticking a tag asks who is doing it, then sends their name', async () => {
  const a = app();
  await a.run('fetchDeliveries()');
  a.run("deliveryScreen('inv-1')");
  assert.match(a.el('app').innerHTML, /Change these shelf tags/);
  a.run('tickTag(1)');
  assert.match(a.el('app').innerHTML, /Who's doing this/);
  assert.equal(a.requests.filter(r => r.url.includes('/tick')).length, 0);
  await a.run('nameChosen(0)');
  const tick = a.requests.find(r => r.url.endsWith('/tasks/1/tick'));
  assert.deepEqual(tick.body, { by: 'Fern' });
});

test('a count far from the last box needs a recount before it is saved', async () => {
  const a = app({ checked: { value: '1860', dataset: { unit: 'each', last: '36' } }, count: '12' });
  await a.run('fetchDeliveries()');
  a.run("deliveryScreen('inv-1'); WHO='Fern'");
  a.el('n2').value = '12';
  a.run('saveCount(2)');
  assert.equal(a.requests.filter(r => r.url.includes('/count')).length, 0);
  assert.match(a.el('cm2').innerHTML, /last box of this had 36/);
  await a.run('saveCount(2)');
  const sent = a.requests.find(r => r.url.endsWith('/tasks/2/count'));
  assert.deepEqual(sent.body, { stock_item_id: 1860, count: 12, by: 'Fern' });
});

test('"None of these" sends the count with no product, for Josh to set up', async () => {
  const a = app({ checked: { value: '', dataset: { unit: '', last: '' } } });
  await a.run('fetchDeliveries()');
  a.run("deliveryScreen('inv-1'); WHO='Rach'");
  a.el('n2').value = '20';
  await a.run('saveCount(2)');
  const sent = a.requests.find(r => r.url.endsWith('/tasks/2/count'));
  assert.deepEqual(sent.body, { stock_item_id: null, count: 20, by: 'Rach' });
});

test('a count of zero or blank is never sent', async () => {
  const a = app({ checked: { value: '1860', dataset: { unit: 'each', last: '36' } } });
  await a.run('fetchDeliveries()');
  a.run("deliveryScreen('inv-1'); WHO='Fern'");
  a.el('n2').value = '0';
  a.run('saveCount(2)');
  assert.equal(a.requests.filter(r => r.url.includes('/count')).length, 0);
});

test('staff see held prices as "keep the tag" with no decision buttons', async () => {
  const a = app({ owner: false });
  await a.run('fetchDeliveries()');
  a.run("deliveryScreen('inv-1')");
  const html = a.el('app').innerHTML;
  assert.match(html, /keep at \$16\.20/);
  assert.match(html, /Josh is deciding/);
  assert.doesNotMatch(html, /Change to \$8\.10/);
});

test('Josh can keep a held price from his list', async () => {
  const a = app({ owner: true });
  await a.run('joshScreen()');
  assert.match(a.el('app').innerHTML, /Change to \$8\.10/);
  await a.run("decide(3, 'keep')");
  const d = a.requests.find(r => r.url.endsWith('/owner/tasks/3/decide'));
  assert.deepEqual(d.body, { decision: 'keep', price: null });
});
