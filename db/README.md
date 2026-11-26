# Database changes for the staff app

| File | Status |
|---|---|
| `migrations/20261126_provenance_01_function_backup.sql` | Applied 26 Nov 2026 |
| `migrations/20261126_provenance_02_schema.sql` | **Staged for review, not applied** |
| `rollback/20261126_provenance_02_schema_rollback.sql` | Rollback for 02 |

Each staged migration lists its exact intended mutations in its header. After applying any app migration run
`select delivery_app_selfcheck();`. Earlier 26 Nov migrations (shelf prices, recent deliveries, booked-flag repair,
privilege narrowing, self-check) were applied directly in Supabase before this folder existed; their names are in the
restricted handover.

Planned next steps (not yet written as files): line-aware booking function `ingest_invoice_line_for` (legacy
`ingest_invoice_line` unchanged), resolver wrapper booking each associated line, ingest_invoice locking and
line association, exceptions view, rollback-only synthetic tests.
