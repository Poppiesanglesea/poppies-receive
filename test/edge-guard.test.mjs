// The committed Edge source must pass the deploy guard (no placeholder, manifest current).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../scripts/check-edge.mjs', import.meta.url));
test('edge source passes structural checks and matches MANIFEST.json', () => {
  const out = JSON.parse(execFileSync(process.execPath, [script], { encoding: 'utf8' }));
  assert.equal(out.ok, true, out.errors.join('; '));
});
test('a live /health that does not match the source is rejected', () => {
  let failed = false;
  try { execFileSync(process.execPath, [script, '--live', JSON.stringify({ build: 'placeholder', source_sha: {} })], { encoding: 'utf8' }); }
  catch (e) { failed = e.status === 1; }
  assert.equal(failed, true);
});
