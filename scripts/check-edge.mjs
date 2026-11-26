#!/usr/bin/env node
// Deploy guard for the delivery-app Edge function (26 Nov 2026).
//   node scripts/check-edge.mjs            -> validate source, embedded SOURCE_SHA and MANIFEST.json (exit 1 on failure)
//   node scripts/check-edge.mjs --write    -> after a deliberate source change: embed SOURCE_SHA and rewrite MANIFEST.json
//   node scripts/check-edge.mjs --live '<json body of GET /health>'  -> compare the deployed build with this source
// Deploy exactly the files in MANIFEST.json from this repo, then run --live. A placeholder, partial or stale deploy
// fails. (The runtime cannot read its own bundled source, so /health reports the hashes embedded at build time;
// for a byte-for-byte check also compare the deployed files, e.g. Supabase get_edge_function, with this repo.)
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const dir = new URL('../supabase/functions/delivery-app/', import.meta.url);
const FILES = ['index.ts', 'auth.ts', 'receipts.ts'];
const REQUIRED = {
  'index.ts': ['Deno.serve(', 'from "./auth.ts"', 'export const BUILD = "', 'export const SOURCE_SHA = {', '"/health"', '"/deliveries"',
               '"/recent-deliveries"', '"/prices/all"', '"/recent"', '"/suppliers"', '"/receipts"', 'op_id', 'ConfigUnavailable', 'whoFromHeaders', 'from "./receipts.ts"', 'delivery_tag_claim', 'delivery_tag_apply', 'price_op_resolve'],
  'auth.ts': ['export class ConfigUnavailable', 'export function makeCfg', 'export async function whoFromHeaders'],
  'receipts.ts': ['export async function createReceipt', 'export async function reconcileReceipt', 'status: "uploading"', 'upload_failed'],
};
const MIN_BYTES = { 'index.ts': 15000, 'auth.ts': 1500, 'receipts.ts': 5000 };
const SHA_LINE = /^export const SOURCE_SHA = \{[^\n]*\};\n/m;
const sha = (t) => createHash('sha256').update(t).digest('hex');
const path = (f) => fileURLToPath(new URL(f, dir));
const read = (f) => readFileSync(path(f), 'utf8');
const args = process.argv.slice(2);
const errors = [];

const shaIndex = (text) => sha(text.replace(SHA_LINE, ''));
if (args[0] === '--write') {
  let idx = read('index.ts');
  if (!SHA_LINE.test(idx)) { console.error('index.ts has no SOURCE_SHA line'); process.exit(1); }
  const want = { index: shaIndex(idx), auth: sha(read('auth.ts')), receipts: sha(read('receipts.ts')) };
  idx = idx.replace(SHA_LINE, `export const SOURCE_SHA = { index: "${want.index}", auth: "${want.auth}", receipts: "${want.receipts}" };\n`);
  writeFileSync(path('index.ts'), idx);
}

const texts = {};
for (const f of FILES) {
  try { texts[f] = read(f); } catch { errors.push(`${f}: missing`); continue; }
  if (Buffer.byteLength(texts[f]) < MIN_BYTES[f]) errors.push(`${f}: only ${Buffer.byteLength(texts[f])} bytes (placeholder?)`);
  for (const needle of REQUIRED[f]) if (!texts[f].includes(needle)) errors.push(`${f}: missing ${needle}`);
}
const build = ((texts['index.ts'] || '').match(/export const BUILD = "([^"]+)"/) || [])[1];
const actual = { index: shaIndex(texts['index.ts'] || ''), auth: sha(texts['auth.ts'] || ''), receipts: sha(texts['receipts.ts'] || '') };
const m = (texts['index.ts'] || '').match(/export const SOURCE_SHA = \{ index: "([0-9a-f]*)", auth: "([0-9a-f]*)", receipts: "([0-9a-f]*)" \};/);
const embedded = m ? { index: m[1], auth: m[2], receipts: m[3] } : null;
if (!embedded || embedded.index !== actual.index || embedded.auth !== actual.auth || embedded.receipts !== actual.receipts) errors.push('embedded SOURCE_SHA is stale (run --write after a deliberate change)');
const fileSha = Object.fromEntries(FILES.map((f) => [f, sha(texts[f] || '')]));

const manifestPath = path('MANIFEST.json');
if (args[0] === '--write' && !errors.length) writeFileSync(manifestPath, JSON.stringify({ build, source_sha: actual, file_sha256: fileSha }, null, 2) + '\n');
let manifest = null;
try { manifest = JSON.parse(readFileSync(manifestPath, 'utf8')); } catch { errors.push('MANIFEST.json missing or invalid'); }
if (manifest) {
  if (manifest.build !== build) errors.push(`MANIFEST build ${manifest.build} != source ${build}`);
  for (const f of FILES) if (manifest.file_sha256?.[f] !== fileSha[f]) errors.push(`MANIFEST hash for ${f} is stale`);
}
if (args[0] === '--live') {
  let live;
  try { live = JSON.parse(args[1]); } catch { errors.push('--live needs the JSON body of GET /health'); }
  if (live) {
    if (live.build !== build) errors.push(`live build "${live.build}" != source "${build}"`);
    if (live.source_sha?.index !== actual.index || live.source_sha?.auth !== actual.auth || live.source_sha?.receipts !== actual.receipts) errors.push('live SOURCE_SHA does not match this source');
  }
}
console.log(JSON.stringify({ build, source_sha: actual, file_sha256: fileSha, ok: !errors.length, errors }, null, 2));
process.exit(errors.length ? 1 : 0);
