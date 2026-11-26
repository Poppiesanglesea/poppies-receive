// Recent deliveries (26 Nov 2026): all retail deliveries, last 14 days in full, older months folded.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const script = readFileSync(new URL('../index.html', import.meta.url), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
const recent = [
  { kind: 'invoice', id: 'drive-1', supplier: 'Supplier A', invoice_number: 'INV-0001', date: '2026-11-26', depts: ['Grocer'], lines: 27, booked: 10, open_jobs: 10 },
  { kind: 'invoice', id: 'drive-2', supplier: 'Garden <Co>', invoice_number: null, date: '2026-11-23', depts: ['Garden'], lines: 1, booked: 1, open_jobs: 0 },
  { kind: 'photo', id: '11111111-2222-3333-4444-555555555555', supplier: 'Supplier C', invoice_number: null, date: '2026-11-25', depts: ['Gift Store'], lines: 4, booked: null, open_jobs: 0 },
];
const octRows = [{ kind: 'invoice', id: 'drive-3', supplier: 'Supplier B', invoice_number: '9', date: '2026-10-30', depts: ['Grocer'], lines: 16, booked: 16, open_jobs: 0 }];
function app() {
  const els = new Map(), reqs = [];
  const el = id => { if (!els.has(id)) els.set(id, { value: '', innerHTML: '', className: '' }); return els.get(id); };
  const ctx = vm.createContext({
    location: { hash: '' }, localStorage: { getItem: () => 'a'.repeat(48) }, window: { scrollTo() {} },
    document: { getElementById: el, addEventListener() {}, querySelector: () => null },
    fetch: async (url, o) => {
      reqs.push({ url: url.replace(/^.*delivery-app/, ''), method: o?.method || 'GET' });
      const body = url.endsWith('/recent') ? { owner: false, items: [{ id: recent[2].id, supplier: 'Supplier C', department: 'Gift Store', status: 'submitted', setup_status: 'ready', created_at: '2026-11-25T01:00:00Z' }] }
        : url.includes('/recent-deliveries?month=') ? { rows: octRows }
        : url.endsWith('/recent-deliveries') ? { recent, months: [{ month: '2026-10', count: 1 }] }
        : { owner: false, staff: [], cards: [] };
      return { ok: true, status: 200, json: async () => body };
    },
    setTimeout: () => 0, clearTimeout() {}, history: { replaceState() {} }, encodeURIComponent, Date,
  });
  vm.runInContext(script, ctx);
  return { ctx, el, reqs };
}
const settle = () => new Promise(r => setImmediate(r));
test('shows all retail deliveries with invoice detail, open jobs and photo status; escapes text', async () => {
  const { el, reqs } = app(); await settle(); await settle();
  assert.ok(reqs.every(r => r.method === 'GET'));
  const h = el('recent').innerHTML;
  assert.match(h, /Supplier A/); assert.match(h, /#INV-0001 · 27 lines · 10 booked/); assert.match(h, /10 jobs open/);
  assert.match(h, /in Square — print labels/); assert.match(h, /onclick="itemsScreen\(&quot;11111111-2222-3333-4444-555555555555&quot;\)"/);
  assert.match(h, /Garden &lt;Co&gt;/); assert.doesNotMatch(h, /Garden <Co>/);
  assert.match(el('months').innerHTML, /1 delivery ▸/);
});
test('department button filters the list', async () => {
  const { ctx, el } = app(); await settle(); await settle();
  vm.runInContext('RD.dept="Garden";drawRecent()', ctx);
  const h = el('recent').innerHTML;
  assert.match(h, /Garden &lt;Co&gt;/); assert.doesNotMatch(h, /Supplier A/); assert.doesNotMatch(h, /Supplier C/);
});
test('older months stay folded until tapped, then load that month only', async () => {
  const { ctx, el, reqs } = app(); await settle(); await settle();
  assert.doesNotMatch(el('months').innerHTML, /Supplier B/);
  await vm.runInContext('toggleMonth("2026-10")', ctx);
  assert.ok(reqs.some(r => r.url === '/recent-deliveries?month=2026-10'));
  assert.match(el('months').innerHTML, /Supplier B/); assert.match(el('months').innerHTML, /▾/);
  await vm.runInContext('toggleMonth("2026-10")', ctx);
  assert.doesNotMatch(el('months').innerHTML, /Supplier B/);
});
