// Retail waiting lines: Edge routing/validation (retail.ts) with a stubbed rpc. Payload shapes follow PR #5's UI.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { retailOwnerRoute, retailRoute } from '../supabase/functions/delivery-app/retail.ts';

const OP = '6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b';
const staff = async () => ['Fern', 'Rach'];
function rpcStub(reply) {
  const calls = [];
  const rpc = async (fn, args) => { calls.push({ fn, args }); return typeof reply === 'function' ? reply(fn, args) : reply; };
  return { rpc, calls };
}
const go = (rpc, method, path, body, owner = false) =>
  retailRoute(rpc, method, path.split('?')[0], new URL('https://x/delivery-app' + path), async () => body, staff, owner);

test('non-retail paths are not handled', async () => {
  const { rpc } = rpcStub({ data: null, error: null });
  assert.equal(await go(rpc, 'GET', '/deliveries'), null);
  assert.equal(await go(rpc, 'GET', '/retail-lines/abc/search'), null);
});

test('list returns owner, staff, mode and cards', async () => {
  const { rpc, calls } = rpcStub({ data: { new_stock_mode: 'dry_run', cards: [{ source_id: 's', lines: [] }] }, error: null });
  const out = await go(rpc, 'GET', '/retail-lines', null, true);
  assert.equal(out.status, 200);
  assert.deepEqual(out.body, { owner: true, staff: ['Fern', 'Rach'], new_stock_mode: 'dry_run', cards: [{ source_id: 's', lines: [] }] });
  assert.equal(calls[0].fn, 'delivery_retail_lines_list');
});

test('list error is a 500, never an empty success', async () => {
  const { rpc } = rpcStub({ data: null, error: { message: 'boom' } });
  assert.equal((await go(rpc, 'GET', '/retail-lines')).status, 500);
});

test('search returns an array; a non-retail line is 404', async () => {
  let { rpc } = rpcStub({ data: [{ stock_item_id: 1, name: 'A' }], error: null });
  const ok = await go(rpc, 'GET', '/retail-lines/12/search?q=ab');
  assert.equal(ok.status, 200);
  assert.ok(Array.isArray(ok.body));
  ({ rpc } = rpcStub({ data: null, error: null }));
  const nf = await go(rpc, 'GET', '/retail-lines/12/search?q=ab');
  assert.equal(nf.status, 404);
  assert.equal(nf.body.code, 'not_found');
});

test('POST needs a uuid op_id and a staff name before reaching the database', async () => {
  const { rpc, calls } = rpcStub({ data: null, error: null });
  assert.equal((await go(rpc, 'POST', '/retail-lines/12/josh', { by: 'Fern', reason: 'x' })).body.code, 'invalid');
  assert.equal((await go(rpc, 'POST', '/retail-lines/12/josh', { op_id: 'nope', by: 'Fern', reason: 'x' })).body.code, 'invalid');
  assert.equal((await go(rpc, 'POST', '/retail-lines/12/josh', { op_id: OP, by: 'Nobody', reason: 'x' })).body.error, 'Pick your name first.');
  assert.equal((await go(rpc, 'POST', '/retail-lines/12/josh', [1])).status, 400);
  assert.equal(calls.length, 0);
});

test('PR #5 payloads are passed through unchanged with the op_id and name split out', async () => {
  const line = { unmatched_id: 12, status: 'setting_up' };
  const { rpc, calls } = rpcStub({ data: { http: 200, body: { ok: true, status: 'setting_up', receipt_id: OP, line } }, error: null });
  const body = { op_id: OP, by: 'Fern', units: 12, no_barcode: false, barcode: '9300000000008', name: '', note: '', confirm: [] };
  const out = await go(rpc, 'POST', '/retail-lines/12/new', body);
  assert.equal(out.status, 200);
  assert.equal(out.body.line.unmatched_id, 12);
  assert.deepEqual(calls[0], { fn: 'delivery_retail_answer', args: { p_unmatched_id: 12, p_action: 'new', p_body: body, p_op_id: OP, p_by: 'Fern' } });
});

test('database http codes are kept: needs_confirm 400 with soft checks, 409 with line', async () => {
  let { rpc } = rpcStub({ data: { http: 400, body: { ok: false, code: 'needs_confirm', checks: [{ code: 'printed_pack_differs', soft: true, message: 'm' }] } }, error: null });
  const nc = await go(rpc, 'POST', '/retail-lines/12/existing', { op_id: OP, by: 'Rach', stock_item_id: 5, units: 1, confirm: [] });
  assert.equal(nc.status, 400);
  assert.equal(nc.body.checks[0].soft, true);
  ({ rpc } = rpcStub({ data: { http: 409, body: { ok: false, code: 'already_answered', line: { unmatched_id: 12, status: 'done' } } }, error: null }));
  const c = await go(rpc, 'POST', '/retail-lines/12/existing', { op_id: OP, by: 'Rach', stock_item_id: 5, units: 6, confirm: [] });
  assert.equal(c.status, 409);
  assert.equal(c.body.line.unmatched_id, 12);
});

test('a database error reply is reported as uncertain (503), never as "nothing was changed"', async () => {
  const { rpc } = rpcStub({ data: null, error: { message: 'upstream connect error' } });
  const out = await go(rpc, 'POST', '/retail-lines/12/josh', { op_id: OP, by: 'Fern', reason: 'x' });
  assert.equal(out.status, 503);
  assert.equal(out.body.code, 'uncertain');
  assert.equal(out.body.retry, true);
  assert.doesNotMatch(out.body.error, /nothing was changed/i);
  assert.match(out.body.error, /won't be saved twice/);
});

test('a thrown call (lost connection) is also uncertain, not a crash', async () => {
  const rpc = async () => { throw new TypeError('fetch failed'); };
  const out = await go(rpc, 'POST', '/retail-lines/12/existing', { op_id: OP, by: 'Fern', stock_item_id: 5, units: 6, confirm: [] });
  assert.equal(out.status, 503);
  assert.equal(out.body.code, 'uncertain');
});

test('retry after an uncertain reply: the same op_id and body are re-sent and the stored result is replayed', async () => {
  let n = 0;
  const line = { unmatched_id: 12, status: 'done' };
  const { rpc, calls } = rpcStub(() => (++n === 1
    ? { data: null, error: { message: 'timeout' } }                       // committed, but the reply was lost
    : { data: { http: 200, body: { ok: true, status: 'done', replayed: true, line } }, error: null }));
  const body = { op_id: OP, by: 'Fern', stock_item_id: 5, units: 6, confirm: [] };
  const first = await go(rpc, 'POST', '/retail-lines/12/existing', body);
  assert.equal(first.status, 503);
  const second = await go(rpc, 'POST', '/retail-lines/12/existing', body);
  assert.equal(second.status, 200);
  assert.equal(second.body.replayed, true);
  assert.equal(second.body.line.unmatched_id, 12);
  assert.deepEqual(calls[0].args, calls[1].args);
  assert.equal(calls[1].args.p_op_id, OP);
});

test('browsing is read-only: the list makes exactly one read call', async () => {
  const { rpc, calls } = rpcStub({ data: { new_stock_mode: 'live', cards: [] }, error: null });
  await go(rpc, 'GET', '/retail-lines');
  await go(rpc, 'GET', '/retail-lines/12/search?q=ab');
  assert.deepEqual(calls.map(c => c.fn), ['delivery_retail_lines_list', 'delivery_retail_search']);
});

test('lines carry their own department (mixed invoices)', async () => {
  const cards = [{ source_id: 's', department: null, departments: ['Garden', 'Grocer'],
    lines: [{ unmatched_id: 1, department: 'Grocer' }, { unmatched_id: 2, department: 'Garden' }] }];
  const { rpc } = rpcStub({ data: { new_stock_mode: 'dry_run', cards }, error: null });
  const out = await go(rpc, 'GET', '/retail-lines');
  assert.deepEqual(out.body.cards[0].lines.map(l => l.department), ['Grocer', 'Garden']);
  assert.equal(out.body.cards[0].department, null);
});

test('owner promote: needs op_id, maps database replies, uncertain on error', async () => {
  const ownerGo = (rpc, method, path, body) => retailOwnerRoute(rpc, method, path, async () => body);
  let { rpc, calls } = rpcStub({ data: { http: 409, body: { ok: false, code: 'setup_test_mode', line: { unmatched_id: 7 } } }, error: null });
  assert.equal(await ownerGo(rpc, 'POST', '/owner/tasks/7/decide', {}), null);
  assert.equal((await ownerGo(rpc, 'POST', '/owner/retail-lines/7/promote', {})).body.code, 'invalid');
  assert.equal((await ownerGo(rpc, 'GET', '/owner/retail-lines/7/promote', {})).status, 405);
  const r = await ownerGo(rpc, 'POST', '/owner/retail-lines/7/promote', { op_id: OP });
  assert.equal(r.status, 409);
  assert.equal(r.body.code, 'setup_test_mode');
  assert.deepEqual(calls.at(-1), { fn: 'delivery_retail_promote', args: { p_unmatched_id: 7, p_op_id: OP, p_by: 'Josh' } });
  ({ rpc } = rpcStub({ data: null, error: { message: 'x' } }));
  const u = await ownerGo(rpc, 'POST', '/owner/retail-lines/7/promote', { op_id: OP });
  assert.equal(u.status, 503);
  assert.equal(u.body.code, 'uncertain');
});

test('unexpected http from the database becomes 500', async () => {
  const { rpc } = rpcStub({ data: { http: 302, body: {} }, error: null });
  assert.equal((await go(rpc, 'POST', '/retail-lines/12/josh', { op_id: OP, by: 'Fern', reason: 'x' })).status, 500);
});

test('wrong methods are 405', async () => {
  const { rpc } = rpcStub({ data: null, error: null });
  assert.equal((await go(rpc, 'POST', '/retail-lines', {})).status, 405);
  assert.equal((await go(rpc, 'GET', '/retail-lines/12/new')).status, 405);
});
