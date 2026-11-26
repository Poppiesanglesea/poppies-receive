// Photo-receipt intake (supabase/functions/delivery-app/receipts.ts) against in-memory stand-ins for the database,
// storage and the invoice reader. Synthetic suppliers only.
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { createReceipt, reconcileReceipt } from '../supabase/functions/delivery-app/receipts.ts';

function world() {
  const rows = new Map(), store = new Map(), queue = new Set(), log = [], fail = {};
  const calls = { dispatch: 0, uploads: 0, inserts: 0 };
  let t = Date.parse('2026-11-26T10:00:00Z');
  const clone = (x) => JSON.parse(JSON.stringify(x));
  const deps = {
    getReceipt: async (id) => fail.get ? { data: null, error: { message: 'db down' } } : { data: rows.has(id) ? clone(rows.get(id)) : null, error: null },
    insertReceipt: async (row) => {
      calls.inserts++; log.push('insert');
      if (fail.insert) return { error: { message: 'db down' } };
      if (rows.has(row.id)) return { error: { code: '23505', message: 'duplicate key' } };
      rows.set(row.id, { created_at: new Date(t).toISOString(), hold_reason: null, ...clone(row) });
      return { error: null };
    },
    updateReceipt: async (id, patch, cond) => {
      if (fail.update) return { data: null, error: { message: 'db down' } };
      const r = rows.get(id);
      if (!r || !cond.statuses.includes(r.status)) return { data: [], error: null };
      if ('dispatchToken' in cond && (r.confirmed_payload?.upload?.dispatch_token ?? null) !== cond.dispatchToken) return { data: [], error: null };
      if (fail.updateOnce && patch.status) { delete fail.updateOnce; return { data: null, error: { message: 'db down' } }; }
      Object.assign(r, clone(patch));
      return { data: [clone(r)], error: null };
    },
    upload: async (path, bytes) => {
      calls.uploads++; log.push('upload ' + path.split('/').pop());
      if (fail.upload && fail.upload.test(path)) return { error: { message: 'storage down' } };
      if (store.has(path)) return { error: { message: 'The resource already exists' }, exists: true };
      store.set(path, bytes);
      return { error: null };
    },
    download: async (path) => store.has(path) ? { data: store.get(path), error: null } : { data: null, error: { message: 'not found' } },
    queueRow: async (s) => ({ data: queue.has(s) ? { source_id: s } : null, error: null }),
    buildPdf: async (pages) => new Uint8Array([37, 80, 68, 70, pages.length, t % 251]),
    dispatch: async (r) => {
      calls.dispatch++; calls.last = r; log.push('dispatch');
      if (fail.hold) { const h = fail.hold; delete fail.hold; return await h; }          // a slow reader call, resolved by the test
      if (fail.timeoutButQueued) { queue.add(r.source_id); return { ok: false, status: 504, body: { error: 'gateway timeout' } }; }
      if (fail.already) return { ok: true, status: 200, body: { status: 'already_queued' } };
      if (fail.dispatch) return { ok: false, status: 503, body: {} };
      if (!fail.lose) queue.add(r.source_id);
      return { ok: true, status: 202, body: { status: 'accepted' } };
    },
    now: () => new Date(t),
    sha256: async (d) => createHash('sha256').update(typeof d === 'string' ? d : Buffer.from(d)).digest('hex'),
    uuid: () => randomUUID(),
  };
  return { rows, store, queue, calls, fail, log, deps, advance: (ms) => { t += ms; } };
}
const JPEG = (n) => Buffer.from([0xff, 0xd8, 0xff, 0xe0, n]).toString('base64');
const body = (op, o = {}) => ({ op_id: op, supplier: 'Supplier A', department: 'Grocer', images: [JPEG(1), JPEG(2)], ...o });

test('a send reserves the receipt before storing anything, stores photos + PDF, dispatches once', async () => {
  const w = world(), op = randomUUID();
  const r = await createReceipt(w.deps, body(op));
  assert.equal(r.status, 202); assert.equal(r.body.id, op); assert.equal(r.body.status, 'reading');
  assert.equal(w.log[0], 'insert', 'reservation first');
  assert.deepEqual(w.log.slice(1), ['upload page-1.jpg', 'upload page-2.jpg', 'upload invoice.pdf', 'dispatch']);
  const row = w.rows.get(op);
  assert.equal(row.status, 'reading'); assert.equal(row.photo_paths.length, 2);
  assert.match(row.confirmed_payload.upload.fingerprint, /^[0-9a-f]{64}$/); assert.equal(row.confirmed_payload.upload.dispatch, 'sent');
});

test('re-sending the same op returns the same receipt without storing or dispatching again', async () => {
  const w = world(), op = randomUUID();
  await createReceipt(w.deps, body(op));
  const before = { ...w.calls };
  const r = await createReceipt(w.deps, body(op));
  assert.equal(r.status, 200); assert.equal(r.body.already_received, true); assert.equal(r.body.id, op);
  assert.equal(w.calls.uploads, before.uploads); assert.equal(w.calls.dispatch, before.dispatch);
});

test('the same op with different photos is refused and nothing is touched', async () => {
  const w = world(), op = randomUUID();
  await createReceipt(w.deps, body(op));
  const stored = [...w.store.values()].map((b) => Buffer.from(b).toString('hex'));
  const r = await createReceipt(w.deps, body(op, { images: [JPEG(9)] }));
  assert.equal(r.status, 409);
  assert.deepEqual([...w.store.values()].map((b) => Buffer.from(b).toString('hex')), stored);
});

test('two concurrent sends of the same op: one receipt, photos stored once, one dispatch', async () => {
  const w = world(), op = randomUUID();
  const [a, b] = await Promise.all([createReceipt(w.deps, body(op)), createReceipt(w.deps, body(op))]);
  assert.equal(a.body.id, op); assert.equal(b.body.id, op);
  assert.equal(w.calls.dispatch, 1);
  assert.equal(w.rows.size, 1);
  assert.equal([...w.store.keys()].length, 3);
});

test('a concurrent winner for a different delivery is detected on read-back (409)', async () => {
  const w = world(), op = randomUUID();
  await createReceipt(w.deps, body(op, { supplier: 'Supplier B' }));
  const r = await createReceipt(w.deps, body(op));
  assert.equal(r.status, 409);
});

test('photo upload failure: error reported, receipt resumable, retry finishes without duplicates', async () => {
  const w = world(), op = randomUUID();
  w.fail.upload = /page-2/;
  const r1 = await createReceipt(w.deps, body(op));
  assert.equal(r1.status, 500); assert.equal(w.rows.get(op).status, 'upload_failed'); assert.equal(w.calls.dispatch, 0);
  delete w.fail.upload;
  const r2 = await createReceipt(w.deps, body(op));
  assert.equal(r2.status, 202); assert.equal(w.rows.get(op).status, 'reading'); assert.equal(w.calls.dispatch, 1);
  assert.equal(w.rows.size, 1);
});

test('PDF upload failure is checked (not silently ignored)', async () => {
  const w = world(), op = randomUUID();
  w.fail.upload = /invoice\.pdf/;
  const r = await createReceipt(w.deps, body(op));
  assert.equal(r.status, 500); assert.equal(w.rows.get(op).status, 'upload_failed'); assert.equal(w.calls.dispatch, 0);
});

test('an earlier stored PDF is the one dispatched on resume (never overwritten)', async () => {
  const w = world(), op = randomUUID();
  w.fail.update = true;                                   // photos + PDF stored, then the row update fails
  const r1 = await createReceipt(w.deps, body(op));
  assert.equal(r1.status, 500);
  const pdfPath = [...w.store.keys()].find((k) => k.endsWith('invoice.pdf'));
  const first = Buffer.from(w.store.get(pdfPath)).toString('hex');
  delete w.fail.update; w.advance(7000);
  const r2 = await createReceipt(w.deps, body(op));
  assert.equal(r2.status, 202);
  assert.equal(Buffer.from(w.store.get(pdfPath)).toString('hex'), first);
  assert.equal(Buffer.from(w.calls.last.pdf).toString('hex'), first);
});

test('database errors are reported, not treated as success', async () => {
  const w = world();
  w.fail.get = true;
  assert.equal((await createReceipt(w.deps, body(randomUUID()))).status, 500);
  const w2 = world();
  w2.fail.insert = true;
  assert.equal((await createReceipt(w2.deps, body(randomUUID()))).status, 500);
  assert.equal(w2.calls.uploads, 0, 'nothing stored without a reservation');
});

test('bad input is refused before anything is reserved', async () => {
  const w = world();
  assert.equal((await createReceipt(w.deps, body(randomUUID(), { images: ['not-base64!!'] }))).status, 400);
  assert.equal((await createReceipt(w.deps, body(randomUUID(), { images: [Buffer.from('hello').toString('base64')] }))).status, 400);
  assert.equal((await createReceipt(w.deps, body(randomUUID(), { department: 'Cafe' }))).status, 400);
  assert.equal(w.calls.inserts, 0);
});

test('reader unavailable: receipt marked error with the PDF kept; re-dispatched from storage after a minute', async () => {
  const w = world(), op = randomUUID();
  w.fail.dispatch = true;
  const r = await createReceipt(w.deps, body(op));
  assert.equal(r.status, 502); assert.equal(w.rows.get(op).status, 'error');
  delete w.fail.dispatch;
  let rec = await reconcileReceipt(w.deps, w.rows.get(op));
  assert.equal(rec.status, 'error', 'not before the wait');
  w.advance(61_000);
  rec = await reconcileReceipt(w.deps, w.rows.get(op));
  assert.equal(rec.status, 'reading'); assert.equal(w.calls.dispatch, 2); assert.equal(w.calls.last.source_id, `app:${op}`);
});

test('a lost hand-off (accepted but never queued) is re-dispatched once after 3 minutes, even with parallel checks', async () => {
  const w = world(), op = randomUUID();
  w.fail.lose = true;
  await createReceipt(w.deps, body(op));
  delete w.fail.lose;
  await reconcileReceipt(w.deps, w.rows.get(op));
  assert.equal(w.calls.dispatch, 1, 'not before 3 minutes');
  w.advance(181_000);
  await Promise.all([reconcileReceipt(w.deps, w.rows.get(op)), reconcileReceipt(w.deps, w.rows.get(op))]);
  assert.equal(w.calls.dispatch, 2);
  await reconcileReceipt(w.deps, w.rows.get(op));
  assert.equal(w.calls.dispatch, 2, 'queued now: no more re-dispatch');
});

test('re-dispatch stops after 5 attempts; older receipts without upload details are left alone', async () => {
  const w = world(), op = randomUUID();
  w.fail.dispatch = true;
  await createReceipt(w.deps, body(op));
  for (let i = 0; i < 8; i++) { w.advance(61_000); await reconcileReceipt(w.deps, w.rows.get(op)); }
  assert.equal(w.calls.dispatch, 5);
  const legacy = { id: randomUUID(), source_id: 'app:legacy', supplier: 'Supplier A', department: 'Grocer', status: 'reading', photo_paths: [], confirmed_payload: null };
  w.rows.set(legacy.id, legacy);
  const before = w.calls.dispatch;
  await reconcileReceipt(w.deps, legacy);
  assert.equal(w.calls.dispatch, before);
});

test('a late answer from an older dispatch attempt never overwrites the newer attempt', async () => {
  const w = world(), op = randomUUID();
  let release; w.fail.hold = new Promise((r) => { release = r; });
  const first = createReceipt(w.deps, body(op));                        // attempt A is waiting on a slow reader
  await new Promise((r) => setImmediate(r));
  w.advance(181_000);
  await reconcileReceipt(w.deps, w.rows.get(op));                       // attempt B (no queue row after 3 minutes)
  assert.equal(w.rows.get(op).confirmed_payload.upload.dispatch, 'sent');
  const tokenB = w.rows.get(op).confirmed_payload.upload.dispatch_token;
  release({ ok: false, status: 503, body: {} });                        // A finally fails
  const a = await first;
  assert.equal(w.rows.get(op).status, 'reading', 'B result kept');
  assert.equal(w.rows.get(op).confirmed_payload.upload.dispatch_token, tokenB);
  assert.equal(a.body.id, op); assert.notEqual(a.status, 502);
});

test('a failed outcome write is reported, and nothing is re-sent while the reader has it', async () => {
  const w = world(), op = randomUUID();
  w.fail.updateOnce = true;                                             // the 'uploading' -> 'reading' move fails once
  const r0 = await createReceipt(w.deps, body(op));
  assert.equal(r0.status, 500);
  const r1 = await createReceipt(w.deps, body(op));                     // resume: move ok, dispatch ok
  assert.equal(r1.status, 202);
  const w2 = world(), op2 = randomUUID();
  await createReceipt(w2.deps, body(op2));
  w2.fail.updateOnce = true;
  w2.rows.get(op2).status = 'error'; w2.rows.get(op2).confirmed_payload.upload.dispatch = 'failed';
  w2.queue.clear(); w2.advance(61_000);
  const before = w2.calls.dispatch;
  const r2 = await createReceipt(w2.deps, body(op2));                   // forced re-send; outcome write fails
  assert.equal(r2.status, 500); assert.match(r2.body.error, /couldn't be recorded/);
  assert.equal(w2.calls.dispatch, before + 1);
  await reconcileReceipt(w2.deps, w2.rows.get(op2));                    // reader queued it: no further dispatch
  assert.equal(w2.calls.dispatch, before + 1);
});

test('a timed-out dispatch that the reader actually accepted is not sent again', async () => {
  const w = world(), op = randomUUID();
  w.fail.timeoutButQueued = true;
  const r = await createReceipt(w.deps, body(op));
  assert.equal(r.status, 502); assert.equal(w.rows.get(op).status, 'error');
  delete w.fail.timeoutButQueued; w.advance(61_000);
  const rec = await reconcileReceipt(w.deps, w.rows.get(op));
  assert.equal(rec.status, 'reading'); assert.equal(w.calls.dispatch, 1);
  const again = await createReceipt(w.deps, body(op));                  // staff re-send: still not sent twice
  assert.equal(again.body.id, op); assert.equal(w.calls.dispatch, 1);
});

test("the reader's 'already_queued' answer counts as accepted", async () => {
  const w = world(), op = randomUUID();
  w.fail.already = true;
  const r = await createReceipt(w.deps, body(op));
  assert.equal(r.status, 202); assert.equal(w.rows.get(op).status, 'reading');
});
