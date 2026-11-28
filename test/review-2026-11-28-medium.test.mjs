// Review fixes, medium (28 Nov 2026): one request per tap, no redraw over a newer screen, decimal-comma prices,
// and a Cancel that lost to a send says so.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const script = readFileSync(new URL('../index.html', import.meta.url), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
const card = {
  source_id: 'inv-1', supplier: 'Supplier A', invoice_number: 'INV-0001', invoice_date: '2026-11-26', open: 1,
  tasks: [{ id: 3, kind: 'hold', status: 'open', info: { name: 'Zucchini', old: 16.2, new: 8.1, pct: -50, per: 'per kg' } }],
};
function app({ hold = false, reply = () => ({ ok: true }) } = {}) {
  const els = new Map(), reqs = []; let release;
  const gate = new Promise(r => { release = r; });
  const el = id => { if (!els.has(id)) els.set(id, { value: '', innerHTML: '', disabled: false, dataset: {}, textContent: '' }); return els.get(id); };
  const ctx = vm.createContext({
    location: { hash: '' }, localStorage: { getItem: () => 'a'.repeat(48) }, window: { scrollTo() {} },
    document: { getElementById: el, addEventListener() {}, querySelector: () => null },
    fetch: async (url, o) => {
      const path = url.replace(/^.*delivery-app/, ''), method = o?.method || 'GET';
      reqs.push({ path, method, body: o?.body ? JSON.parse(o.body) : null });
      if (path === '/deliveries') return { ok: true, status: 200, json: async () => ({ owner: true, staff: ['Fern'], cards: [structuredClone(card)] }) };
      if (method === 'POST' && hold) await gate;
      const r = reply(path); return { ok: (r.status ?? 200) < 300, status: r.status ?? 200, json: async () => r.body ?? r };
    },
    setTimeout: () => 0, clearTimeout() {}, history: { replaceState() {} }, encodeURIComponent, Date, confirm: () => true,
  });
  vm.runInContext(script, ctx);
  return { ctx, el, reqs, release, run: c => vm.runInContext(c, ctx) };
}
const posts = (a, end) => a.reqs.filter(r => r.method === 'POST' && r.path.endsWith(end));

test('a second tap while a decision is in flight sends nothing', async () => {
  const a = app({ hold: true });
  await a.run('joshScreen()');
  const p1 = a.run("decide(3, 'keep')"), p2 = a.run("decide(3, 'keep')");
  a.release(); await p1; await p2;
  assert.equal(posts(a, '/owner/tasks/3/decide').length, 1);
});

test('a slow save does not redraw over the screen staff moved to', async () => {
  const a = app({ hold: true });
  await a.run('joshScreen()');
  const p = a.run("decide(3, 'keep')");
  a.run('$("<h2>Checking lines</h2>")');      // staff moved on while the save was in flight
  a.release(); await p;
  assert.equal(a.el('app').innerHTML, '<h2>Checking lines</h2>');
});

test('register prices: decimal comma reads as a decimal point; junk is refused', async () => {
  const a = app();
  assert.equal(a.run('parsePrice("1,50")'), 1.5);
  assert.equal(a.run('parsePrice("$4.50")'), 4.5);
  assert.equal(a.run('parsePrice("")'), null);
  assert.ok(Number.isNaN(a.run('parsePrice("1.2.3")')));
  await a.run('joshScreen()');
  a.el('rn7').value = '1,50';
  await a.run("resolveOp(7, 'skip')");
  assert.deepEqual(posts(a, '/owner/price-ops/7/resolve')[0].body, { action: 'skip', register_now: 1.5 });
  a.el('rn8').value = 'abc';
  await a.run("resolveOp(8, 'skip')");
  assert.equal(posts(a, '/owner/price-ops/8/resolve').length, 0);
});

test('a Cancel that lost to a send says the delivery was already sent', async () => {
  const a = app({ reply: p => p.endsWith('/cancel') ? { status: 409, body: { error: 'already sent for set-up', status: 'submitted' } } : { ok: true } });
  a.run('REC = { id: "11111111-2222-3333-4444-555555555555" }; S.receipt = REC.id');
  await a.run('cancelRec()');
  assert.match(a.el('app').innerHTML, /Already sent/);
  assert.equal(a.run('S.receipt'), null);
});

test('Cancel does nothing while a send is in flight', async () => {
  const a = app();
  a.run('REC = { id: "11111111-2222-3333-4444-555555555555" }');
  a.el('go').disabled = true;
  await a.run('cancelRec()');
  assert.equal(posts(a, '/cancel').length, 0);
});
