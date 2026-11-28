// Retail waiting lines (v18, 28 Nov 2026). Contract: docs/retail-lines-contract.md.
// Pure routing/validation with an injected rpc so it can be tested without Supabase (test/retail-lines-edge.test.mjs).
// The database function delivery_retail_answer is the only writer and the authority on every check; this layer only
// rejects malformed requests early and maps the database's {http, body} to the response.
export type RpcErr = { code?: string; message?: string } | null;
export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: any; error: RpcErr }>;
type Out = { status: number; body: unknown };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const RETAIL_ROUTE = /^\/retail-lines(?:\/(\d{1,12})\/(search|existing|new|josh))?$/;

export async function retailRoute(rpc: Rpc, method: string, path: string, url: URL, readBody: () => Promise<unknown>,
                                  staff: () => Promise<string[]>, owner: boolean): Promise<Out | null> {
  const m = path.match(RETAIL_ROUTE);
  if (!m) return null;
  if (!m[1]) {
    if (method !== "GET") return { status: 405, body: { error: "GET only" } };
    const { data, error } = await rpc("delivery_retail_lines_list", {});
    if (error) return { status: 500, body: { error: "Couldn't load waiting invoice lines." } };
    return { status: 200, body: { owner, staff: await staff(), new_stock_mode: data?.new_stock_mode ?? "dry_run", cards: data?.cards ?? [] } };
  }
  const id = Number(m[1]);
  if (m[2] === "search") {
    if (method !== "GET") return { status: 405, body: { error: "GET only" } };
    const q = (url.searchParams.get("q") ?? "").slice(0, 60);
    const { data, error } = await rpc("delivery_retail_search", { p_unmatched_id: id, p_q: q });
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
  const { data, error } = await rpc("delivery_retail_answer", { p_unmatched_id: id, p_action: m[2], p_body: body, p_op_id: op, p_by: by });
  // An error here means the database transaction did not commit: nothing was saved and the same op_id can be re-sent.
  if (error) return { status: 500, body: { ok: false, code: "retry", error: "Couldn't save. Nothing was changed — try again." } };
  const status = Number(data?.http);
  return { status: [200, 400, 404, 409].includes(status) ? status : 500, body: data?.body ?? { error: "unexpected reply" } };
}
