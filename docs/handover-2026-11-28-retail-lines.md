# Retail waiting lines: backend handover, 28 Nov 2026

Public repo: technical outcomes only. Business detail stays in the restricted project record.
Roles: Claude built the backend on `retail-waiting-lines-2026-11-28`. Codex built the frontend in PR #5 and reviews.

## Rev 2, 28 Nov (after Codex review) — head commit in the PR/branch
1. **Deployed vs candidate Edge:**
   - Production `delivery-app` is Supabase version 18, build `delivery-app v17 2026-11-26`. Its embedded hashes equal `main`, which this branch is built on, so production holds no newer Edge code.
   - The barcode lookup is live only in the database: `delivery_line_known` and `delivery_name_close`, applied 27 Nov. Its Edge part is on the unmerged branch `known-barcodes-2026-11-27`, which also calls itself v18. This branch is renamed **`delivery-app v19 2026-11-28 retail-lines`**.
   - The fixed-price writes are database-only (`price_square_put`, `square_set_variation_price`, applied 28 Nov), and this migration doesn't touch them.
   - Preserved and tested (live, rolled back):
     - md5 before and after the migration of the lookup, name-matching, fixed-price, booking and count-job functions;
     - both price writers still set FIXED_PRICING;
     - a priced new product reaches Square as FIXED_PRICING with its price;
     - `delivery_line_known` still returns the matched product and its barcode after an app booking.
   - Composition: a scratch merge of this branch + PR #5 (`c3d12d9`) + known-barcodes passes 117/117 with check-edge ok. The only conflicts were the build/hash lines and README rows. Whichever merges second re-runs `check-edge.mjs --write`.
2. **Read-only browsing / no silent promotion:**
   - `delivery_retail_lines_list` is STABLE, so the database refuses writes from it, and the Edge GET no longer sweeps.
   - Each "new" answer stores `setup_mode`, and the submitted line carries `planned_in_mode`.
   - `new_stock_apply` (patch 0) forces a dry run for any unpromoted test-mode plan, even when it's called live (sweep, retry).
   - Promotion is explicit: `delivery_retail_promote` plus `POST /owner/retail-lines/:id/promote` (owner key). It is refused while set-up is in test mode, and is idempotent per `op_id`.
3. **Uncertain replies:**
   - An RPC error or thrown call returns 503 `uncertain` with wording that does not claim a rollback.
   - Edge tests cover error→retry→replay with the same op and body.
   - DB tests cover same-`op_id` retries for existing, new, josh and promote: no double booking, receipt or log line.
4. **Mixed departments:**
   - Each line has `department`.
   - Each card has `departments[]`, and `department` is null when mixed.
   - None occurred in the last 90 days, but they are supported.

Evidence for rev 2:
- Node: 104/104.
- Live rolled-back run: `retail_lines_pre.sql` + migration + test, 82/82.
- Residue check: clean, and `new_stock_mode` is still `dry_run`.
- Local rollback guard checked again.

## What is staged (nothing applied or deployed)
- `db/migrations/20261128_retail_lines_01.sql`
  - New tables `delivery_retail_answers` and `delivery_retail_ops`.
  - New column `delivery_receipts.origin`.
  - New functions `delivery_retail_*` and `delivery_gtin_*`. They are service-role only and covered by `delivery_app_selfcheck`.
  - Anchored, asserted patches to `new_stock_apply` and `delivery_recent_list`. Backups are in `function_backup`, label `pre-retail-lines-2026-11-28`.
- Rollback: `db/rollback/20261128_retail_lines_01_rollback.sql`.
- Edge build `delivery-app v19 2026-11-28 retail-lines` (was v18 in rev 1):
  - Files: `retail.ts` (new), `index.ts` (routes, plus `/recent` lists photo receipts only), `MANIFEST.json`.
  - `scripts/check-edge.mjs` now covers `retail.ts` (SOURCE_SHA gains `retail`).
- Contract: `docs/retail-lines-contract.md`, draft 2. Every change since draft 1 adds a field or code, so PR #5 needs no change.

## Evidence
- `node --experimental-strip-types --test test/*.test.mjs`:
  - 99/99 on this branch.
  - 103/103 with PR #5 (ae3c1ec) merged into a scratch branch, with no merge conflicts.
  - `check-edge.mjs` ok.
  - `test/retail-lines-edge.test.mjs` sends PR #5's exact payload shapes. These are integer `units`, `barcode: ""` with `no_barcode`, empty `name` and `note`, and the `confirm` codes. It checks that:
    - search returns an array;
    - 200 and 409 replies carry `line.unmatched_id`;
    - `needs_confirm` checks carry `soft: true`.
- Rolled-back integration test on the live database: `db/tests/retail_lines_rollback_test.sql`, 64/64 (rev 1; rev 2 82/82, see above).
  - Ran as one query appended to the migration. The last statement raises, so everything rolled back.
  - Square was stubbed inside the transaction.
  - Fixtures are synthetic. The live waiting lines were present too, for the list timing (under 3 s).
  - What it covered:
    - eligibility: other supplier, archived, café, department;
    - the three soft checks on a carton booked as 1;
    - partial confirm;
    - nothing written on `needs_confirm`;
    - booking for the line and its sibling;
    - replay, `op_conflict` and `already_answered`;
    - a failed booking fully undone;
    - every barcode check;
    - the receipt hand-off;
    - set-up with a reader that guessed the wrong pack and a carton GTIN. Staff units and cost win, and the carton code never reaches Square;
    - a "known" decision for a staff "new" line goes to Josh;
    - the photo flow unchanged;
    - dry-run requeue once live;
    - selfcheck.
- Residue check after the run: clean. See `db/tests/retail_lines_residue_check.sql`. No tables, columns, functions, backups, fixtures or stubs remained, and `new_stock_mode` was unchanged.
- First live attempt timed out in the list: per-item eligibility plus a per-line produce-supplier lookup. The candidate search was rewritten as one set-based pass (token pre-filter, then the exact name test), and the supplier set is computed once per call.

## Rollout order (each step needs Josh's yes)
1. Codex reviews this branch and PR #5.
2. Apply `retail_lines_01`. Then run `select delivery_app_selfcheck();`.
3. Deploy Edge v18 from `MANIFEST.json`. Then fetch `/health` and run `node scripts/check-edge.mjs --live '<json>'`.
   - The migration must come first: `/recent` filters on `origin`.
4. Merge PR #5 (GitHub Pages).
5. Do a browser smoke check on the iPad.
   - First real use: one "existing" match on a real waiting line. That books real stock, so it needs Josh's yes.
6. `new_stock_mode` is `dry_run`. "New" lines plan the product but create nothing in Square until Josh switches it to `live`. Plans made in test mode then wait for Josh's per-line approval (owner route); nothing is promoted automatically.

## Known limits / open
- Concurrency relies on a row lock on the waiting line, plus a primary key on answers and ops. It was not exercised with two live sessions, because there is no dblink on production.
- Lines staff send to Josh ("josh" action) have no owner screen yet. Set-up questions still show in Josh's existing products-waiting list.
- Eligibility keeps the produce rule: a product supplied only by a different supplier can't be matched. When a product legitimately comes through two distributors, staff will find nothing and should send the line to Josh.
- Other open branches touch the same files: `known-barcodes-2026-11-27` (index.ts, MANIFEST) and `price-write-fixed-pricing-2026-11-28` (db/README, base.sql). Rebase whichever merges second, and re-run `check-edge.mjs --write`.
