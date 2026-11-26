// delivery-app auth helpers (26 Nov 2026). Pure and dependency-free so they can be tested from the repo
// (node --experimental-strip-types). Rules:
//  * A malformed or wrong key is a genuine 401.
//  * A config read that errors, or returns no value, is NOT an invalid key: it raises ConfigUnavailable,
//    which the handler turns into a fail-closed 503 (no access granted, nothing cached).
//  * Only successful, non-empty reads are cached (60 s). Concurrent reads of the same key share one request.
//  * Nothing here retries or bypasses the key check.

export class ConfigUnavailable extends Error {
  key: string;
  constructor(key: string, cause?: unknown) {
    super(`config "${key}" unavailable`);
    this.name = "ConfigUnavailable";
    this.key = key;
    (this as { cause?: unknown }).cause = cause;
  }
}

export type ConfigRead = (key: string) => Promise<{ value: string | null | undefined; error: unknown }>;

export function makeCfg(read: ConfigRead, opts: { ttlMs?: number; now?: () => number } = {}) {
  const ttl = opts.ttlMs ?? 60000;
  const now = opts.now ?? (() => Date.now());
  const cache = new Map<string, { v: string; at: number }>();
  const inflight = new Map<string, Promise<string>>();
  return function cfg(key: string): Promise<string> {
    const c = cache.get(key);
    if (c && now() - c.at < ttl) return Promise.resolve(c.v);
    const pending = inflight.get(key);
    if (pending) return pending;
    const p = (async () => {
      let res: { value: string | null | undefined; error: unknown };
      try { res = await read(key); } catch (e) { throw new ConfigUnavailable(key, e); }
      if (res.error) throw new ConfigUnavailable(key, res.error);
      const v = typeof res.value === "string" ? res.value : "";
      if (!v) throw new ConfigUnavailable(key, "empty");
      cache.set(key, { v, at: now() });
      return v;
    })();
    inflight.set(key, p);
    p.then(() => inflight.delete(key), () => inflight.delete(key));
    return p;
  };
}

export function constantTimeEq(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

const KEY_RE = /^[0-9a-f]{48}$/;

// Returns { device, owner }. Throws ConfigUnavailable (=> 503) only when a well-formed key had to be checked
// and the stored key could not be read. Malformed keys never touch config and are simply not authorised.
export async function whoFromHeaders(headers: { get(name: string): string | null }, cfg: (k: string) => Promise<string>) {
  const dk = headers.get("x-device-key") ?? "", ok = headers.get("x-owner-key") ?? "";
  let owner = false;
  if (KEY_RE.test(ok)) owner = constantTimeEq(ok, await cfg("delivery_owner_key"));
  let device = owner;
  if (!device && KEY_RE.test(dk)) device = constantTimeEq(dk, await cfg("delivery_device_key"));
  return { device, owner };
}
