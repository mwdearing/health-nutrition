import { assert, assertEquals } from "jsr:@std/assert@1";
import { AppleConfig, Deps, GrantStore, handle } from "./handler.ts";

const keyPair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
const config: AppleConfig = { teamId: "TEAM123456", clientId: "com.example.app", keyId: "KEY1234567", privateKey: pem };

class MemoryStore implements GrantStore {
  rows = new Map<string, string>();
  put(u: string, t: string) { this.rows.set(u, t); return Promise.resolve(); }
  get(u: string) { return Promise.resolve(this.rows.get(u) ?? null); }
  remove(u: string) { this.rows.delete(u); return Promise.resolve(); }
}

interface Call { url: string; form: URLSearchParams }

function setup(opts: { config?: Partial<AppleConfig>; apple?: () => Response } = {}) {
  const calls: Call[] = [];
  const store = new MemoryStore();
  const deps: Deps = {
    config: opts.config ?? config,
    fetch: ((url: string, init: RequestInit) => {
      calls.push({ url, form: new URLSearchParams(init.body as URLSearchParams) });
      return Promise.resolve(opts.apple ? opts.apple() : new Response(JSON.stringify({ refresh_token: "rt-1" })));
    }) as unknown as typeof fetch,
    nowSeconds: () => 1_000_000,
    authenticate: (t) => Promise.resolve(t === "good" ? "user-1" : null),
    store,
  };
  return { calls, store, deps };
}

const post = (body: unknown, token = "good") =>
  new Request("https://x/apple-grant", {
    method: "POST",
    headers: { authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });

Deno.test("rejects a request without a valid session", async () => {
  const { deps, calls } = setup();
  assertEquals((await handle(post({ action: "revoke" }, "bad"), deps)).status, 401);
  assertEquals(calls.length, 0);
});

Deno.test("store exchanges the code and keeps the refresh token for the signed-in user", async () => {
  const { deps, calls, store } = setup();
  const reply = await handle(post({ action: "store", authorization_code: "code-9" }), deps);
  assertEquals(reply.status, 200);
  assertEquals(calls[0].url, "https://appleid.apple.com/auth/token");
  assertEquals(calls[0].form.get("grant_type"), "authorization_code");
  assertEquals(calls[0].form.get("code"), "code-9");
  assertEquals(calls[0].form.get("client_id"), "com.example.app");
  assertEquals(store.rows.get("user-1"), "rt-1");
});

Deno.test("client secret is an ES256 JWT with Apple's claims and a valid signature", async () => {
  const { deps, calls } = setup();
  await handle(post({ action: "store", authorization_code: "c" }), deps);
  const [h, c, s] = calls[0].form.get("client_secret")!.split(".");
  const dec = (x: string) => JSON.parse(atob(x.replace(/-/g, "+").replace(/_/g, "/")));
  assertEquals(dec(h), { alg: "ES256", kid: "KEY1234567", typ: "JWT" });
  assertEquals(dec(c), { iss: "TEAM123456", iat: 1_000_000, exp: 1_000_300, aud: "https://appleid.apple.com", sub: "com.example.app" });
  const sig = Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (ch) => ch.charCodeAt(0));
  assert(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, keyPair.publicKey, sig, new TextEncoder().encode(`${h}.${c}`)));
});

Deno.test("store without the Apple key set up does nothing and does not fail sign-in", async () => {
  const { deps, calls, store } = setup({ config: {} });
  const reply = await handle(post({ action: "store", authorization_code: "c" }), deps);
  assertEquals(reply.status, 200);
  assertEquals(await reply.json(), { stored: false, reason: "not_configured" });
  assertEquals(calls.length, 0);
  assertEquals(store.rows.size, 0);
});

Deno.test("revoke calls Apple's revoke endpoint with the stored token, then forgets it", async () => {
  const { deps, calls, store } = setup();
  store.rows.set("user-1", "rt-1");
  const reply = await handle(post({ action: "revoke" }), deps);
  assertEquals(reply.status, 200);
  assertEquals(await reply.json(), { revoked: true });
  assertEquals(calls[0].url, "https://appleid.apple.com/auth/revoke");
  assertEquals(calls[0].form.get("token"), "rt-1");
  assertEquals(calls[0].form.get("token_type_hint"), "refresh_token");
  assertEquals(store.rows.size, 0);
});

Deno.test("revoke for a user with no Apple grant succeeds without calling Apple", async () => {
  const { deps, calls } = setup();
  const reply = await handle(post({ action: "revoke" }), deps);
  assertEquals(reply.status, 200);
  assertEquals(await reply.json(), { revoked: false, reason: "no_grant" });
  assertEquals(calls.length, 0);
});

Deno.test("revoke only touches the caller's own grant", async () => {
  const { deps, calls, store } = setup();
  store.rows.set("someone-else", "rt-other");
  await handle(post({ action: "revoke" }), deps);
  assertEquals(calls.length, 0);
  assertEquals(store.rows.get("someone-else"), "rt-other");
});

Deno.test("a failed Apple revoke keeps the token and fails, so deletion can be retried", async () => {
  const { deps, store } = setup({ apple: () => new Response("{}", { status: 400 }) });
  store.rows.set("user-1", "rt-1");
  assertEquals((await handle(post({ action: "revoke" }), deps)).status, 502);
  assertEquals(store.rows.get("user-1"), "rt-1");
});

Deno.test("revoke with a stored grant but no key refuses instead of skipping", async () => {
  const { deps, store } = setup({ config: {} });
  store.rows.set("user-1", "rt-1");
  assertEquals((await handle(post({ action: "revoke" }), deps)).status, 503);
  assertEquals(store.rows.get("user-1"), "rt-1");
});

Deno.test("revoke treats Apple's invalid_grant as already revoked", async () => {
  const { deps, store } = setup({ apple: () => new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 }) });
  store.rows.set("user-1", "rt-1");
  const reply = await handle(post({ action: "revoke" }), deps);
  assertEquals(reply.status, 200);
  assertEquals(store.rows.size, 0);
});

Deno.test("a failure forgetting the token after a successful revoke does not block deletion", async () => {
  const { deps, store } = setup();
  store.rows.set("user-1", "rt-1");
  deps.store = { ...store, get: (u) => store.get(u), put: (u, t) => store.put(u, t), remove: () => Promise.reject(new Error("x")) };
  assertEquals((await handle(post({ action: "revoke" }), deps)).status, 200);
});

Deno.test("store fails cleanly when Apple rejects the code or returns no refresh token", async () => {
  for (const apple of [() => new Response("{}", { status: 400 }), () => new Response("{}")]) {
    const { deps, store } = setup({ apple });
    assertEquals((await handle(post({ action: "store", authorization_code: "c" }), deps)).status, 502);
    assertEquals(store.rows.size, 0);
  }
});

Deno.test("a null JSON body is a bad request, not a crash", async () => {
  const { deps } = setup();
  assertEquals((await handle(post(null), deps)).status, 400);
});

Deno.test("a thrown fetch or store error becomes a structured 502", async () => {
  const { deps, store } = setup();
  store.rows.set("user-1", "rt-1");
  deps.fetch = (() => Promise.reject(new Error("timeout"))) as unknown as typeof fetch;
  const reply = await handle(post({ action: "revoke" }), deps);
  assertEquals(reply.status, 502);
  assertEquals(await reply.json(), { error: "upstream_failed" });
  assertEquals(store.rows.get("user-1"), "rt-1");
});
