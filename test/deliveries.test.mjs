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

test('"None of these" sends the count and what was counted, with no product, for Josh to set up', async () => {
  const a = app({ checked: { value: '', dataset: { unit: '', last: '' } } });
  await a.run('fetchDeliveries()');
  a.run("deliveryScreen('inv-1'); WHO='Rach'");
  a.el('n2').value = '4';
  a.el('us2').value = 'kg';
  await a.run('saveCount(2)');
  const sent = a.requests.find(r => r.url.endsWith('/tasks/2/count'));
  assert.deepEqual(sent.body, { stock_item_id: null, count: 4, by: 'Rach', note: 'unit: kg' });
});

test('"None of these" without saying kg, items or bunches is not sent', async () => {
  const a = app({ checked: { value: '', dataset: { unit: '', last: '' } } });
  await a.run('fetchDeliveries()');
  a.run("deliveryScreen('inv-1'); WHO='Rach'");
  a.el('n2').value = '4';
  a.run('saveCount(2)');
  assert.equal(a.requests.filter(r => r.url.includes('/count')).length, 0);
  assert.match(a.el('cm2').innerHTML, /kg, items or bunches/);
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

// ---- box sizes (26 Nov 2026): only box lines are listed; staff fix one delivery; Josh decides the usual size
function boxApp({ owner = false } = {}) {
  const withBoxes = structuredClone(card);
  withBoxes.boxes = [{ line_id: 77, stock_item_id: 2328, name: 'Mushrooms – Flat', description: 'Mushroom White Flat', qty: 1, unit: 'Box', count_unit: 'kg', usual: 4, report: null }];
  withBoxes.tasks.push({ id: 9, kind: 'boxsize', status: 'open', info: { name: 'Mushrooms - Flat (Retail)', unit: 'box', count_unit: 'kg', usual: 4, actual: 3.5, reported_by: 'Fern' } });
  const elements = new Map(); const requests = [];
  const el = id => { if (!elements.has(id)) elements.set(id, { value: '', innerHTML: '', disabled: false, dataset: {}, textContent: '', insertAdjacentHTML() {} }); return elements.get(id); };
  const ctx = vm.createContext({
    location: { hash: '' }, localStorage: { getItem: () => 'a'.repeat(48) }, window: { scrollTo() {} },
    document: { getElementById: el, addEventListener() {}, querySelector: () => null },
    fetch: async (url, options) => {
      requests.push({ url, method: options?.method || 'GET', body: options?.body ? JSON.parse(options.body) : null });
      if (url.endsWith('/deliveries')) return { ok: true, status: 200, json: async () => ({ owner, staff: ['Fern'], cards: [structuredClone(withBoxes)] }) };
      return { ok: true, status: 200, json: async () => ({ ok: true, status: 'recorded' }) };
    },
  });
  vm.runInContext(script, ctx);
  return { run: c => vm.runInContext(c, ctx), requests, el };
}

test('box lines show a "Different size?" option with the usual size', async () => {
  const a = boxApp();
  await a.run('fetchDeliveries()');
  a.run("deliveryScreen('inv-1')");
  const html = a.el('app').innerHTML;
  assert.match(html, /Boxes on this delivery/);
  assert.match(html, /usually 4 kg in each/);
  assert.match(html, /Different size\?/);
});

test('reporting a box sends what was in it and who checked', async () => {
  const a = boxApp();
  await a.run('fetchDeliveries()');
  a.run("deliveryScreen('inv-1'); WHO='Fern'; openBox(77)");
  a.el('bv77').value = '3.5';
  await a.run('saveBox(77)');
  const sent = a.requests.find(r => r.url.endsWith('/deliveries/inv-1/boxes/77/report'));
  assert.deepEqual(sent.body, { actual: 3.5, by: 'Fern' });
});

test('an empty box report is not sent', async () => {
  const a = boxApp();
  await a.run('fetchDeliveries()');
  a.run("deliveryScreen('inv-1'); WHO='Fern'; openBox(77)");
  a.el('bv77').value = '';
  a.run('saveBox(77)');
  assert.equal(a.requests.filter(r => r.url.includes('/boxes/')).length, 0);
});

test('Josh sees the box-size question and can make it the usual', async () => {
  const a = boxApp({ owner: true });
  await a.run('joshScreen()');
  const html = a.el('app').innerHTML;
  assert.match(html, /Box sizes/);
  assert.match(html, /Make 3\.5 kg the usual/);
  await a.run("decide(9, 'approve')");
  const d = a.requests.find(r => r.url.endsWith('/owner/tasks/9/decide'));
  assert.equal(d.body.decision, 'approve');
});

test('a practice delivery says clearly that nothing changes', async () => {
  const a = app();
  await a.run('fetchDeliveries()');
  a.run("DLV.cards[0].practice = true; deliveryScreen('inv-1')");
  assert.match(a.el('app').innerHTML, /PRACTICE DELIVERY/);
  assert.doesNotMatch(a.el('app').innerHTML, /Prices are already changed in Square/);
});
