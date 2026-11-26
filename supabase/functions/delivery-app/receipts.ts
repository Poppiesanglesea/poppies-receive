// Photo-receipt intake for the delivery app (v17, 26 Nov 2026). Pure logic with injected I/O so it can be tested
// without Supabase or the invoice reader (test/receipts.test.mjs).
//
// Reliability rules
//  * Reserve before upload: the receipt row (status 'uploading') is inserted BEFORE any photo is stored, carrying a
//    fingerprint of the payload (supplier, department, page count, sha-256 of every page). The client's op_id is the
//    receipt id, so one send = one receipt however often it is retried.
//  * A retry with the same op_id must carry the same payload (fingerprint) — otherwise 409, nothing touched.
//    A retry of an unfinished send resumes it: photos and the PDF are stored with upsert OFF (an existing object at our
//    own path is the same content because the fingerprint matched), so a concurrent or later request can never
//    overwrite the photos of the request that won the reservation.
//  * Every storage write and every row write is checked. A failure leaves the row 'upload_failed' (resumable) and
//    returns an error; nothing is reported as received unless it is.
//  * Only the request that moves the row 'uploading' -> 'reading' dispatches to the invoice reader.
//  * Dispatch reconciliation: a 'reading' receipt with no reader queue row after 3 minutes, or an 'error' receipt
//    whose dispatch failed, is re-dispatched from the stored PDF with the same source_id (max 5 attempts, one at a
//    time via an optimistic check on the last attempt time).

export const DEPTS = ["Garden", "Grocer", "Gift Store"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const RESUMABLE = ["uploading", "upload_failed"];
const REDISPATCH_AFTER_MS = { reading: 3 * 60_000, error: 60_000 };
const MAX_DISPATCH = 5;

export type DbErr = { code?: string; message: string } | null;
export type Receipt = {
  id: string; source_id: string; supplier: string; department: string; status: string; photo_paths: string[];
  confirmed_payload: { upload?: Upload } | null; hold_reason?: string | null; created_at?: string;
};
export type Upload = {
  fingerprint?: string; pages?: number; reserved_at?: string; dispatch?: "pending" | "sent" | "failed";
  dispatch_attempts?: number; last_dispatch_at?: string | null; error?: string;
};
export type Deps = {
  getReceipt(id: string): Promise<{ data: Receipt | null; error: DbErr }>;
  insertReceipt(row: Partial<Receipt>): Promise<{ error: DbErr }>;
  // update only when the row is still in one of `statuses` (and, if given, last_dispatch_at still equals `lastDispatchAt`)
  updateReceipt(id: string, patch: Partial<Receipt>, cond: { statuses: string[]; lastDispatchAt?: string | null }): Promise<{ data: Receipt[] | null; error: DbErr }>;
  upload(path: string, bytes: Uint8Array, contentType: string): Promise<{ error: DbErr; exists?: boolean }>;
  download(path: string): Promise<{ data: Uint8Array | null; error: DbErr }>;
  queueRow(sourceId: string): Promise<{ data: unknown | null; error: DbErr }>;
  buildPdf(pages: Uint8Array[]): Promise<Uint8Array>;
  dispatch(r: { source_id: string; supplier: string; department: string; pdf: Uint8Array }): Promise<{ ok: boolean; status: number; body: unknown }>;
  now(): Date;
  sha256(data: Uint8Array | string): Promise<string>;
  uuid(): string;
};
type Out = { status: number; body: Record<string, unknown> };

export function b64ToBytes(b64: string) {
  const s = atob(b64.replace(/^data:[^,]+,/, ""));
  const u = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i);
  return u;
}
const isJpeg = (u: Uint8Array) => u.length > 3 && u[0] === 0xff && u[1] === 0xd8 && u[2] === 0xff;
const dirOf = (r: Receipt) => `${(r.confirmed_payload?.upload?.reserved_at ?? r.created_at ?? "").slice(0, 10)}/${r.id}`;
const upl = (r: Receipt): Upload => r.confirmed_payload?.upload ?? {};
const withUpload = (r: Receipt, u: Upload) => ({ ...(r.confirmed_payload ?? {}), upload: { ...upl(r), ...u } });
const sameDelivery = (r: Receipt, supplier: string, department: string, fp: string) =>
  r.supplier === supplier && r.department === department && (!upl(r).fingerprint || upl(r).fingerprint === fp);
const received = (r: Receipt, code = 200): Out => ({ status: code, body: { id: r.id, status: r.status === "uploading" ? "saving" : r.status, already_received: true } });

export async function createReceipt(d: Deps, b: Record<string, unknown>): Promise<Out> {
  const supplier = String(b.supplier ?? "").trim();
  const department = String(b.department ?? "");
  const images = Array.isArray(b.images) ? b.images : [];
  if (!supplier || !DEPTS.includes(department) || !images.length || images.length > 6) {
    return { status: 400, body: { error: "supplier, department and 1 to 6 photos are needed" } };
  }
  let pages: Uint8Array[];
  try { pages = images.map((x) => b64ToBytes(String(x))); } catch { return { status: 400, body: { error: "A photo couldn't be read. Take it again." } }; }
  if (!pages.every(isJpeg)) return { status: 400, body: { error: "A photo couldn't be read. Take it again." } };
  const opId = typeof b.op_id === "string" && UUID.test(b.op_id) ? b.op_id : null;
  const fp = await d.sha256([supplier, department, String(pages.length), ...(await Promise.all(pages.map((p) => d.sha256(p))))].join("\n"));

  const id = opId ?? d.uuid();
  let rec: Receipt | null = null;
  if (opId) {
    const prior = await d.getReceipt(id);
    if (prior.error) return { status: 500, body: { error: "Couldn't check for an earlier send. Try again." } };
    if (prior.data) {
      if (!sameDelivery(prior.data, supplier, department, fp)) return { status: 409, body: { error: "This upload id belongs to a different delivery." } };
      if (!RESUMABLE.includes(prior.data.status)) {
        if (prior.data.status === "error" && upl(prior.data).dispatch === "failed") return redispatch(d, prior.data, true);
        return received(prior.data);
      }
      rec = prior.data;   // resume an unfinished send of the same photos
    }
  }
  if (!rec) {
    const now = d.now().toISOString();
    const row: Partial<Receipt> = { id, source_id: `app:${id}`, supplier, department, status: "uploading", photo_paths: [],
      confirmed_payload: { upload: { fingerprint: fp, pages: pages.length, reserved_at: now, dispatch: "pending", dispatch_attempts: 0 } } };
    const ins = await d.insertReceipt(row);
    if (ins.error) {
      if (ins.error.code !== "23505") return { status: 500, body: { error: "Couldn't save the delivery. Try again." } };
      const won = await d.getReceipt(id);      // a concurrent send with the same op_id reserved it first
      if (won.error || !won.data) return { status: 500, body: { error: "Couldn't save the delivery. Try again." } };
      if (!sameDelivery(won.data, supplier, department, fp)) return { status: 409, body: { error: "This upload id belongs to a different delivery." } };
      if (!RESUMABLE.includes(won.data.status)) return received(won.data);
      rec = won.data;
    } else {
      rec = row as Receipt;
    }
  }
  return finishUpload(d, rec, pages);
}

async function failUpload(d: Deps, rec: Receipt, what: string): Promise<Out> {
  await d.updateReceipt(rec.id, { status: "upload_failed", hold_reason: what, confirmed_payload: withUpload(rec, { error: what }) }, { statuses: RESUMABLE });
  return { status: 500, body: { error: "Couldn't save the photos. Your photos are still on the iPad — tap Send to try again." } };
}

async function finishUpload(d: Deps, rec: Receipt, pages: Uint8Array[]): Promise<Out> {
  const dir = dirOf(rec);
  const paths: string[] = [];
  for (let i = 0; i < pages.length; i++) {
    const p = `${dir}/page-${i + 1}.jpg`;
    const up = await d.upload(p, pages[i], "image/jpeg");
    if (up.error && !up.exists) return failUpload(d, rec, `photo upload: ${up.error.message}`.slice(0, 200));
    paths.push(p);
  }
  let pdf: Uint8Array;
  try { pdf = await d.buildPdf(pages); } catch (e) { return failUpload(d, rec, `pdf: ${String((e as Error).message ?? e)}`.slice(0, 200)); }
  const up = await d.upload(`${dir}/invoice.pdf`, pdf, "application/pdf");
  if (up.error && !up.exists) return failUpload(d, rec, `pdf upload: ${up.error.message}`.slice(0, 200));
  if (up.exists) {   // an earlier attempt stored the PDF: dispatch exactly that file
    const got = await d.download(`${dir}/invoice.pdf`);
    if (got.error || !got.data) return failUpload(d, rec, "pdf re-read failed");
    pdf = got.data;
  }

  const now = d.now().toISOString();
  const moved = await d.updateReceipt(rec.id, { status: "reading", photo_paths: paths, hold_reason: null,
    confirmed_payload: withUpload(rec, { dispatch: "pending", last_dispatch_at: now, dispatch_attempts: (upl(rec).dispatch_attempts ?? 0) + 1, error: undefined }) },
    { statuses: RESUMABLE });
  if (moved.error) return { status: 500, body: { error: "Couldn't save the delivery. Try again." } };
  if (!moved.data?.length) {   // another request finished this send first; it does the dispatch
    const cur = await d.getReceipt(rec.id);
    if (cur.error || !cur.data) return { status: 500, body: { error: "Couldn't save the delivery. Try again." } };
    return received(cur.data, 202);
  }
  return dispatchOnce(d, moved.data[0], pdf, 202);
}

async function dispatchOnce(d: Deps, rec: Receipt, pdf: Uint8Array, okCode: number): Promise<Out> {
  let r: { ok: boolean; status: number; body: unknown };
  try { r = await d.dispatch({ source_id: rec.source_id, supplier: rec.supplier, department: rec.department, pdf }); }
  catch (e) { r = { ok: false, status: 0, body: String((e as Error).message ?? e) }; }
  const accepted = r.ok && (r.body as { status?: string } | null)?.status === "accepted";
  if (accepted) {
    await d.updateReceipt(rec.id, { status: "reading", hold_reason: null, confirmed_payload: withUpload(rec, { dispatch: "sent" }) }, { statuses: ["reading", "error"] });
    return { status: okCode, body: { id: rec.id, status: "reading" } };
  }
  const why = `reader: ${r.status} ${JSON.stringify(r.body).slice(0, 200)}`;
  await d.updateReceipt(rec.id, { status: "error", hold_reason: why, confirmed_payload: withUpload(rec, { dispatch: "failed" }) }, { statuses: ["reading", "error"] });
  return { status: 502, body: { id: rec.id, status: "error", reason: "The invoice reader is not available right now. The photo is saved and will be sent again automatically." } };
}

// Re-dispatch from the stored PDF. `force` = explicit resend of a failed dispatch by the same op_id.
async function redispatch(d: Deps, rec: Receipt, force = false): Promise<Out> {
  const u = upl(rec);
  const attempts = u.dispatch_attempts ?? 0;
  if (attempts >= MAX_DISPATCH) return received(rec);
  const last = u.last_dispatch_at ?? rec.created_at ?? null;
  const wait = REDISPATCH_AFTER_MS[rec.status as "reading" | "error"];
  if (!force && (wait === undefined || (last && d.now().getTime() - Date.parse(last) < wait))) return received(rec);
  const claim = await d.updateReceipt(rec.id, { confirmed_payload: withUpload(rec, { last_dispatch_at: d.now().toISOString(), dispatch_attempts: attempts + 1 }) },
    { statuses: [rec.status], lastDispatchAt: u.last_dispatch_at ?? null });
  if (claim.error || !claim.data?.length) return received(rec);   // another request is re-dispatching it
  const got = await d.download(`${dirOf(rec)}/invoice.pdf`);
  if (got.error || !got.data) return received(rec);
  return dispatchOnce(d, claim.data[0], got.data, 202);
}

// Called when a receipt is looked at: re-dispatch a lost or failed reader hand-off. Returns the receipt as it now is.
export async function reconcileReceipt(d: Deps, rec: Receipt): Promise<Receipt> {
  const u = upl(rec);
  const stuckReading = rec.status === "reading" && u.dispatch !== undefined;
  const failedDispatch = rec.status === "error" && u.dispatch === "failed";
  if (!stuckReading && !failedDispatch) return rec;
  if (stuckReading) {
    const q = await d.queueRow(rec.source_id);
    if (q.error || q.data) return rec;   // the reader has it (or we can't tell): leave it
  }
  await redispatch(d, rec);
  const cur = await d.getReceipt(rec.id);
  return cur.data ?? rec;
}
