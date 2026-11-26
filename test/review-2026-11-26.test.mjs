// Regressions for Codex review findings, 26 Nov 2026.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

// Minimal HTML attribute decoder, to check what the browser would actually run from onclick="...".
const decodeAttr = s => s.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
const onclicks = h => [...h.matchAll(/onclick="([^"]*)"/g)].map(m => decodeAttr(m[1]));

function app(routes = {}) {
  const els = new Map(), reqs = [];
  const el = id => { if (!els.has(id)) els.set(id, { value: '', innerHTML: '', className: '', insertAdjacentHTML(_, h) { this.innerHTML = h + this.innerHTML; } }); return els.get(id); };
  let gate = null;
  const ctx = vm.createContext({
    location: { hash: '' }, localStorage: { getItem: () => 'a'.repeat(48) }, window: { scrollTo() {} },
    document: { getElementById: el, addEventListener() {}, querySelector: () => null },
    fetch: async (url, o) => {
      const path = url.replace(/^.*delivery-app/, '');
      reqs.push(path);
      const h = Object.entries(routes).find(([k]) => path === k || path.startsWith(k + '?'));
      const res = h ? await h[1](path) : { owner: false, items: [], staff: [], cards: [], recent: [], months: [] };
      if (res && res.__status) return { ok: false, status: res.__status, json: async () => res.body || {} };
      return { ok: true, status: 200, json: async () => res };
    },
    setTimeout: () => 0, clearTimeout() {}, history: { replaceState() {} }, encodeURIComponent, Date, JSON, String,
  });
  vm.runInContext(script, ctx);
  return { ctx, el, els, reqs };
}
const settle = async (n = 4) => { for (let i = 0; i < n; i++) await new Promise(r => setImmediate(r)); };

test("supplier names with apostrophes produce a valid onclick (Farmer's Co)", async () => {
  const { ctx, el } = app();
  await settle();
  vm.runInContext(`SUP = { usual: ["Farmer's Co", 'Quote "Co"'], others: ["O'Brien & Sons"] }; S.dept = "Grocer";`, ctx);
  el('sq').value = '';
  vm.runInContext('drawSup()', ctx);
  const calls = onclicks(el('sup').innerHTML);
  assert.equal(calls.length, 3);
  for (const c of calls) assert.doesNotThrow(() => new Function(c), c); // parses as JS
  vm.runInContext('photoScreen = () => {}', ctx);
  vm.runInContext(calls[0], ctx); assert.equal(vm.runInContext('S.supplier', ctx), "Farmer's Co");
  vm.runInContext(calls[1], ctx); assert.equal(vm.runInContext('S.supplier', ctx), 'Quote "Co"');
  vm.runInContext(calls[2], ctx); assert.equal(vm.runInContext('S.supplier', ctx), "O'Brien & Sons");
});

test('home screen replies that arrive after navigating away do not write into the new screen', async () => {
  let release; const wait = new Promise(r => (release = r));
  const { ctx, el } = app({ '/recent': async () => { await wait; return { owner: true, items: [] }; },
                            '/recent-deliveries': async () => { await wait; return { recent: [{ kind: 'invoice', id: 'x', supplier: 'LATE', date: '2026-11-26', depts: ['Grocer'], lines: 1, booked: 1, waiting: 0, open_jobs: 0 }], months: [] }; } });
  await settle();
  vm.runInContext('$(`<h2>Other screen</h2>`)', ctx); // navigate away
  el('recent').innerHTML = 'SENTINEL'; el('own-needs').innerHTML = 'SENTINEL';
  release(); await settle(8);
  assert.equal(el('recent').innerHTML, 'SENTINEL');
  assert.equal(el('own-needs').innerHTML, 'SENTINEL');
});

test('owner buttons from /deliveries and /recent use separate slots (no overwrite race)', async () => {
  const { el } = app({ '/recent': async () => ({ owner: true, items: [] }), '/deliveries': async () => ({ owner: true, staff: [], cards: [] }) });
  await settle(8);
  assert.match(el('own-josh').innerHTML, /price decisions/);
  assert.match(el('own-needs').innerHTML, /waiting for a price/);
});

test('a failed month load shows an error, not an empty month', async () => {
  const { ctx, el } = app({ '/recent-deliveries': async (p) => p.includes('month=') ? { __status: 500, body: { error: 'x' } } : { recent: [], months: [{ month: '2026-10', count: 84 }] } });
  await settle(6);
  await vm.runInContext('toggleMonth("2026-10")', ctx);
  assert.match(el('months').innerHTML, /Couldn't load this month/);
  assert.doesNotMatch(el('months').innerHTML, /None for/);
});

test('a slow month reply cannot overwrite a month that was closed and reopened', async () => {
  let n = 0; const releases = [];
  const { ctx, el } = app({ '/recent-deliveries': async (p) => {
    if (!p.includes('month=')) return { recent: [], months: [{ month: '2026-10', count: 2 }] };
    const k = ++n; await new Promise(r => releases.push(r));
    return { rows: [{ kind: 'invoice', id: 'r' + k, supplier: k === 1 ? 'STALE' : 'FRESH', date: '2026-10-30', depts: ['Grocer'], lines: 1, booked: 1, waiting: 0, open_jobs: 0 }] };
  } });
  await settle(6);
  const first = vm.runInContext('toggleMonth("2026-10")', ctx); await settle();
  vm.runInContext('toggleMonth("2026-10")', ctx);                // close
  const second = vm.runInContext('toggleMonth("2026-10")', ctx); await settle(); // reopen
  releases[1](); await second; releases[0](); await first;       // fresh reply first, stale reply last
  assert.match(el('months').innerHTML, /FRESH/);
  assert.doesNotMatch(el('months').innerHTML, /STALE/);
});

test('recent rows show authoritative booked and waiting counts', async () => {
  const { el } = app({ '/recent-deliveries': async () => ({ recent: [{ kind: 'invoice', id: 's', supplier: 'Supplier A', invoice_number: 'INV-0001', date: '2026-11-26', depts: ['Grocer'], lines: 27, booked: 23, waiting: 4, open_jobs: 10 }], months: [] }) });
  await settle(8);
  assert.match(el('recent').innerHTML, /27 lines · 23 booked · <b[^>]*>4 waiting<\/b>/);
});

test('a 503 (settings unavailable) shows a retry banner and never the "not set up" screen', async () => {
  const { el } = app({ '/recent': async () => ({ __status: 503, body: { error: "The app can't reach its settings right now.", retry: true } }) });
  await settle(8);
  assert.match(el('busy').innerHTML, /can&#39;t reach its settings/);
  assert.match(el('busy').innerHTML, /Try again/);
  assert.doesNotMatch(el('app').innerHTML, /isn't set up yet/);
});

// ---- 503 / network resilience (Codex synthetic findings on 39ec238)
const unavailable = async () => ({ __status: 503, body: { error: "The app can't reach its settings right now.", retry: true } });

test('supplier list 503 shows an error with retry instead of throwing', async () => {
  const { ctx, el } = app({ '/suppliers': unavailable });
  await settle();
  await vm.runInContext('supplierScreen()', ctx);
  assert.match(el('sup').innerHTML, /can&#39;t reach its settings/);
  assert.match(el('sup').innerHTML, /onclick="supplierScreen\(\)"/);
});

test('price-needs 503 shows an error instead of throwing', async () => {
  const { ctx, el } = app({ '/owner/needs': unavailable, '/owner/awaiting': async () => [] });
  await settle();
  await vm.runInContext('needsScreen()', ctx);
  assert.match(el('app').innerHTML, /can&#39;t reach its settings/);
  assert.match(el('app').innerHTML, /onclick="needsScreen\(\)"/);
});

test('delivery products 503 shows an error, not a blank heading and empty table', async () => {
  const { ctx, el } = app({ '/receipts/11111111-2222-3333-4444-555555555555/items': unavailable });
  await settle();
  await vm.runInContext('itemsScreen("11111111-2222-3333-4444-555555555555")', ctx);
  const h = el('app').innerHTML;
  assert.match(h, /can&#39;t reach its settings/);
  assert.doesNotMatch(h, /<table>/);
});

test('busy banner retry re-runs only the current read and never clears photos or the receipt', async () => {
  const { ctx, el, reqs } = app({ '/suppliers': unavailable });
  await settle();
  vm.runInContext('S.dept = "Grocer"; S.photos = ["data:image/jpeg;base64,AAA"]; S.receipt = "keep-me";', ctx);
  await vm.runInContext('supplierScreen()', ctx);
  const before = reqs.filter(r => r.startsWith('/suppliers')).length;
  await vm.runInContext('retryView()', ctx); await settle();
  assert.equal(reqs.filter(r => r.startsWith('/suppliers')).length, before + 1);
  assert.equal(vm.runInContext('S.photos.length', ctx), 1);
  assert.equal(vm.runInContext('S.receipt', ctx), 'keep-me');
});

test('sending photos: a dropped connection keeps the photos, re-enables Send, warns it may have been saved, and does not resend', async () => {
  const { ctx, el, reqs } = app({ '/receipts': async () => { throw new Error('network down'); } });
  await settle();
  vm.runInContext('S.supplier = "Supplier A"; S.dept = "Grocer"; S.photos = ["data:image/jpeg;base64,AAA"];', ctx);
  vm.runInContext('photoScreen()', ctx);
  el('send').disabled = false;
  await vm.runInContext('sendPhotos()', ctx);
  assert.equal(reqs.filter(r => r === '/receipts').length, 1, 'no automatic replay');
  assert.equal(el('send').disabled, false);
  assert.equal(vm.runInContext('S.photos.length', ctx), 1);
  assert.match(el('pmsg').innerHTML, /may or may not have been saved/);
});

test('sending photos: a 503 says nothing was saved', async () => {
  const { ctx, el } = app({ '/receipts': unavailable });
  await settle();
  vm.runInContext('S.supplier = "Supplier A"; S.dept = "Grocer"; S.photos = ["data:image/jpeg;base64,AAA"];', ctx);
  vm.runInContext('photoScreen()', ctx);
  el('send').disabled = false;
  await vm.runInContext('sendPhotos()', ctx);
  assert.match(el('pmsg').innerHTML, /Nothing was saved/);
  assert.equal(el('send').disabled, false);
});
