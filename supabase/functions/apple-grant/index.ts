// Edge Function entry. Secrets come from the function's environment (set with `supabase secrets set`).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { handle } from "./handler.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

Deno.serve((request) =>
  handle(request, {
    config: {
      teamId: Deno.env.get("APPLE_TEAM_ID"),
      clientId: Deno.env.get("APPLE_CLIENT_ID"),
      keyId: Deno.env.get("APPLE_KEY_ID"),
      privateKey: Deno.env.get("APPLE_PRIVATE_KEY"),
    },
    fetch,
    nowSeconds: () => Math.floor(Date.now() / 1000),
    authenticate: async (token) => {
      const { data, error } = await admin.auth.getUser(token);
      return error || !data.user ? null : data.user.id;
    },
    store: {
      async put(userId, refreshToken) {
        const { error } = await admin.from("apple_grants").upsert({ user_id: userId, refresh_token: refreshToken });
        if (error) throw new Error("store_failed");
      },
      async get(userId) {
        const { data, error } = await admin.from("apple_grants").select("refresh_token").eq("user_id", userId).maybeSingle();
        if (error) throw new Error("store_failed");
        return data?.refresh_token ?? null;
      },
      async remove(userId) {
        const { error } = await admin.from("apple_grants").delete().eq("user_id", userId);
        if (error) throw new Error("store_failed");
      },
    },
  })
);
