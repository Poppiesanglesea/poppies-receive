// Shelf-tag confirm for the delivery app (v17). Two database calls = two transactions: delivery_tag_claim commits the
// claim, its audit rows and the operation keys before delivery_tag_apply makes any register write (staged pricing_03).
// Falls back to the single legacy call ONLY when the database verifiably has no claim function (pricing_03 not yet
// applied). Any other failure is returned as a retryable error; a committed claim is preserved and expires after two
// minutes, after which a retry reads the register first and never writes twice.
export type RpcErr = { code?: string; message?: string } | null;
export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: any; error: RpcErr }>;
type Out = { status: number; body: Record<string, unknown> };

export function missingClaimFunction(e: RpcErr) {
  return !!e && (e.code === "PGRST202" || e.code === "42883") && /delivery_tag_claim/.test(e.message ?? "");
}
const RETRY = "The register update didn't finish. Wait two minutes, then tap again — it won't be changed twice.";

export async function confirmTag(rpc: Rpc, taskId: number, by: string): Promise<Out> {
  const c = await rpc("delivery_tag_claim", { p_task_id: taskId, p_by: by });
  if (c.error) {
    if (!missingClaimFunction(c.error)) return { status: 502, body: { error: RETRY, status: "busy", retry: true } };
    const t = await rpc("delivery_task_tick", { p_task_id: taskId, p_by: by });   // database without pricing_03
    if (t.error) return { status: 500, body: { error: t.error.message ?? "Couldn't save. Try again." } };
    return { status: t.data?.ok ? 200 : 400, body: t.data ?? {} };
  }
  if (c.data?.phase !== "apply") return { status: c.data?.ok ? 200 : 400, body: c.data ?? {} };
  const a = await rpc("delivery_tag_apply", { p_task_id: taskId, p_token: c.data.token, p_by: by });
  if (a.error) return { status: 502, body: { error: RETRY, status: "busy", retry: true } };
  return { status: a.data?.ok ? 200 : 400, body: a.data ?? {} };
}
