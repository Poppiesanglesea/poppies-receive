import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const script = readFileSync(new URL('../index.html', import.meta.url), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
const line = { unmatched_id: 12, status: 'open', description: 'Oatcakes (6)', printed_pack: 6, carton_code: '12345678901234', qty: 2 };
const card = { source_id: 'inv', supplier: 'Supplier A', department: 'Grocer', invoice_number: '100', invoice_date: '2026-11-25', open: 1, lines: [line] };
function setup(action, answer) {
  const elements = new Map(), posts = [];
  let current = structuredClone(card);
  const el = id => {
    if (!elements.has(id)) elements.set(id, { value: '', innerHTML: '', textContent: '' });
    return elements.get(id);
  };
  const ctx = vm.createContext({
    location: { hash: '' }, localStorage: { getItem: () => null }, window: { scrollTo() {} },
    document: { getElementById: el, querySelector: () => ({value:'17'}), addEventListener() {} },
    fetch: async (url, options) => {
      if (!options.body) return {ok:true, status:200, json:async () => ({cards:[current], staff:['Fern'], new_stock_mode:'dry_run'})};
      const body = JSON.parse(options.body);
      posts.push({url,body});
      const [status, result] = await answer(body, posts.length);
      if (result.line) current = {...card, open:0, lines:[result.line]};
      return {ok:status === 200,status,json:async () => result};
    },
    card: structuredClone(card),
  });
  const run = s => vm.runInContext(s, ctx);
  run(script);
  run('RETAIL={cards:[card],staff:["Fern"],new_stock_mode:"dry_run"};retailScreen("inv")');
  run(`openRetail(12,"${action}")`);
  el('retail-by').value = 'Fern'; el('retail-units').value = '6';
  return {run,el,posts};
}
test('waiting invoice links to the correct card and new setup leaves the shelf barcode blank', () => {
  const a = setup('new');
  assert.match(a.run('rdRow({kind:"invoice",id:"inv",depts:[],date:"2026-11-25"})'), /Review waiting lines/);
  assert.doesNotMatch(a.run('rdRow({kind:"invoice",id:"other",depts:[],date:"2026-11-25"})'), /Review waiting lines/);
  assert.match(a.el('app').innerHTML,/Test mode/);
  assert.doesNotMatch(a.el('app').innerHTML,/12345678901234/);
});
test('match preserves the operation ID across confirmations and invalidates a warning when units change', async () => {
  const a = setup('existing', (_body,n) => n < 3 ? [400,{code:'needs_confirm',checks:[{code:'cost_differs',soft:true,message:'Check unit cost'}]}] : [200,{ok:true,line:{...line,status:'done'}}]);
  await a.run('saveRetail()');
  assert.match(a.el('retail-msg').textContent,/Check unit cost/);
  a.el('retail-units').value = '7';
  await a.run('saveRetail()'); await a.run('saveRetail()');
  assert.deepEqual(a.posts.map(p=>p.body.confirm),[[],[],['cost_differs']]);
  assert.equal(new Set(a.posts.map(p=>p.body.op_id)).size,1);
  assert.equal(a.posts[2].body.stock_item_id,17);
  assert.match(a.el('app').innerHTML,/Booked to stock/);
});
test('a double submit sends one operation and an already answered line leaves the form', async () => {
  let finish;
  const a = setup('josh', () => new Promise(resolve => {finish = resolve;}));
  a.el('retail-reason').value = 'Mixed cartons';
  const saving = a.run('saveRetail()');
  await a.run('saveRetail()');
  assert.equal(a.posts.length,1); assert.equal(a.posts[0].body.reason,'Mixed cartons');
  finish([409,{error:'Already answered',line:{...line,status:'with_josh'}}]); await saving;
  assert.match(a.el('app').innerHTML,/With Josh/);
  assert.doesNotMatch(a.el('app').innerHTML,/Send to Josh/);
});
test('grocery without a barcode requires a reason and hard rejections cannot be confirmed', async () => {
  const a = setup('new', () => [400,{code:'barcode_invalid',error:'Invalid barcode'}]);
  a.el('retail-no-code').checked = true;
  await a.run('saveRetail()'); assert.equal(a.posts.length,0);
  a.el('retail-note').value = 'No barcode on individual pots';
  await a.run('saveRetail()');
  assert.equal(a.posts[0].body.no_barcode,true); assert.equal(a.posts[0].body.barcode,'');
  assert.match(a.el('retail-msg').textContent,/Invalid barcode/);
  assert.equal(a.run('retailForm.confirm'),null);
});
