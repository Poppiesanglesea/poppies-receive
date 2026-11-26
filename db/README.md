# Database changes for the staff app

| File | Status |
|---|---|
| `migrations/20261126_provenance_01_function_backup.sql` | Applied 26 Nov 2026 |
| `migrations/20261126_provenance_02_schema.sql` (rev 2) | **Staged, not applied** — validated locally |
| `rollback/20261126_provenance_02_schema_rollback.sql` | Validated locally (refuses if tables used / exceptions reviewed) |
| `migrations/20261126_pricing_03_tag_confirm.sql` | **Staged, not applied** — validated locally |
| `rollback/20261126_pricing_03_tag_confirm_rollback.sql` | Validated locally (refuses while a register update is in flight) |
| `tests/pricing_03_selftest.sql` | 32 checks, all pass locally (Square mocked; real Square call stubbed to raise) |

Applied directly (narrowing / read-only, before or alongside this folder): app RPC privilege narrowing,
`delivery_app_selfcheck()` (now also flags SECURITY DEFINER pricing functions callable by anon/authenticated and lists
invoker pricing functions still callable by them), `produce_price_items` narrowed to service_role.

## Local validation method
Disposable PostgreSQL 16 on the build machine. Structure of every table these files touch was rebuilt from the
production catalogue (columns, defaults, constraints, indexes) with synthetic rows only; helper functions and the
pricing-maths view are stubs; `square_api` and the legacy `square_set_variation_price` raise if called. The production
`delivery_tasks_list` text was used so 03's text patch is checked against the real body. Commands:
`psql -f migrations/…02… ; psql -f rollback/…02…` (guard + clean rollback + re-apply), `psql -f migrations/…03… ;
psql -f tests/pricing_03_selftest.sql ; psql -f rollback/…03…`.

## Pending approvals (each needs a specific yes; the Supabase prompt shows potentially destructive SQL)
1. `provenance_02_schema` (rev 2): adds 4 derived key columns to processed_invoices and fills them; new trigger;
   new tables invoice_identity_exception (seeded with existing collision groups — count in the restricted record),
   invoice_line_stock, ingest_unmatched_line. No deletes; no changes to stock, lines, prices, Square or email.
2. `pricing_03_tag_confirm`: owner-approved pricing workflow. Adds columns/status values, backs up 6 functions,
   marks every existing tag job `tag_only`, replaces the 4 price-writing paths so they create authorised proposals +
   tag jobs, adds the staff confirm function. Applying it changes no prices; afterwards the register changes only on
   staff confirmation (or owner flow -> staff confirmation). Live effect: the 5-minute produce sweep and nightly
   rules stop writing Square directly.

## Not yet written (next packet)
Line-aware booking (`ingest_invoice_line_for`), ingest_invoice reservation/lock + identity policy, resolver wrapper,
exceptions view, rollback-only provenance tests; receipt dispatch reconciliation and mocked Edge receipt tests.
