// 27 Nov 2026 (Josh): a delivery line that matches an existing product shows the barcode Square already holds.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const page = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const script = page.match(/<script>([\s\S]*?)<\/script>/)[1];
const edge = readFileSync(new URL('../supabase/functions/delivery-app/index.ts', import.meta.url), 'utf8');

function screen(known) {
  const els = new Map(), requests = [];
  const el = id => { if (!els.has(id)) els.set(id, { value: '', innerHTML: '', disabled: false }); return els.get(id); };
  const ctx = vm.createContext({
    location: { hash: '' }, localStorage: { getItem: () => null }, window: { scrollTo() {} },
    document: { getElementById: el, addEventListener() {}, querySelector: () => null },
    fetch: async (url, o) => { requests.push({ url, body: o?.body ? JSON.parse(o.body) : null }); return { ok: true, status: 200, json: async () => ({ status: 'submitted' }) }; },
    rec: {
      id: 'r1', status: 'ready', supplier: 'Biodynamic', department: 'Grocer', known,
      extraction: { lines: [
        { description: 'Cheese MOZZARELLA 250gm Symons Organic', qty: 4, unit: 'EA', unit_price: 7.8 },
        { description: 'Capsicums GREEN 4KG - Lower Don', qty: 1, unit: 'EA', unit_price: 55 },
        { description: 'Totally new thing', qty: 2, unit: 'EA', unit_price: 3 },
      ] },
    },
  });
  vm.runInContext(script, ctx);
  vm.runInContext('linesScreen(rec)', ctx);
  const rows = () => el('ln').innerHTML.split('<tr class="sub">').slice(1);
  return { ctx, el, rows, requests, run: s => vm.runInContext(s, ctx) };
}

const KNOWN = [
  { stock_item_id: 2332, name: 'Symons - Mozzarella', upc: '9353880000044' },
  { stock_item_id: 2330, name: 'Capsicum - Green (Organic)', upc: null },
  null,
];

test('a matched product with a barcode shows it read-only, with no Scan button', () => {
  const s = screen(KNOWN);
  const r = s.rows()[0];
  assert.match(r, /value="9353880000044" readonly/);
  assert.doesNotMatch(r, /scanFor\(0\)/);
  assert.match(r, /Already in Square: Symons - Mozzarella/);
});

test('a matched product without a barcode says so instead of offering a scan that would not save', () => {
  const r = screen(KNOWN).rows()[1];
  assert.match(r, /No barcode in Square for this product/);
  assert.doesNotMatch(r, /scanFor\(1\)/);
});

test('a new product keeps the empty barcode box and Scan button', () => {
  const r = screen(KNOWN).rows()[2];
  assert.match(r, /placeholder="Barcode"/);
  assert.match(r, /scanFor\(2\)/);
});

test('no lookup result (older server, or lookup failed) leaves every box as before', () => {
  const s = screen(undefined);
  for (const [i, r] of s.rows().entries()) { assert.match(r, new RegExp(`scanFor\\(${i}\\)`)); assert.doesNotMatch(r, /Already in Square/); }
});

test('renaming a matched line to something else drops the match and brings the box back', () => {
  const s = screen(KNOWN);
  s.run('renameLine(0, "Mozzarella buffalo 125g")');
  assert.match(s.rows()[0], /scanFor\(0\)/);
  assert.doesNotMatch(s.rows()[0], /9353880000044/);
});

test('splitting a matched line drops the match (the parts are different products)', () => {
  const s = screen(KNOWN);
  s.run('splitLine(0)');
  assert.equal(s.run('LINES[0].known'), null);
  assert.equal(s.run('LINES[1].known'), undefined);
});

test('the known barcode is never sent back with the delivery', async () => {
  const s = screen(KNOWN);
  await s.run('submitLines()');
  const body = s.requests.at(-1).body;
  assert.equal(body.lines.length, 3);
  for (const l of body.lines) { assert.equal('known' in l, false); assert.equal(l.barcode, ''); }
});

test('the server adds the lookup only for a ready delivery and keeps it out of what is stored', () => {
  assert.match(edge, /rec\.status === "ready"[^\n]*rec\.extraction\?\.lines/);
  assert.match(edge, /SB\.rpc\("delivery_line_known"/);
  assert.doesNotMatch(edge, /update\(\{[^}]*known/);
});
