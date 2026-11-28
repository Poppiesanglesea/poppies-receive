// delivery-app — Poppie's Anglesea "New stock" API. v15, 26 Nov 2026 (v8 25 Nov reviewed by Codex).
// Staff photograph the invoice/docket that comes with a delivery, correct/add/split lines, scan barcodes,
// and send them for automatic product set-up (new-stock-setup). The photo flow NEVER books invoices or stock.
// Exception (v9): a staff box count on the Deliveries screen maps an already-booked invoice line, which books that line's stock.
// Shop iPad: device key (app_config.delivery_device_key). Josh's price screen: owner key (delivery_owner_key).
// v6: server-side validation, same-receipt resubmit. v7: fixture receipts (is_fixture) hidden from Recent and Josh's list.
// v8: products created without a price (variable price, Josh prices them in Square) show "waiting for a price — don't print labels".
// v9 (26 Nov 2026): Deliveries screen. Jobs from booked Harvey's/Biodynamic Grocer invoices (delivery_tasks):
//   staff tick shelf tags, count boxes the invoice gives no count for (maps + books + reprices), Josh approves or keeps held prices.
// v10 (26 Nov 2026): staff report a box that wasn't the usual size (fixes that delivery's stock and cost only);
//   Josh decides whether it becomes the usual size (delivery_owner_decide routes box-size and price jobs).
// v11 (26 Nov 2026): GET /prices?q= — read-only shelf price lookup from live Square (delivery_price_search). Never writes.
// v12 (26 Nov 2026): GET /prices/all — full shelf price list (Grocer, Gift Store, Garden) from delivery_price_cache, refreshed in the background when >10 min old. Never writes to Square.
// v13 (26 Nov 2026): GET /recent-deliveries[?month=YYYY-MM] — all retail deliveries (invoices + app photos), last 14 days in full, older months folded (delivery_recent_list). Read-only.
// v15 (26 Nov 2026): config-read failures fail closed as 503 (never cached, never reported as an invalid device);
//   wrong/malformed keys stay 401 (auth.ts, tested in repo). Routes now surface DB errors instead of returning empty
//   success. GET /health reports BUILD and SOURCE_SHA (embedded by scripts/check-edge.mjs) for deploy verification.
// v17 (26 Nov 2026): photo receipts are reserved before upload with a payload fingerprint, never overwrite stored photos,
//   check every storage/row write, and re-dispatch a lost or failed reader hand-off from the stored PDF (receipts.ts).
//   Shelf-tag confirm uses delivery_tag_claim then delivery_tag_apply as two calls when the database has them
//   (staged pricing_03); before that it falls back to the single delivery_task_tick call.
// v19 (28 Nov 2026; the unmerged known-barcodes branch is "v18 2026-11-27"): retail waiting lines (retail.ts; contract docs/retail-lines-contract.md): GET /retail-lines,
//   GET /retail-lines/:id/search, POST /retail-lines/:id/(existing|new|josh). "new" hands the line to new-stock-setup.
//   Rev 2: browsing is read-only (no sweep, no requeue); POST /owner/retail-lines/:id/promote (owner key) approves a
//   product planned while set-up was in test mode. /recent lists only photo receipts (origin = 'photo').
// v16 (26 Nov 2026): POST /receipts accepts a client op_id (uuid) and uses it as the receipt id, so re-sending the same
//   photo set after an uncertain failure returns the existing receipt instead of creating a duplicate delivery.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { PDFDocument } from "npm:pdf-lib@1.17.1";
import { ConfigUnavailable, makeCfg, whoFromHeaders } from "./auth.ts";
import { createReceipt, reconcileReceipt, type Deps, type Receipt } from "./receipts.ts";
import { confirmTag, type RpcErr } from "./tags.ts";
import { retailOwnerRoute, retailRoute } from "./retail.ts";

export const BUILD = "delivery-app v19 2026-11-28 retail-lines";
// SOURCE_SHA is written by scripts/check-edge.mjs --write: sha-256 of index.ts (with this one line removed), auth.ts, receipts.ts, tags.ts and retail.ts.
export const SOURCE_SHA = { index: "81f76bfde5ea97551ad87cb78279ebc2167ff2c072bff432c65841103ebb9a91", auth: "1c3f2f3fbdcffb50d150df19e7aef3c67cc6292d9d8a09e37ccd235c63e52331", receipts: "0bbd4a7723ef2f7b146ac729ab08c45034a4d6dd04fecb3ef6c1adf72f199afe", tags: "0866c0de5065b546c54c8211853388e3316ec5fa4d297f70f12f30c2ed340c3d", retail: "ba5b57337b58cc61ffd90daf4586f78be1f510168961cd21505e40e9362b6ff8" };

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SB = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const HOOK_KEY = Deno.env.get("POPPIES_INVOICE_HOOK_KEY") ?? "";
const DEPTS = ["Garden", "Grocer", "Gift Store"];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-device-key, x-owner-key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const cfg = makeCfg(async (key) => {
  const { data, error } = await SB.from("app_config").select("value").eq("key", key).maybeSingle();
  return { value: data?.value ?? null, error };
});
const who = (req: Request) => whoFromHeaders(req.headers, cfg);
const unavailable = () => json({ error: "The app can't reach its settings right now. Wait a moment and try again.", retry: true }, 503);

function bytesToB64(u: Uint8Array) { let s = ""; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000)); return btoa(s); }
const RCOLS = "id, source_id, supplier, department, status, photo_paths, confirmed_payload, hold_reason, created_at";
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const DEPS: Deps = {
  getReceipt: async (id) => { const r = await SB.from("delivery_receipts").select(RCOLS).eq("id", id).maybeSingle(); return { data: r.data as Receipt | null, error: r.error }; },
  insertReceipt: async (row) => { const r = await SB.from("delivery_receipts").insert(row); return { error: r.error }; },
  updateReceipt: async (id, patch, cond) => {
    let q = SB.from("delivery_receipts").update(patch).eq("id", id).in("status", cond.statuses);
    if ("dispatchToken" in cond) {
      q = cond.dispatchToken == null ? q.is("confirmed_payload->upload->>dispatch_token", null) : q.eq("confirmed_payload->upload->>dispatch_token", cond.dispatchToken);
    }
    const r = await q.select(RCOLS);
    return { data: r.data as Receipt[] | null, error: r.error };
  },
  upload: async (path, bytes, contentType) => {
    const r = await SB.storage.from("delivery-photos").upload(path, bytes, { contentType, upsert: false });
    if (!r.error) return { error: null };
    const e = r.error as { message: string; statusCode?: string | number };
    return { error: { message: e.message }, exists: String(e.statusCode ?? "") === "409" || /already exists|duplicate/i.test(e.message) };
  },
  download: async (path) => {
    const r = await SB.storage.from("delivery-photos").download(path);
    return { data: r.data ? new Uint8Array(await r.data.arrayBuffer()) : null, error: r.error ? { message: r.error.message } : null };
  },
  queueRow: async (sourceId) => { const r = await SB.from("invoice_ingest_queue").select("source_id").eq("source_id", sourceId).maybeSingle(); return { data: r.data, error: r.error }; },
  buildPdf: async (pages) => {
    const pdf = await PDFDocument.create();
    for (const bytes of pages) {
      const img = await pdf.embedJpg(bytes);
      const page = pdf.addPage([img.width, img.height]);
      page.drawImage(img, { x: 0, y: 0, width: img.width, height: img.height });
    }
    return await pdf.save();
  },
  dispatch: async ({ source_id, supplier, department, pdf }) => {
    const r = await fetch(`${URL_}/functions/v1/invoice-reader`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-poppies-key": HOOK_KEY },
      body: JSON.stringify({ drive_file_id: source_id, supplier_folder: supplier, business_unit_folder: department, file_name: "New stock app photo", pdf_base64: bytesToB64(pdf), received_at: new Date().toISOString() }),
    });
    return { ok: r.ok, status: r.status, body: await r.json().catch(() => ({})) };
  },
  now: () => new Date(),
  sha256: async (d) => hex(await crypto.subtle.digest("SHA-256", typeof d === "string" ? new TextEncoder().encode(d) : new Uint8Array(d))),
  uuid: () => crypto.randomUUID(),
};
function setup(body: unknown) {
  return fetch(`${URL_}/functions/v1/new-stock-setup`, { method: "POST", headers: { "content-type": "application/json", "x-poppies-key": HOOK_KEY }, body: JSON.stringify(body) });
}
let lastSweep = 0;
function sweepSoon() {
  if (Date.now() - lastSweep < 10 * 60000) return;
  lastSweep = Date.now();
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime.waitUntil(setup({ sweep: true }).catch(() => null));
}

export function validateLines(raw: unknown): [Record<string, unknown>[], string | null] {
  if (!Array.isArray(raw) || !raw.length) return [[], "No lines to send."];
  if (raw.length > 150) return [[], "Too many lines."];
  const num = (v: unknown) => v === "" || v == null ? null : Number(v);
  const out: Record<string, unknown>[] = [];
  for (const [i, l] of (raw as Record<string, unknown>[]).entries()) {
    const description = String(l.description ?? "").trim().slice(0, 200);
    const qty = num(l.qty);
    if (!description) return [[], `Row ${i + 1}: enter a product name or remove this row.`];
    if (qty === null || !Number.isFinite(qty) || qty <= 0 || qty > 100000) return [[], `Row ${i + 1}: enter the quantity that arrived.`];
    const source = l.source === "added" || l.source === "split" ? l.source : "invoice";
    const unit_price = num(l.unit_price);
    if (unit_price !== null && (!Number.isFinite(unit_price) || unit_price < 0)) return [[], `Row ${i + 1}: the cost isn't a valid number.`];
    out.push({
      description, qty, unit_price, source,
      invoice_description: l.invoice_description ? String(l.invoice_description).slice(0, 200) : null,
      sku: source === "split" ? null : (l.sku ? String(l.sku).slice(0, 60) : null),
      split_group: source === "split" && l.split_group ? String(l.split_group).slice(0, 20) : null,
      split_total: source === "split" ? num(l.split_total) : null,
      barcode: l.barcode ? String(l.barcode).replace(/\D/g, "").slice(0, 14) || null : null,
      unit: l.unit ? String(l.unit).slice(0, 30) : null,
      note: l.note ? String(l.note).slice(0, 300) : null,
    });
  }
  const groups: Record<string, Record<string, unknown>[]> = {};
  for (const l of out) if (l.source === "split") {
    if (!l.split_group) return [[], "A split row is missing its group. Start the split again."];
    (groups[l.split_group as string] ||= []).push(l);
  }
  for (const rows of Object.values(groups)) {
    if (rows.length < 2) return [[], `The split of "${rows[0].invoice_description}" has only one part.`];
    const total = rows[0].split_total as number | null;
    const sum = rows.reduce((a, r) => a + (r.qty as number), 0);
    if (total !== null && Math.abs(sum - total) > 1e-9) return [[], `The parts of "${rows[0].invoice_description}" add up to ${sum}, but the paperwork says ${total}.`];
  }
  return [out, null];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const path = new URL(req.url).pathname.replace(/^.*\/delivery-app/, "") || "/";
  try {
    if (req.method === "GET" && path === "/health") {
      return json({ ok: true, build: BUILD, source_sha: SOURCE_SHA });
    }
    const w = await who(req);
    if (!w.device) return json({ error: "This device isn't set up. Ask Josh for the setup link." }, 401);

    if (path.startsWith("/owner")) {
      if (!w.owner) return json({ error: "owner only" }, 403);
      if (req.method === "GET" && path === "/owner/needs") {
        const { data, error } = await SB.from("new_stock_lines").select("id, input, decision, price, note, status, receipt_id, delivery_receipts!inner(supplier, department, created_at, is_fixture)").eq("delivery_receipts.is_fixture", false).in("status", ["needs_josh", "failed", "square_created"]).order("id", { ascending: false }).limit(100);
        if (error) return json({ error: "Couldn't load products waiting for a price." }, 500);
        return json(data ?? []);
      }
      if (req.method === "GET" && path === "/owner/awaiting") {
        const { data, error } = await SB.from("v_new_stock_awaiting_price").select("line_id, supplier, department, item, variation, sku, unit_cost_ex, days_waiting").order("applied_at").limit(200);
        if (error) return json({ error: "Couldn't load products waiting for a price." }, 500);
        return json(data ?? []);
      }
      if (req.method === "POST" && path === "/owner/price") {
        const b = await req.json();
        const price = Number(b.price);
        if (!(price > 0 && price < 10000)) return json({ error: "Enter a price above 0." }, 400);
        const r = await setup({ line_id: Number(b.line_id), josh_price: Math.round(price * 100) / 100 });
        return json(await r.json().catch(() => ({})), r.status);
      }
      const pm = path.match(/^\/owner\/price-ops\/(\d+)\/resolve$/);
      if (req.method === "POST" && pm) {
        // Josh settles a register price the tag confirm could not apply safely (changed elsewhere, or a smaller tag with
        // no recorded price): 'overwrite' with the price the register shows now, or 'skip' to leave the register as is.
        const b = await req.json().catch(() => ({}));
        const action = b.action === "overwrite" || b.action === "skip" ? b.action : null;
        const now = Number(b.register_now);
        if (!action) return json({ error: "Unknown action." }, 400);
        if (action === "overwrite" && !(Number.isFinite(now) && now >= 0 && now < 10000)) return json({ error: "Enter the price the register shows now." }, 400);
        // skip: the register price Josh read (if given) is what staff put the tag back to
        const cents = Number.isFinite(now) && b.register_now !== null && b.register_now !== "" && now >= 0 && now < 10000 ? Math.round(now * 100) : null;
        const { data, error } = await SB.rpc("price_op_resolve", { p_op_id: Number(pm[1]), p_action: action, p_expected_cents: cents, p_by: "Josh" });
        if (error) return json({ error: error.code === "PGRST202" ? "Not available yet." : "Couldn't save. Try again." }, error.code === "PGRST202" ? 404 : 500);
        return json(data, data?.ok ? 200 : 400);
      }
      // deno-lint-ignore no-explicit-any
      const ro = await retailOwnerRoute((fn, args) => SB.rpc(fn, args) as unknown as Promise<{ data: any; error: RpcErr }>, req.method, path, () => req.json());
      if (ro) {
        const b = ro.body as { receipt_id?: string; status?: string } | null;
        if (ro.status === 200 && b?.receipt_id && b.status === "setting_up") {
          // deno-lint-ignore no-explicit-any
          (globalThis as any).EdgeRuntime.waitUntil(setup({ receipt_id: b.receipt_id }).catch(() => null));
        }
        return json(ro.body, ro.status);
      }
      const om = path.match(/^\/owner\/tasks\/(\d+)\/decide$/);
      if (req.method === "POST" && om) {
        const b = await req.json().catch(() => ({}));
        const decision = b.decision === "keep" ? "keep" : b.decision === "approve" ? "approve" : "";
        if (!decision) return json({ error: "approve or keep" }, 400);
        const price = b.price === "" || b.price == null ? null : Number(b.price);
        if (price !== null && !(price > 0 && price < 10000)) return json({ error: "Enter a price above 0." }, 400);
        const { data, error } = await SB.rpc("delivery_owner_decide", { p_task_id: Number(om[1]), p_decision: decision, p_price: price, p_by: "Josh" });
        if (error) return json({ error: error.message }, 500);
        return json(data, data?.ok ? 200 : 400);
      }
      return json({ error: "not found" }, 404);
    }

    // ---- Retail waiting lines (v18)
    if (path.startsWith("/retail-lines")) {
      const staff = async () => (await cfg("delivery_staff_names")).split(",").map((n) => n.trim()).filter(Boolean);
      // deno-lint-ignore no-explicit-any
      const out = await retailRoute((fn, args) => SB.rpc(fn, args) as unknown as Promise<{ data: any; error: RpcErr }>,
        req.method, path, new URL(req.url), () => req.json(), staff, w.owner);
      if (out) {
        const b = out.body as { receipt_id?: string; status?: string } | null;
        if (out.status === 200 && b?.receipt_id && b.status === "setting_up") {
          // deno-lint-ignore no-explicit-any
          (globalThis as any).EdgeRuntime.waitUntil(setup({ receipt_id: b.receipt_id }).catch(() => null));  // the sweep retries a lost hand-off
        }
        return json(out.body, out.status);
      }
    }
    // ---- Recent retail deliveries (v13): last 14 days + older months folded; ?month=YYYY-MM opens one month
    if (req.method === "GET" && path === "/recent-deliveries") {
      const mo = new URL(req.url).searchParams.get("month");
      if (mo !== null && !/^\d{4}-\d{2}$/.test(mo)) return json({ error: "bad month" }, 400);
      const { data, error } = await SB.rpc("delivery_recent_list", { p_month: mo });
      if (error) return json({ error: "Couldn't load deliveries right now." }, 500);
      return json(data ?? {});
    }
    // ---- Shelf prices (v12): full list from delivery_price_cache; refreshed in the background from Square when >10 min old
    if (req.method === "GET" && path === "/prices/all") {
      const { data, error } = await SB.from("delivery_price_cache").select("rows, checked_at").eq("id", 1).maybeSingle();
      if (error) return json({ error: "Price list isn't working right now." }, 500);
      const age = data ? Date.now() - new Date(data.checked_at).getTime() : Infinity;
      if (age > 10 * 60000) {
        // deno-lint-ignore no-explicit-any
        (globalThis as any).EdgeRuntime.waitUntil(SB.rpc("delivery_price_cache_refresh").then(() => null, () => null));
      }
      if (!data) return json({ ok: false, error: "The price list is being built. Try again in a minute." }, 503);
      return json({ ok: true, rows: data.rows, checked_at: data.checked_at, refreshing: age > 10 * 60000 });
    }
    // ---- Shelf prices (v11): read-only, live from Square
    if (req.method === "GET" && path === "/prices") {
      const q = (new URL(req.url).searchParams.get("q") ?? "").slice(0, 60);
      const { data, error } = await SB.rpc("delivery_price_search", { p_q: q });
      if (error) return json({ error: "Price lookup isn't working right now." }, 500);
      return json(data, data?.ok ? 200 : 400);
    }

    // ---- Deliveries (v9)
    if (req.method === "GET" && path === "/deliveries") {
      const { data, error } = await SB.rpc("delivery_tasks_list");
      if (error) return json({ error: error.message }, 500);
      const names = (await cfg("delivery_staff_names")).split(",").map((n) => n.trim()).filter(Boolean);
      return json({ owner: w.owner, staff: names, cards: data ?? [] });
    }
    const bm = path.match(/^\/deliveries\/([A-Za-z0-9_:.-]{1,120})\/boxes\/(\d+)\/report$/);
    if (req.method === "POST" && bm) {
      const b = await req.json().catch(() => ({}));
      const by = String(b.by ?? "").trim().slice(0, 40);
      const names = (await cfg("delivery_staff_names")).split(",").map((n) => n.trim());
      if (!names.includes(by)) return json({ error: "Pick your name first." }, 400);
      const actual = Number(b.actual);
      if (!(actual > 0 && actual <= 1000)) return json({ error: "Enter what was in one box." }, 400);
      const { data, error } = await SB.rpc("delivery_box_report", { p_source_id: decodeURIComponent(bm[1]), p_line_id: Number(bm[2]), p_actual: actual, p_by: by });
      if (error) return json({ error: error.message }, 500);
      return json(data, data?.ok ? 200 : 400);
    }
    const tm = path.match(/^\/tasks\/(\d+)\/(tick|count|search)$/);
    if (tm) {
      const id = Number(tm[1]);
      if (req.method === "GET" && tm[2] === "search") {
        const q = new URL(req.url).searchParams.get("q") ?? "";
        const { data: t, error: tErr } = await SB.from("delivery_tasks").select("unmatched_id").eq("id", id).eq("kind", "count").maybeSingle();
        if (tErr) return json({ error: "Couldn't load this job." }, 500);
        if (!t) return json({ error: "not found" }, 404);
        const { data, error } = await SB.rpc("delivery_item_search", { p_unmatched_id: t.unmatched_id, p_q: q });
        if (error) return json({ error: error.message }, 500);
        return json(data ?? []);
      }
      if (req.method === "POST") {
        const b = await req.json().catch(() => ({}));
        const by = String(b.by ?? "").trim().slice(0, 40);
        const names = (await cfg("delivery_staff_names")).split(",").map((n) => n.trim());
        if (!names.includes(by)) return json({ error: "Pick your name first." }, 400);
        if (tm[2] === "tick") {
          const out = await confirmTag((fn, args) => SB.rpc(fn, args) as unknown as Promise<{ data: any; error: RpcErr }>, id, by);
          return json(out.body, out.status);
        }
        const { data, error } = tm[2] === "tick"
          ? await SB.rpc("delivery_task_tick", { p_task_id: id, p_by: by })
          : await SB.rpc("delivery_count_answer", {
              p_task_id: id, p_stock_item_id: b.stock_item_id == null ? null : Number(b.stock_item_id),
              p_count: Number.isFinite(Number(b.count)) ? Number(b.count) : null, p_by: by, p_note: b.note ? String(b.note).slice(0, 300) : null,
            });
        if (error) return json({ error: error.message }, 500);
        return json(data, data?.ok ? 200 : 400);
      }
    }

    if (req.method === "GET" && path === "/suppliers") {
      const dept = new URL(req.url).searchParams.get("department") ?? "";
      const { data, error } = await SB.rpc("delivery_supplier_list", { p_department: dept });
      if (error) return json({ error: error.message }, 500);
      const rows = (data ?? []) as { name: string; usual: boolean }[];
      return json({ usual: rows.filter((r) => r.usual).map((r) => r.name), others: rows.filter((r) => !r.usual).map((r) => r.name) });
    }

    if (req.method === "POST" && path === "/receipts") {
      const b = await req.json().catch(() => null);
      if (!b || typeof b !== "object") return json({ error: "supplier, department and 1 to 6 photos are needed" }, 400);
      const out = await createReceipt(DEPS, b as Record<string, unknown>);
      return json(out.body, out.status);
    }

    const m = path.match(/^\/receipts\/([0-9a-f-]{36})(\/submit|\/cancel|\/items)?$/);
    if (m) {
      const { data: rec, error: recErr } = await SB.from("delivery_receipts").select("*").eq("id", m[1]).maybeSingle();
      if (recErr) return json({ error: "Couldn't load this delivery." }, 500);
      if (!rec) return json({ error: "not found" }, 404);

      if (req.method === "GET" && !m[2]) {
        if (rec.status === "reading") {
          const { data: q } = await SB.from("invoice_ingest_queue").select("status, extraction, checks, hold_reason").eq("source_id", rec.source_id).maybeSingle();
          if (q && q.extraction && q.status !== "received") {
            const ext = { ...q.extraction, reader_holds: q.hold_reason, mapped: q.checks?.mapped ?? [], duplicate_of: q.checks?.duplicate_of ?? null };
            await SB.from("delivery_receipts").update({ status: "ready", extraction: ext }).eq("id", rec.id);
            rec.status = "ready"; rec.extraction = ext;
          } else if (q && ["error", "skipped_not_stock"].includes(q.status)) {
            await SB.from("delivery_receipts").update({ status: "error", hold_reason: q.hold_reason }).eq("id", rec.id);
            rec.status = "error"; rec.hold_reason = q.hold_reason;
          } else if (!q) {
            Object.assign(rec, await reconcileReceipt(DEPS, rec as Receipt));   // lost reader hand-off: re-send the stored PDF
          }
        } else if (rec.status === "error") {
          Object.assign(rec, await reconcileReceipt(DEPS, rec as Receipt));     // failed reader hand-off: retry from the stored PDF
        }
        return json({ id: rec.id, status: rec.status, supplier: rec.supplier, department: rec.department, extraction: rec.extraction, setup_status: rec.setup_status, hold_reason: rec.hold_reason });
      }

      if (req.method === "GET" && m[2] === "/items") {
        const { data, error } = await SB.from("new_stock_lines").select("id, line_no, input, status, sku, result, note, awaiting_price").eq("receipt_id", rec.id).order("line_no");
        const { data: aw, error: awErr } = await SB.from("v_new_stock_awaiting_price").select("line_id").eq("receipt_id", rec.id);
        if (error || awErr) return json({ error: "Couldn't load this delivery's products." }, 500);
        const waiting = new Set((aw ?? []).map((a) => a.line_id));
        // price_state: "awaiting" = in Square with no price yet (don't print labels); "priced" = Josh has since priced it in Square
        const lines = (data ?? []).map(({ id, ...l }) => ({ ...l, price_state: l.awaiting_price ? (waiting.has(id) ? "awaiting" : "priced") : null }));
        const setup_status = rec.setup_status === "ready" && waiting.size ? "awaiting_price" : rec.setup_status;
        return json({ supplier: rec.supplier, department: rec.department, setup_status, lines });
      }

      if (req.method === "POST" && m[2] === "/cancel") {
        if (rec.status === "submitted") return json({ error: "already sent for set-up" }, 409);
        await SB.from("delivery_receipts").update({ status: "cancelled" }).eq("id", rec.id);
        return json({ status: "cancelled" });
      }

      if (req.method === "POST" && m[2] === "/submit") {
        if (rec.status === "submitted") return json({ error: "already sent", status: "submitted" }, 409);
        if (rec.status !== "ready") return json({ error: `cannot send while ${rec.status}` }, 409);
        const b = await req.json();
        const [lines, err] = validateLines(b.lines);
        if (err) return json({ error: err }, 400);
        const { data: upd } = await SB.from("delivery_receipts").update({
          status: "submitted", submitted_lines: lines, submitted_at: new Date().toISOString(), setup_status: "pending",
          staff_edits: { invoice_number: String(b.invoice_number ?? "").trim() || null, invoice_date: b.invoice_date || null, read: (rec.extraction?.lines ?? []).length, sent: lines.length },
        }).eq("id", rec.id).eq("status", "ready").select("id");
        if (!upd?.length) return json({ error: "already sent", status: "submitted" }, 409);
        await SB.from("engine_runs").insert({ steps_ok: 1, steps_failed: 0, notes: `NEW-STOCK-APP submitted source=${rec.source_id} supplier=${rec.supplier} dept=${rec.department} lines=${lines.length}` });
        // deno-lint-ignore no-explicit-any
        (globalThis as any).EdgeRuntime.waitUntil(setup({ receipt_id: rec.id }).catch(() => null));
        return json({ status: "submitted" });
      }
    }

    if (req.method === "GET" && path === "/recent") {
      sweepSoon();
      const { data, error } = await SB.from("delivery_receipts").select("id, supplier, department, status, setup_status, created_at").eq("is_fixture", false).eq("origin", "photo").neq("status", "cancelled").order("created_at", { ascending: false }).limit(20);
      if (error) return json({ error: "Couldn't load recent deliveries." }, 500);
      const ids = (data ?? []).filter((r) => r.setup_status === "ready").map((r) => r.id);
      const { data: aw, error: awErr } = ids.length ? await SB.from("v_new_stock_awaiting_price").select("receipt_id").in("receipt_id", ids) : { data: [], error: null };
      if (awErr) return json({ error: "Couldn't load recent deliveries." }, 500);
      const waiting = new Set((aw ?? []).map((a) => a.receipt_id));
      const items = (data ?? []).map((r) => waiting.has(r.id) ? { ...r, setup_status: "awaiting_price" } : r);
      return json({ owner: w.owner, items });
    }
    return json({ error: "not found" }, 404);
  } catch (e) {
    if (e instanceof ConfigUnavailable) return unavailable();
    return json({ error: String((e as Error).message ?? e).slice(0, 300) }, 500);
  }
});
