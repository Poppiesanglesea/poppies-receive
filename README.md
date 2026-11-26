# Poppie's Anglesea — Receive delivery

Staff page for the shop iPad. The page holds no keys or data; the iPad is set up once with a device link, and everything else sits on the Poppie's back end (Supabase function `delivery-app`).

- **New delivery:** photograph the invoice or docket, check the lines, and send new products for set-up in Square.
- **Deliveries to finish** (added 26 Nov 2026): jobs from booked Harvey's and Biodynamic Grocer invoices. Staff tick shelf tags once changed, and count boxes the invoice gives no count for. Josh approves or keeps held prices from his own device.
- **Shelf prices** (added 26 Nov 2026): search any product to see its current Square price, for when a shelf tag is missing. Read-only, live from Square; it never changes a price.

Tests: `node --test test/*.test.mjs`
