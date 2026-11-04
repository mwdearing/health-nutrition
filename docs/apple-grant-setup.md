# Sign in with Apple: revoking the grant on account deletion

App Store guideline 5.1.1(v) needs the Sign in with Apple grant revoked when an account is deleted.
The Edge Function `supabase/functions/apple-grant` does it; the Apple key lives only in the function's secrets.

## One-time setup (owner)

1. Apple Developer portal > Certificates, Identifiers & Profiles > Keys > +. Name it, tick **Sign in with Apple**,
   Configure > pick this app's primary App ID, Save, Continue, Register. Download the `.p8` once (Apple will not show it again).
   Note the **Key ID** (10 characters) and your **Team ID** (Membership page).
2. Set the function secrets (the shell reads the key file; nothing is printed):

```
supabase secrets set --project-ref <ref> \
  APPLE_TEAM_ID=<team id> \
  APPLE_KEY_ID=<key id> \
  APPLE_CLIENT_ID=<app bundle id> \
  APPLE_PRIVATE_KEY="$(cat /path/to/AuthKey_<key id>.p8)"
```

3. Deploy the table and the function (the function needs no secret to deploy; deploy it before shipping the app, since
   account deletion calls it):

```
supabase db push --project-ref <ref>
supabase functions deploy apple-grant --project-ref <ref>
```

Never run `supabase config push`. Do not commit the `.p8`.

## Behavior

- Sign in: the app sends Apple's authorization code; the function exchanges it for a refresh token and keeps it in
  `public.apple_grants` (service role only, no client access).
- Delete account: the app calls the function first. With a stored grant it calls Apple's revoke endpoint and forgets the
  token; with none (email sign-in) it returns at once. A failed revoke stops the deletion so it can be retried.
- Until the secrets are set, sign-in works and nothing is stored, so accounts created before the key is configured have no
  grant to revoke server-side. The person can still remove the app under Settings > Apple ID > Sign in with Apple.

## Tests

`cd supabase/functions/apple-grant && deno test --no-check handler_test.ts`
