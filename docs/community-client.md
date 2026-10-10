# Community client

The community client is the app's side of the shared label catalog: sign-in, the account profile and the catalog calls. It lives in `ios/NutritionCore/Sources/NutritionProviders/Community/` and has no user interface yet. The settings screen, the sign-in sheet and the catalog integration in the app come in later changes.

## Configuration

The client reads two values from the bundle's Info.plist, filled from build settings:

- `SUPABASE_URL`: the project address. It must be `https` and its host must end in `.supabase.co`. Port and user information are rejected.
- `SUPABASE_ANON_KEY`: the public (anon) key. It is sent as the `apikey` header on every request.

Neither value is committed to the repository. The signed build supplies them from environment secrets. When either value is blank or invalid, `CommunityConfig(infoDictionary:)` returns nil and `CommunityClient.make(infoDictionary:transport:store:)` throws `CommunityError.notConfigured`. In that case no call is made, so a build without the settings has no account behavior.

Tests use a made-up project host and fake keys only.

## Types

- `CommunityConfig`: the validated project address and key.
- `CommunityTransport`: the one network seam. `URLSessionCommunityTransport` uses an ephemeral session, as the other providers do.
- `CommunitySession`: access token, refresh token, expiry, user id and email. `CommunitySessionStore` keeps it. `KeychainCommunitySessionStore` writes one generic password (service `communityaccount` by default), accessible after the first unlock on this device only. `InMemoryCommunitySessionStore` is for tests and previews.
- `CommunityAuth` (actor): sign-in, sign-out and session upkeep.
- `CommunityClient`: profile and catalog calls. It exposes `auth` for the sign-in flow.
- `CommunityLabelSubmission`, `CommunityLabel`, `CommunityBasis`, `CommunitySubmitResult`, `CommunityProfile`.
- `CommunityError`: the failure cases the app handles.

Logs and error text never carry a token, key, code or email. The error cases hold no text, and transport errors are dropped instead of being wrapped.

## Auth endpoints

| Call | Request |
| --- | --- |
| `signInWithApple(idToken:nonce:)` | POST `/auth/v1/token?grant_type=id_token` with `provider: "apple"`, `id_token`, `nonce` |
| `requestEmailCode(email:)` | POST `/auth/v1/otp` with `email` and `create_user: true` |
| `verifyEmailCode(email:code:)` | POST `/auth/v1/verify` with `type: "email"`, `email`, `token` |
| `validSession()` | POST `/auth/v1/token?grant_type=refresh_token` when the access token has less than 60 seconds left |
| `signOut()` | POST `/auth/v1/logout`, best effort |

Sign-in and renewal store the new session. A renewal rejected with 400, 401 or 403 clears the stored session and throws `signedOut`. A network failure during renewal keeps the session. Concurrent callers share one renewal, because the refresh token rotates. `signOut()` always clears the local session, even when the server call fails.

## Account and catalog endpoints

Every call first gets a valid session from `validSession()`, so a signed-out call throws `signedOut` without a request. Authenticated calls send `Authorization: Bearer <access token>`.

| Call | Request |
| --- | --- |
| `profile()` | GET `/rest/v1/profiles` for the signed-in user's row. A missing row reads as no name and sharing on. |
| `updateProfile(displayName:shareLabels:)` | PATCH `/rest/v1/profiles` for the user's row with `Prefer: return=representation`. A cleared name is sent as null. |
| `deleteAccount()` | POST `/rest/v1/rpc/delete_my_account`. The local session is cleared only after the server accepts. |
| `submitLabel(_:)` | POST `/rest/v1/rpc/submit_label` with `p_barcode`, `p_basis`, `p_serving_text`, `p_product_name`, `p_brand`, `p_nutrients`. Returns `received`, `shared` or `verified`. |
| `lookupLabel(barcode:)` | POST `/rest/v1/rpc/lookup_label` with `p_barcode`. Returns each label with `verified` and `supportingAccounts`. |

Basis values are the catalog's own: `per_100g`, `per_100ml`, `per_serving`. Nutrient keys are `energyKcal`, `protein`, `carbohydrates`, `sugars`, `fat`, `saturatedFat`, `fiber`, `sodium`, `salt`. Energy is kcal, sodium is mg, the rest are grams.

## Error mapping

A PostgREST error body with an SQLSTATE `code` wins over the HTTP status:

| Code | Error |
| --- | --- |
| `28000` | `signedOut` |
| `42501` | `sharingOff` |
| `22023` | `invalid` |
| `53400` | `rateLimited` |

Without a known code, the status maps as follows: 400 and 422 to `invalid`, 401 and 403 to `unauthorized`, 429 to `rateLimited`, anything else to `server(status)`. A request that gets no reply throws `network`. A reply that does not decode throws `server(status)`. A session that cannot be written to the Keychain throws `storage`.

## Not done yet

- No user interface: no Settings section, sign-in sheet, sharing switch or first-run disclosure. These come in the account settings change.
- No Sign in with Apple entitlement and no build settings wiring. The signed-build workflow must pass `SUPABASE_URL` and `SUPABASE_ANON_KEY`. A build setting value written as `https://...` must escape the `//`, because xcconfig reads `//` as a comment.
- No catalog integration: the label capture does not submit yet, and barcode lookup does not consult the community catalog yet.
- No privacy manifest, App Privacy or `PRIVACY.md` changes.
- The Keychain store is compiled only where Security is available. It has not been run on a device.
- The client has not been compiled or tested on this host. CI is the first build.
