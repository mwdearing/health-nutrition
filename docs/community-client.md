# Community client

The community client is the app's side of the shared label catalog: sign-in, the account profile and the catalog calls. It lives in `ios/NutritionCore/Sources/NutritionProviders/Community/` and is used by the Account section of Settings. The app uses it for sending saved labels and for the barcode fallback; see [the community catalog in the app](community-catalog-app.md).

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
- `CommunityLabelSubmission`, `CommunityLabel`, `CommunityBasis`, `CommunityVerificationSource`, `CommunitySubmitResult`, `CommunityProfile`.
- `CommunityError`: the failure cases the app handles.

Logs and error text never carry a token, key, code or email. The error cases hold no text, and transport errors are dropped instead of being wrapped.

## Auth endpoints

| Call | Request |
| --- | --- |
| `signInWithApple(idToken:nonce:)` | POST `/auth/v1/token?grant_type=id_token` with `provider: "apple"`, `id_token`, `nonce` |
| `requestEmailCode(email:)` | POST `/auth/v1/otp` with `email` and `create_user: true` |
| `verifyEmailCode(email:code:)` | POST `/auth/v1/verify` with `type: "email"`, `email`, `token` |
| `validSession()` | POST `/auth/v1/token?grant_type=refresh_token` when the access token has less than 60 seconds left |
| `signOut()` | POST `/auth/v1/logout?scope=local`, best effort for the current server session |

Sign-in and renewal store the new session. A renewal rejected with 400, 401 or 403 clears the matching stored session and throws `signedOut`; an older renewal cannot clear a replacement session. A storage-read or clear failure is reported as `storage`; an unreadable stored session is not cleared. A network failure during renewal keeps the session. Concurrent callers share one renewal, because the refresh token rotates. `signOut()` clears the local session before its best-effort server call. If local storage cannot be cleared, it reports a storage error and skips the server call. A server-call failure does not restore local credentials; the logout asks the server to end only this device's session.

## Account and catalog endpoints

Every call first gets a valid session from `validSession()`, so a signed-out call throws `signedOut` without a request. Authenticated calls send `Authorization: Bearer <access token>`.

| Call | Request |
| --- | --- |
| `profile()` | GET `/rest/v1/profiles` for the signed-in user's row. A missing row reads as no name and sharing on. |
| `updateProfile(displayName:shareLabels:)` | PATCH `/rest/v1/profiles` for the user's row with `Prefer: return=representation`. A cleared name is sent as null. |
| `deleteAccount()` | POST `/rest/v1/rpc/delete_my_account`. The local session is cleared only after the server accepts. |
| `submitLabel(_:)` | POST `/rest/v1/rpc/submit_label` with `p_barcode`, `p_basis`, `p_serving_text`, `p_product_name`, `p_brand`, `p_nutrients`. The decoder accepts `received`, `shared` and the legacy `verified` reply for compatibility; community agreement must not produce a `verified` reply. |
| `lookupLabel(barcode:)` | POST `/rest/v1/rpc/lookup_label_v2` with `p_barcode`. Returns each label with an explicit `verificationSource` (`community` or `owner_reviewed`), plus compatibility `verified` and `supportingAccounts` values. |

The versioned lookup requires `verification_source`. A missing or unknown value makes the reply fail decoding; the client never guesses a source from the legacy `verified` boolean. It normalizes community rows to `verified == false`, even if a reply carries a stale true bit. Owner-reviewed rows use the explicit source, set the compatibility `verified` value to true, and expose zero supporting accounts so the UI cannot present a contributor count for an owner-maintained snapshot.

Community agreement is not verification. The five-account threshold is not a verification signal; only an explicit owner-reviewed source receives owner-review wording. Owner review describes the review action, not nutrition or medical accuracy. This documents the source-aware API expected by the app and does not assert that a hosted migration has been applied.

Basis values are the catalog's own: `per_100g`, `per_100ml`, `per_serving`. Nutrient keys are `energyKcal`, `protein`, `carbohydrates`, `sugars`, `fat`, `saturatedFat`, `fiber`, `sodium`, `salt`. Energy is kcal, sodium is mg, the rest are grams.

## Error mapping

A PostgREST error body with an SQLSTATE `code` wins over the HTTP status:

| Code | Error |
| --- | --- |
| `28000` | `signedOut` |
| `42501` | `sharingOff` |
| `22023` | `invalid` |
| `53400` | `rateLimited` |

Without a known code, the status maps as follows: 400 and 422 to `invalid`, 401 to `unauthorized`, 403 to `permissionDenied`, 429 to `rateLimited`, anything else to `server(status)`. A request that gets no reply throws `network`. A reply that does not decode throws `server(status)`. A session that cannot be written to the Keychain throws `storage`.

## Settings and wiring

- The Account section in Settings, the sign-in sheet and the first-run sharing disclosure are built on the `AccountViewModel` seam (`CommunityAccountServicing`). See [accounts](accounts.md) for what a person sees and what is shared.
- The app target builds the client with `CommunityClient.make(infoDictionary:store:)` and the Keychain store. When that throws, no account model exists and the section is not shown.
- The Sign in with Apple entitlement is in `HealthNutrition.entitlements`. `Support/Info.plist` reads the two keys from the build settings `SUPABASE_URL` and `SUPABASE_ANON_KEY`, which are empty in the repository. The signed-beta workflow passes them from environment secrets, all or nothing.
- The one request the sign-in service protects, asking for an emailed code (`/auth/v1/otp`), carries a challenge token in `gotrue_meta_security.captcha_token` when a `CommunityCaptcha` provider is set. Each request asks the provider for a fresh token, because a token is single use. Checking the code, the Apple identity-token grant, refresh and logout carry none (the service does not ask for one there). Without a provider the bodies are unchanged.
- A failed or cancelled challenge throws `captcha` before anything is sent. A `captcha_failed` error from the server (GoTrue's `error_code`) also maps to `captcha`.
- The app target links the hCaptcha SDK, pinned to exactly `3.1.0` in `project.yml` and linked by the app target only. The package's RxSwift dependency is resolved but not linked. The site key is the build setting `HCAPTCHA_SITE_KEY` (empty in the repository, read from Info.plist), passed by the signed-beta workflow from the optional environment secret of the same name. With no key, no provider is created.
- A build setting value written as `https://...` in an xcconfig file must escape the `//`, because xcconfig reads `//` as a comment. The values in `project.yml` and on the `xcodebuild` command line are not read as xcconfig.

## Validation limits

- The legacy scanned-label upload still has no retry queue; custom-product delivery has its own durable queue.
- The Keychain implementation requires Apple Security. Portable provider tests do not validate actual Keychain behavior.
- Actual Apple package compilation, simulator tests/captures and Release builds remain required on the integrated source.

## Shared products v2

The additive custom-product API provides nine RPCs: `catalog_capabilities_v2`, `acknowledge_catalog_consent_v2`, `submit_catalog_product_v2`, `withdraw_catalog_product_v2`, `get_my_catalog_contribution_v2`, `get_catalog_product_v2`, `search_catalog_products_v2`, `resolve_catalog_publish_for_withdrawal_v2`, and `get_catalog_product_alternatives_v2`. Publication resolution resolves a possibly committed publication or installs a durable cancellation fence without publishing it. The exact request envelope remains immutable across retries.

Authenticated writes and owner-state reads check the expected account before token refresh, check the refreshed account before saving credentials, and check ownership again after refresh. Both legacy and v2 requests invalidate only the matching access token on HTTP 401 or HTTP 403 with SQLSTATE `28000`. Ordinary permission/consent failures, including typed v2 authorization errors, retain credentials. Replacement sign-in intent survives a rejection of the older token in either response order. Logout clears local credentials first and uses server scope `local`; storage failures remain errors and leave delivery paused.

The Community transport uses [bounded response loading](providers/response-limits.md). Cancellation remains distinct from network failures. See the [shared-products design](superpowers/specs/2026-10-11-shared-custom-products-design.md) for consent, durable delivery, explicit review and release gates.


Fresh sharing/discovery requires `bounded_publication_version:1`. Search and authenticated alternatives pages expose explicit continuation; the 1 MiB client cap remains unchanged. Exact attempted publications, withdrawal and resolution remain recoverable when fresh publication is unavailable. Discovery opens a read-only facts inspector before deliberate Save. It shows each legacy alternative's source/review independently; absent review metadata on a custom alternative is labeled as unavailable evidence.

Eligible new creation captures current account/profile/consent/session, coordinator admission and concrete store state synchronously at Save, then saves its publication in the same local transaction. Imported items, selected historical repairs, later edits and unconsented creation stay local until explicit review; later sign-in never backfills them. A selected snapshot-less historical food/supplement template stages only its known name. Existing consumed component amounts are read-only references, not invented label facts; kind, basis and required serving remain explicit choices.
