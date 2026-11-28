# Database changes for the staff app

| File | Status |
|---|---|
| `migrations/20261126_provenance_01_function_backup.sql` | Applied 26 Nov 2026 |
| `migrations/20261126_provenance_02_schema.sql` (rev 2) | **Staged, not applied** — validated locally. Original approval declined (Codex handover, 26 Nov) |
| `rollback/20261126_provenance_02_schema_rollback.sql` | Validated locally (refuses if tables used / exceptions reviewed) |
| `migrations/20261126_pricing_03_tag_confirm.sql` (rev 2) | **Applied 26 Nov 2026** (~22:31 Melbourne, via Supabase apply_migration; post-apply `delivery_app_selfcheck` ok, all 16 function bodies matched e0e8301 — Codex handover record) |
| `rollback/20261126_pricing_03_tag_confirm_rollback.sql` | Validated locally (refuses while a register update is in flight or in doubt; keeps audit + operation evidence). **Order:** refuses while pricing_repair_01 is applied (run its rollback first) or while `produce_price_items` carries the 28 Nov markup decision |
| `migrations/20261128_produce_markup_no_decision.sql` | **Applied 28 Nov 2026** directly in production (Josh: produce prices that needed his decision now just take the markup, produce only; the >max-% owner hold no longer applies to produce). Recorded afterwards; keeps the previous version as `produce_price_items_bak_20261128`. Do not re-run: a second run overwrites that backup with the new version |
| `migrations/20261128_pricing_repair_01.sql` | **Staged, not applied** — its guard expects the markup version of `produce_price_items` above. Tests: `tests/run_pricing_repair_local.sh` |
| `rollback/20261128_pricing_repair_01_rollback.sql` | Validated locally (refuses unless every replaced object still carries the repair marker) |
| `migrations/20261128_retail_lines_01.sql` | **Staged, not applied** — retail waiting-line jobs (contract: docs/retail-lines-contract.md). Rev 2. Tested rolled back on live data 28 Nov 2026: `tests/retail_lines_pre.sql` + migration + `tests/retail_lines_rollback_test.sql` 82/82, residue check clean (`tests/retail_lines_residue_check.sql`) |
| `rollback/20261128_retail_lines_01_rollback.sql` | Validated locally (refuses while a set-up is in flight or if the patched functions changed since; archives answer tables) |
| `tests/run_local.sh` | Reproducible local run of everything below (disposable PostgreSQL 16+ with dblink) |

Statuses updated 28 Nov 2026 from the Codex handover records and the markup branch, not re-read from the live database.
Confirm with `select delivery_app_selfcheck();` and `select distinct label from function_backup;` before relying on them.

Applied directly (narrowing / read-only, before or alongside this folder): app RPC privilege narrowing,
`delivery_app_selfcheck()` (now also flags SECURITY DEFINER pricing functions callable by anon/authenticated and lists
invoker pricing functions still callable by them), `produce_price_items` narrowed to service_role.

## Local validation (reproducible)
`PGHOST=/tmp PGPORT=54329 PGUSER=postgres db/tests/run_local.sh` builds fresh databases from `tests/local/base.sql`
(production table structure, no data; production helpers that the tests exercise are copied verbatim — including the
caller chain `produce_price_for_invoice` -> `produce_price_items` -> `delivery_tasks_add`; unrelated helpers and the
pricing-maths view are explicit fixtures), applies 01 / 02 / 03 as single transactions and runs:
- `tests/provenance_02_checks.sql` + 02 rollback guard / clean rollback / re-apply;
- `tests/pricing_03_selftest.sql` against a Square stand-in in a SEPARATE database reached through dblink
  (`tests/local/square_mock_store.sql`), so a "Square" write survives a rollback here exactly like a real call; the
  stand-in enforces versions and idempotency keys. The real Square call (`square_api`) raises if reached;
- `tests/pricing_03_concurrency.sh`: three sessions (slow confirm holding the item lock, newer invoice touching two items
  in reverse order, confirm on the other item): no deadlock, one write, correct supersede order;
- 03 rollback guard and evidence-preserving rollback (`tests/pricing_03_rollback_checks.sql`).
Last run (26 Nov 2026, rev 2c): provenance_02 8/8 + 4 rollback checks; pricing_03 84/84; concurrency 6/6; 03 rollback 2 + 9/9.
Rev 2c: when Josh leaves a register price as it is after staff already confirmed the group, the job asks staff to put
those physical tags back to the register price ('restore'), then closes; rollback refuses while such a step is open.
Rev 2b (after review of 49f251a): unknown-price halves can close as skipped/superseded without inventing a price
(owner skip, newer price, Keep, rollback all tested); every job reads only its CURRENT proposal's operations when a
delivery card is reused by a newer revision (tested); owner resolution is wired end to end — Edge
`POST /owner/price-ops/:id/resolve` and a "Register prices to check" section on Josh's screen (active once 03 is applied).

## Pending approvals (each needs a specific yes; the Supabase prompt shows potentially destructive SQL)
1. `provenance_02_schema` (rev 2): adds 4 derived key columns to processed_invoices and fills them; new trigger;
   new tables invoice_identity_exception (seeded with existing collision groups — count in the restricted record),
   invoice_line_stock, ingest_unmatched_line. No deletes; no changes to stock, lines, prices, Square or email.
2. `pricing_03_tag_confirm` (rev 2): owner-approved pricing workflow. Adds columns/status values and two evidence tables
   (price_apply_op, price_apply_audit), backs up 6 functions, marks every existing tag job `tag_only`, replaces the 4
   price-writing paths so they create authorised proposals + tag jobs. Applying it changes no prices; afterwards the
   register changes only on staff confirmation (or owner flow -> staff confirmation). Live effect: the 5-minute
   produce sweep and nightly rules stop writing Square directly. Deploy order: Edge build with the two-call confirm
   (claim, then apply; falls back to the old single call before 03 exists) first, then 03.

## Not yet written (next packet)
Line-aware booking (`ingest_invoice_line_for`), ingest_invoice reservation/lock + identity policy, resolver wrapper,
exceptions view, rollback-only provenance tests; receipt dispatch reconciliation and mocked Edge receipt tests.
