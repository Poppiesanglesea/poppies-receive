# Retail waiting lines — API contract (draft 1, 28 Nov 2026)

Owner of backend: Claude (branch `retail-waiting-lines-2026-11-28`). Frontend: Codex (separate branch).
Status: **contract draft, staged; nothing deployed or applied.** Changes to this file are announced in the handover.

## What it covers
An emailed invoice for Grocer, Gift Store or Garden is booked line by line. A line the system cannot match to a
product stays **waiting** (an open `ingest_unmatched` row): it has a price but no stock booked. Until now only
Harvey's/Biodynamic Grocer lines had a staff job (`/deliveries`, kind `count`). This adds a job for every other
retail waiting line. Staff choose one of three actions per line:

1. **existing**: "It's something we already sell" -> pick the product, say how many sellable units came in ONE invoice
   unit (carton/box/pack as invoiced). Books the stock now and saves the mapping for future invoices.
2. **new**: "It's a new product" -> say how many sellable units came in one invoice unit and scan the barcode on ONE
   sellable item. Product set-up runs in the background (Square item + mapping), then the line is booked.
3. **josh**: "Not sure / tell Josh" -> a short reason; the line goes to Josh.

Lines that already have a produce `count` job (Harvey's/Biodynamic) are excluded here and stay on `/deliveries`.

## Common rules
- Auth as today: device key; owner key also works. Owner-only fields are marked.
- `by` must be one of `staff` (from `GET /retail-lines`), same check as `/tasks/:id/tick`.
- **`op_id`** (uuid) is required on every POST. Generate it once per staff action (when the action's sheet opens) and
  reuse it for every retry of that action, including the re-send after `needs_confirm`.
  - Only a **successful** result is recorded against the `op_id`. Validation failures and `needs_confirm` are not
    recorded, so the same `op_id` can be re-sent with changed input (e.g. adding `confirm`).
  - Same `op_id` + same payload after success -> the stored response again, with `replayed: true` (HTTP 200).
  - Same `op_id` + different payload after success -> 409 `op_conflict`.
  - A different `op_id` on a line that is no longer `open` -> 409 `already_answered` with the current `line`.
  - Concurrent requests for one line are serialised in the database (row lock); exactly one can succeed.
- `confirm`: array of soft-check codes the staff member accepted after seeing the message (see Checks). Server re-runs
  every check on each request; a soft check is passed only if its code is in `confirm`. Hard checks cannot be confirmed.

## GET /retail-lines
```jsonc
{
  "owner": false,
  "staff": ["Fern", "Rach"],
  "new_stock_mode": "dry_run",          // "live" | "dry_run": in dry_run, "new" products are planned but NOT created
  "cards": [{
    "source_id": "drive-file-id",
    "supplier": "Supplier A", "invoice_number": "INV-1", "invoice_date": "2026-11-25",
    "department": "Grocer",              // Grocer | Gift Store | Garden
    "open": 2,                           // lines with status "open"
    "lines": [{
      "unmatched_id": 2046,              // the job id used in every route below
      "description": "Brand Product 135g (10)",  // as printed on the invoice
      "qty": 1, "unit": null,            // invoiced quantity and unit (unit often null = each/carton as printed)
      "invoice_unit_cost_ex": 136.10,    // ex-GST price of ONE invoice unit (may be null)
      "printed_pack": 10,                // sellable units per invoice unit read from the description, else null
      "carton_code": "19414966016957",   // code printed on the invoice line; often a CARTON barcode, never assume shelf
      "status": "open",                  // open | setting_up | with_josh | done
      "status_note": null,               // plain words for staff, e.g. "Being set up — test mode, not in Square yet"
      "answer": null,                    // see below; null while open
      "candidates": [ /* option, only while open: suggested existing products */ ]
    }]
  }]
}
```
Option (candidates and search results):
```jsonc
{ "stock_item_id": 745, "name": "Brand - Product – Variation", "count_unit": "each",
  "supplied_by_this_supplier": true, "last_count": 6,       // units per invoice unit last time from this supplier, or null
  "unit_cost_ex": 8.00,                                      // last known cost of ONE sellable unit, ex GST, or null
  "shelf_price": 13.50 }                                     // current shelf price (inc GST), or null
```
Answer:
```jsonc
{ "action": "existing" | "new" | "josh", "by": "Fern", "at": "2026-11-28T12:00:00+11:00",
  "units": 10, "stock_item_id": 745, "name": "…", "barcode": "9300000000000", "no_barcode": false,
  "reason": "…", "confirmed": ["printed_pack_differs"] }
```
Which cards: invoices dated in the last 30 days with at least one retail waiting line, plus lines answered or booked
in the last 48 hours (shown `done` / `setting_up` / `with_josh`). Test and duplicate invoices are excluded.
Order: invoice_date desc, then supplier. Lines in invoice order.

Status meaning:
- `open`: needs a staff action.
- `setting_up`: "new" chosen; product set-up running (or planned only, in `dry_run`).
- `with_josh`: "josh" chosen, or set-up could not finish without Josh (price/category/SKU question, Square refusal).
- `done`: the line is booked to stock (by this app or outside it).

## GET /retail-lines/:unmatched_id/search?q=
`q` at least 2 characters. Returns up to 15 options (same shape), eligible products only. 404 if not a retail
waiting line.

## POST /retail-lines/:unmatched_id/existing
```json
{ "op_id": "uuid", "by": "Fern", "stock_item_id": 745, "units": 6, "confirm": [] }
```
`units`: sellable units in ONE invoice unit, integer 1–500. On success books the line (and any other open line of the
same supplier with the identical description), saves the mapping with that pack, returns status `done`.

## POST /retail-lines/:unmatched_id/new
```json
{ "op_id": "uuid", "by": "Fern", "units": 12, "barcode": "9300000000000", "no_barcode": false,
  "name": "optional staff name for the product", "note": "optional", "confirm": [] }
```
- `barcode`: digits from scanning ONE sellable item (EAN-8, UPC-A 12, EAN-13; GTIN-14 accepted only with indicator 0).
- `no_barcode: true` when the item really has none (Gift Store/Garden usually; Grocer must explain in `note`).
- `name` optional (≤120); the set-up names the product from the invoice in house style.
Returns status `setting_up` (or `with_josh` if set-up already resolved that way on a replay).

## POST /retail-lines/:unmatched_id/josh
```json
{ "op_id": "uuid", "by": "Fern", "reason": "Damaged / not sure what it is" }
```
`reason` 1–300 characters. Returns status `with_josh`.

## Responses
- 200 `{ "ok": true, "status": "done" | "setting_up" | "with_josh", "line": { /* line object */ }, "replayed"?: true }`
- 400 `{ "ok": false, "code": "<code>", "error": "plain message", "checks"?: [{ "code", "soft": bool, "message" }] }`
  - `code` is `needs_confirm` when only soft checks failed (show each message; re-send with their codes in `confirm`).
  - otherwise the first hard failure: `invalid` (bad body/name/units), `not_eligible`, `barcode_invalid`,
    `carton_barcode`, `barcode_known`, `barcode_required`.
- 404 `{ "ok": false, "code": "not_found" }` — not a retail waiting line (or a produce line handled on /deliveries).
- 409 `{ "ok": false, "code": "op_conflict" | "already_answered", "error", "line" }`
- 500 `{ "error" }`; 503 as today (settings unavailable, retry).

## Checks
Sale unit versus carton is the main risk: an invoice unit is usually a carton (the "(10)" in the description) and the
code printed on the invoice is usually the carton barcode.

| code | soft/hard | action | when |
|---|---|---|---|
| `invalid` | hard | all | `by` not a staff name; `units` not an integer 1–500; `reason`/`name` too long; bad `op_id` |
| `not_eligible` | hard | existing | product not in this line's department, archived/inactive/prep, not sold in Square, or supplied only by a different supplier |
| `printed_pack_differs` | soft | existing, new | `units` differs from `printed_pack` (incl. `units` = 1 when the description shows a pack) |
| `count_differs` | soft | existing | `units` more than 50% away from `last_count` for this supplier |
| `cost_above_shelf` | soft | existing | invoice_unit_cost_ex / units ≥ the shelf price ex GST (a carton booked as one item) |
| `cost_differs` | soft | existing | invoice_unit_cost_ex / units outside 0.5×–2× the product's last unit cost |
| `barcode_invalid` | hard | new | not 8/12/13/14 digits or GS1 check digit wrong |
| `carton_barcode` | hard | new | barcode equals the invoice's carton code, or is a GTIN-14 with indicator 1–8 |
| `barcode_known` | hard | new | barcode already on an active Square product (message names it: use "existing") |
| `barcode_required` | hard | new | Grocer, no barcode, `no_barcode` not true or no `note` |

## Not in this packet
- Josh's screen for `with_josh` lines from action "josh" (he sorts them in a Claude chat for now; set-up questions
  still appear in his existing "products waiting" list).
- Repricing after "existing" (retail prices follow the RRP rules, not produce auto-pricing).
- The historical gingerbread booking (separate proposal for Josh).
