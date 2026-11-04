// Sign in with Apple grant handling: keep the refresh token server-side at sign-in, and revoke it at
// account deletion. All I/O is injected so tests run against doubles. Never logs tokens or keys.

export interface AppleConfig {
  teamId: string;
  clientId: string;
  keyId: string;
  privateKey: string; // PEM contents of the .p8 key
}

export interface GrantStore {
  put(userId: string, refreshToken: string): Promise<void>;
  get(userId: string): Promise<string | null>;
  remove(userId: string): Promise<void>;
}

export interface Deps {
  config: Partial<AppleConfig>;
  fetch: typeof fetch;
  nowSeconds: () => number;
  /** Returns the user id for a valid access token, or null. */
  authenticate: (accessToken: string) => Promise<string | null>;
  store: GrantStore;
}

const APPLE = "https://appleid.apple.com";

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function b64url(bytes: Uint8Array | string): string {
  const data = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let s = "";
  for (const b of data) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

/** Apple's client secret: an ES256 JWT signed with the Sign in with Apple key, valid for 5 minutes. */
export async function clientSecret(config: AppleConfig, nowSeconds: number): Promise<string> {
  const header = b64url(JSON.stringify({ alg: "ES256", kid: config.keyId, typ: "JWT" }));
  const claims = b64url(JSON.stringify({
    iss: config.teamId,
    iat: nowSeconds,
    exp: nowSeconds + 300,
    aud: APPLE,
    sub: config.clientId,
  }));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(config.privateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`)),
  );
  return `${header}.${claims}.${b64url(signature)}`;
}

function configured(c: Partial<AppleConfig>): c is AppleConfig {
  return Boolean(c.teamId && c.clientId && c.keyId && c.privateKey);
}

async function appleForm(deps: Deps, config: AppleConfig, path: string, fields: Record<string, string>) {
  const secret = await clientSecret(config, deps.nowSeconds());
  const body = new URLSearchParams({ client_id: config.clientId, client_secret: secret, ...fields });
  return deps.fetch(`${APPLE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
    signal: AbortSignal.timeout(10_000),
  });
}

/** Apple answers invalid_grant for a token that is already revoked or expired: nothing is left to revoke. */
async function alreadyRevoked(reply: Response): Promise<boolean> {
  if (reply.status !== 400) return false;
  const body = await reply.json().catch(() => null);
  return body?.error === "invalid_grant";
}

export async function handle(request: Request, deps: Deps): Promise<Response> {
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" });
  const bearer = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  const userId = bearer ? await deps.authenticate(bearer) : null;
  if (!userId) return json(401, { error: "unauthorized" });

  let payload: { action?: string; authorization_code?: string };
  try {
    payload = await request.json();
  } catch {
    return json(400, { error: "bad_request" });
  }
  if (payload === null || typeof payload !== "object") return json(400, { error: "bad_request" });

  if (payload.action === "store") {
    const code = payload.authorization_code;
    if (!code || typeof code !== "string") return json(400, { error: "bad_request" });
    // Key not set up yet: nothing can be exchanged, and the sign-in itself is unaffected.
    if (!configured(deps.config)) return json(200, { stored: false, reason: "not_configured" });
    const reply = await appleForm(deps, deps.config, "/auth/token", { code, grant_type: "authorization_code" });
    if (!reply.ok) return json(502, { error: "apple_exchange_failed" });
    const token = (await reply.json().catch(() => ({})))?.refresh_token;
    if (typeof token !== "string" || !token) return json(502, { error: "apple_exchange_failed" });
    await deps.store.put(userId, token);
    return json(200, { stored: true });
  }

  if (payload.action === "revoke") {
    const token = await deps.store.get(userId);
    if (!token) return json(200, { revoked: false, reason: "no_grant" });
    // A grant exists but the key is gone: refuse, so deletion cannot silently leave the grant connected.
    if (!configured(deps.config)) return json(503, { error: "not_configured" });
    const reply = await appleForm(deps, deps.config, "/auth/revoke", {
      token,
      token_type_hint: "refresh_token",
    });
    if (!reply.ok && !(await alreadyRevoked(reply))) return json(502, { error: "apple_revoke_failed" });
    // The grant is revoked at Apple. Forgetting the token is housekeeping (the row also goes with the user),
    // so a failure here must not block the deletion.
    await deps.store.remove(userId).catch(() => {});
    return json(200, { revoked: true });
  }

  return json(400, { error: "bad_request" });
}
