import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const page = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const script = page.match(/<script>([\s\S]*?)<\/script>/)[1];

function receipt(lines, networkFailure = false, alreadySent = false) {
  const elements = new Map();
  const requests = [];
  const element = id => {
    if (!elements.has(id)) elements.set(id, { value: '', innerHTML: '', disabled: false });
    return elements.get(id);
  };
  const app = vm.createContext({
    location: { hash: '' },
    localStorage: { getItem: () => null },
    document: { getElementById: element, addEventListener() {} },
    window: { scrollTo() {} },
    fixture: structuredClone(lines),
    fetch: async (url, options) => {
      requests.push({ url, body: options?.body ? JSON.parse(options.body) : null });
      if (networkFailure) throw new TypeError('Network unavailable');
      if (alreadySent && options.method === 'POST') return { ok: false, status: 409, json: async () => ({}) };
      return { ok: true, status: 200, json: async () => ({ status: 'submitted' }) };
    }
  });
  vm.runInContext(script, app);
  vm.runInContext("REC = { id: 'test-receipt' }; LINES = fixture;", app);
  return { submit: () => vm.runInContext('submitLines()', app), requests, element };
}

const product = { description: 'Sample product', qty: 3, source: 'invoice' };

test('a complete line submits once with its count', async () => {
  const app = receipt([product]);
  await app.submit();
  assert.equal(app.requests.length, 1);
  assert.deepEqual(app.requests[0].body.lines, [product]);
});

test('a second partially entered product is never silently discarded', async () => {
  const app = receipt([product, { description: ' ', qty: 2, barcode: '012345678905' }]);
  await app.submit();
  assert.equal(app.requests.length, 0);
});

test('a negative arrival count is rejected before submission', async () => {
  const app = receipt([{ ...product, qty: -1 }]);
  await app.submit();
  assert.equal(app.requests.length, 0);
});

test('connection loss leaves the form available for retry', async () => {
  const app = receipt([product], true);
  await app.submit();
  assert.equal(app.requests.length, 1);
  assert.equal(app.element('go').disabled, false);
});

test('a retry checks the same receipt when the server reports a conflict', async () => {
  const app = receipt([product], false, true);
  await app.submit();
  assert.equal(app.requests.length, 2);
  assert.equal(app.requests[0].url, app.requests[1].url + '/submit');
  assert.equal(app.requests[1].body, null);
  assert.match(app.element('app').innerHTML, /already sent/i);
});
