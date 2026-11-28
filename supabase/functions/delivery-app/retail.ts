// Retail waiting lines (v18, 28 Nov 2026; rev 2 after Codex review). Contract: docs/retail-lines-contract.md.
// GET /retail-lines and search are read-only. A transport error or a thrown call does NOT prove the database rolled
// back (the commit may have happened and only the reply was lost), so it is reported as "uncertain": the client re-sends
// the same op_id, and the database replays the stored result instead of acting twice.
// Pure routing/validation with an injected rpc so it can be tested without Supabase (test/retail-lines-edge.test.mjs).
// The database function delivery_retail_answer is the only writer and the authority on every check; this layer only
// rejects malformed requests early and maps the database's {http, body} to the response.
export type RpcErr = { code?: string; message?: string } | null;
export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: any; error: RpcErr }>;
type Out = { status: number; body: unknown };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const RETAIL_ROUTE = /^\/retail-lines(?:\/(\d{1,12})\/(search|existing|new|josh))?$/;
export const RETAIL_OWNER_ROUTE = /^\/owner\/retail-lines\/(\d{1,12})\/promote$/;
export const UNCERTAIN = { ok: false, code: "uncertain", retry: true,
  error: "The app couldn't confirm whether this was saved. Tap Save again — it won't be saved twice." };

async function call(rpc: Rpc, fn: string, args: Record<string, unknown>): Promise<{ data: any; error: RpcErr }> {
  try { return await rpc(fn, args); } catch (e) { return { data: null, error: { message: String((e as Error)?.message ?? e) } }; }
}
const mapped = (data: any): Out => {
  const status = Number(data?.http);
  return { status: [200, 400, 404, 409].includes(status) ? status : 500, body: data?.body ?? { error: "unexpected reply" } };
};

// Owner-only: approve creating a product that was planned while new-stock set-up was in test mode.
export async function retailOwnerRoute(rpc: Rpc, method: string, path: string, readBody: () => Promise<unknown>): Promise<Out | null> {
  const m = path.match(RETAIL_OWNER_ROUTE);
  if (!m) return null;
  if (method !== "POST") return { status: 405, body: { error: "POST only" } };
  const b = await readBody().catch(() => null) as Record<string, unknown> | null;
  const op = b && typeof b.op_id === "string" && UUID.test(b.op_id) ? b.op_id.toLowerCase() : null;
  if (!op) return { status: 400, body: { ok: false, code: "invalid", error: "Missing op_id." } };
  const { data, error } = await call(rpc, "delivery_retail_promote", { p_unmatched_id: Number(m[1]), p_op_id: op, p_by: "Josh" });
  if (error) return { status: 503, body: UNCERTAIN };
  return mapped(data);
}

export async function retailRoute(rpc: Rpc, method: string, path: string, url: URL, readBody: () => Promise<unknown>,
                                  staff: () => Promise<string[]>, owner: boolean): Promise<Out | null> {
  const m = path.match(RETAIL_ROUTE);
  if (!m) return null;
  if (!m[1]) {
    if (method !== "GET") return { status: 405, body: { error: "GET only" } };
    const { data, error } = await call(rpc, "delivery_retail_lines_list", {});
    if (error) return { status: 500, body: { error: "Couldn't load waiting invoice lines." } };
    return { status: 200, body: { owner, staff: await staff(), new_stock_mode: data?.new_stock_mode ?? "dry_run", cards: data?.cards ?? [] } };
  }
  const id = Number(m[1]);
  if (m[2] === "search") {
    if (method !== "GET") return { status: 405, body: { error: "GET only" } };
    const q = (url.searchParams.get("q") ?? "").slice(0, 60);
    const { data, error } = await call(rpc, "delivery_retail_search", { p_unmatched_id: id, p_q: q });
    if (error) return { status: 500, body: { error: "Search isn't working right now." } };
    if (data === null || data === undefined) return { status: 404, body: { ok: false, code: "not_found", error: "This line is not a retail waiting line." } };
    return { status: 200, body: Array.isArray(data) ? data : [] };
  }
  if (method !== "POST") return { status: 405, body: { error: "POST only" } };
  const b = await readBody().catch(() => null);
  if (!b || typeof b !== "object" || Array.isArray(b)) return { status: 400, body: { ok: false, code: "invalid", error: "Bad request." } };
  const body = b as Record<string, unknown>;
  const op = typeof body.op_id === "string" && UUID.test(body.op_id) ? body.op_id.toLowerCase() : null;
  if (!op) return { status: 400, body: { ok: false, code: "invalid", error: "Missing op_id." } };
  const by = String(body.by ?? "").trim().slice(0, 40);
  if (!(await staff()).includes(by)) return { status: 400, body: { ok: false, code: "invalid", error: "Pick your name first." } };
  if (JSON.stringify(body).length > 4000) return { status: 400, body: { ok: false, code: "invalid", error: "Too much text." } };
  // Malformed numbers are a definite 400 here (28 Nov review): passed on, a fraction made the database cast raise, which
  // looked like an uncertain save and asked staff to retry the same request forever.
  if (m[2] === "existing" && !(Number.isSafeInteger(body.stock_item_id) && (body.stock_item_id as number) > 0)) {
    return { status: 400, body: { ok: false, code: "invalid", error: "Pick the product." } };
  }
  const { data, error } = await call(rpc, "delivery_retail_answer", { p_unmatched_id: id, p_action: m[2], p_body: body, p_op_id: op, p_by: by });
  // No reply (or an error reply) does not prove nothing was saved: report it as uncertain; re-sending the same op_id is safe.
  if (error) return { status: 503, body: UNCERTAIN };
  return mapped(data);
}
