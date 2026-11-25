import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const script = readFileSync(new URL('../index.html', import.meta.url), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
for (const status of ['dry_run', 'empty', 'failed', 'needs_josh', 'pending', 'ready']) {
  test('delivery detail shows appropriate label instructions for ' + status, async () => {
    const root = {};
    const app = vm.createContext({
      location: { hash: '' }, window: { scrollTo() {} },
      document: { getElementById: () => root, addEventListener() {} },
      fetch: async () => ({ ok: true, status: 200, json: async () => ({ setup_status: status, lines: [] }) })
    });
    vm.runInContext(script, app);
    await vm.runInContext("itemsScreen('test-receipt')", app);
    assert.equal(root.innerHTML.includes('Print labels'), status === 'ready');
  });
}