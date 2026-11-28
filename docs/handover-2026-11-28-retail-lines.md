# Retail waiting lines: backend handover, 28 Nov 2026

Public repo: technical outcomes only. Business detail stays in the restricted project record.
Roles: Claude built the backend on `retail-waiting-lines-2026-11-28`. Codex built the frontend in PR #5 and reviews.

## What is staged (nothing applied or deployed)
- `db/migrations/20261128_retail_lines_01.sql`
  - New tables `delivery_retail_answers` and `delivery_retail_ops`.
  - New column `delivery_receipts.origin`.
  - New functions `delivery_retail_*` and `delivery_gtin_*`. They are service-role only and covered by `delivery_app_selfcheck`.
  - Anchored, asserted patches to `new_stock_apply` and `delivery_recent_list`. Backups are in `function_backup`, label `pre-retail-lines-2026-11-28`.
- Rollback: `db/rollback/20261128_retail_lines_01_rollback.sql`.
- Edge build `delivery-app v18 2026-11-28`:
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
- Rolled-back integration test on the live database: `db/tests/retail_lines_rollback_test.sql`, 64/64.
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
6. `new_stock_mode` is `dry_run`. "New" lines plan the product but create nothing in Square until Josh switches it to `live`. Planned lines are requeued automatically on the next list call after that.

## Known limits / open
- Concurrency relies on a row lock on the waiting line, plus a primary key on answers and ops. It was not exercised with two live sessions, because there is no dblink on production.
- Lines staff send to Josh ("josh" action) have no owner screen yet. Set-up questions still show in Josh's existing products-waiting list.
- Eligibility keeps the produce rule: a product supplied only by a different supplier can't be matched. When a product legitimately comes through two distributors, staff will find nothing and should send the line to Josh.
- Other open branches touch the same files: `known-barcodes-2026-11-27` (index.ts, MANIFEST) and `price-write-fixed-pricing-2026-11-28` (db/README, base.sql). Rebase whichever merges second, and re-run `check-edge.mjs --write`.
