# Shared custom products

Status: design approved 2026-10-11; source implementation integrated. Hosted migration, Apple validation and client release remain separate gates. This document does not claim deployment.

## Outcome

A person can save a custom food, drink or supplement and, while signed in with community sharing enabled, publish its product details to the shared catalog. A barcode is optional. Another signed-in person can find the item by name, inspect its facts, save it locally and log it. The initial contribution is discoverable as unverified; publication does not wait for a second contributor.

The original report was a custom item present on the phone but absent from the hosted database. Success requires both acknowledged cloud storage and discovery from another account. A successful local save alone must never be described as successful sharing.

Only product details are published. Consumed amount, intake time, meal, journal identifiers, notes, goals, photos and device identifiers are excluded. This feature does not sync or back up the personal journal.

## Current behavior and constraints

At the baseline for this design, the app saves intakes in SwiftData. A manually entered food has no product snapshot; manually entered drinks and supplements retain only basic identity and kind. Library products are derived from journal snapshots, deliberately exclude manual origins and disappear from that source when the relevant journal history disappears. Library search is not implemented.

The hosted catalog is organized around barcode and nutrition basis. Its upload contract requires a valid barcode and at least three standard nutrition facts. It does not represent product kind or supplement compounds. Uploads from the app require a captured label; manual entries and supplements do not qualify. Errors are currently ignored by that legacy upload path.

Removing the upload guard alone would lose facts and fail database validation. Product storage, a new contract, discovery and durable delivery are necessary.

## Approach and alternatives

Use an additive product catalog with stable UUIDs and versioned API functions, plus a local product store and durable sharing queue. Preserve the legacy barcode API for existing app versions.

Widening the current barcode tables in place would force barcode-free identity into their consensus and moderation rules and break older assumptions. Private account sync would solve a different problem: the requested products must be available to other people. Neither approach is selected.

## Product model and editing

A custom product exists independently of an intake. Persist a stable local UUID, revision identity, optional server product UUID, name, optional brand/barcode, product kind, structured nutrition basis, serving definition and structured facts. All three kinds use the same persistence path.

A product editor exposes name, brand, kind, optional barcode, basis, serving information and facts. Saving a product does not require logging consumption. Add can open the editor and then offer logging with the saved product; Library can create or edit a product directly. Intake amounts remain in intake UI and must never become an implicit product serving size.

A nonblank bounded name and explicit kind are sufficient to save and share a custom product. Missing facts are retained as missing and shown as “Nutrition details not provided.” There is no three-standard-nutrient requirement for custom products. A single-ingredient supplement is valid. A name-only contribution is unverified and cannot become verified without stated facts.

Facts preserve known amounts, known zero, unknown, not applicable and below-reporting-threshold states. Each fact has a bounded key, display name, state, optional decimal amount and approved unit. The product-level basis is per 100 g, per 100 mL or per serving; per-serving products must state their product serving definition before numeric facts can be published. Without numeric facts, a name-only product can leave its serving definition absent.

Use decimal strings in the new wire contract to avoid binary float conversion. Text bounds count Unicode scalars, and transport strings exclude NUL because PostgreSQL JSONB cannot represent it. Canonical UTF-8 request bytes determine the size bound. Initial bounds: at most 64 facts, 16 KiB serialized payload, unique fact keys of at most 64 characters, display names at most 120 characters, nonnegative finite amounts up to 1,000,000,000 with at most six fractional digits. Standard nutrient keys enforce their expected dimension. Supplement compounds accept the app's supported mass, volume, count and activity units; activity units such as IU are not converted into mass without a compound-specific conversion already supported by the domain model. Unsupported units produce an actionable validation error rather than guessed conversion.

Historical intake snapshots are immutable. Editing a product creates a new revision; previously logged entries retain the facts they used. Library custom products remain available even if all corresponding intakes are removed.

## Shared identity, revisions and verification

Each shared product has a server UUID. A barcode-free new product receives a new identity. Never merge products by name alone. Search lets the person deliberately select an existing product. Selecting or logging that result does not submit a new contribution or count as agreement.

Canonical valid barcodes resolve atomically to a product identity, preserving UPC-A/leading-zero EAN-13 equivalence. A conflicting barcode/kind or incompatible product identity returns a conflict requiring review; it cannot silently overwrite a different product. Product facts and basis belong to contributions/revisions, not a unique barcode record.

A stable operation UUID and immutable client revision UUID identify delivery. The server assigns contribution sequence numbers. An edit carries its expected server revision; a compare-and-swap check rejects stale edits, including two devices editing the same revision. The app shows a conflict and requires deliberate review, never automatic overwrite or rebasing. Replaying an operation with the same body returns its acknowledgment together with the current publication/retirement state. Reusing the operation UUID with a different body is rejected. One account can contribute at most once to a particular fact set's support count, regardless of retries or devices.

The first valid active contribution is searchable as “Shared, not yet verified.” Verification is separate and requires explicit catalog-owner review of the exact facts. Community agreement never grants verification, regardless of account count. Configured distinct-account thresholds continue to govern legacy visibility/support, not verification. For custom products, count only explicit contributions with equivalent complete facts and the same product identity, kind, basis, serving definition and units after supported normalization. Mere search/import/repeat is not an attestation. Conflicting fact sets remain separate alternatives and are never averaged into a fabricated supplement label. A deterministic representative is selected from actual active contributions: greatest support, then earliest accepted contribution ID. Corrections submit a new contribution revision and recompute the representative. The displayed support count belongs to that representative, not all conflicting submissions combined.

## Hosted storage and API

Add a private, nonexposed catalog schema with:

- Products: UUID, kind, moderation state and creation metadata.
- Barcode bindings: canonical barcode to product UUID, with transactional uniqueness.
- Contributions: authenticated owner, product UUID, revision, content hash and product-only facts.
- Request receipts and retirement tombstones: owner and operation UUID, client revision UUID, server sequence, expected revision, payload hash and acknowledgment. Retain these after contribution withdrawal until account deletion. Retired revisions cannot be republished by replay; explicit republication requires a new operation/client revision and expected current retired server revision.
- Derived entries: public product facts, representative revision, support count and verification state.
- Rejections: product/revision moderation decisions. Server-owned only.

Expose eight versioned RPCs: capabilities, consent acknowledgment, submit, withdraw, own contribution state, product get, search, and resolve publication for withdrawal. Resolution returns the committed operation receipt with current state or durably fences an uncommitted operation; it never publishes as a recovery strategy. Clients receive product UUID, accepted revision, sharing result and public attribution, never contributor account UUIDs. Withdraw removes only the caller's contribution and recomputes visibility. A product disappears when no active contribution remains; independently supported products remain.

Publication requires a current nonanonymous authenticated account, live sharing permission and current consent. Withdrawal, consent management and account deletion require authentication/ownership but remain available while sharing is off. Private tables have RLS and no direct client grants. Security-definer functions use an empty search path, explicit account checks, bounded input and explicit grants. Existing submission limits apply across legacy and new endpoints so alternating APIs cannot bypass the daily limit. Idempotent retries do not consume another submission allowance; new product revisions do.

Search requires a signed-in account, a bounded query of 2–120 characters and bounded pagination of at most 20 products per page. Search and get omit rejected, withdrawn and unsupported entries, including on later pages. Use literal parameterized matching, deterministic ordering and indexes appropriate to the query. Public results include kind, source, verification and missing-facts state. Legacy barcode entries appear through a read adapter, using the same stable canonical-barcode-to-UUID mapping as new submissions. A legacy-only binding can exist without inventing a product kind; the new custom contribution must explicitly supply its kind. Search groups matching barcode identities into one result with attributable fact alternatives. Legacy and new representative facts retain separate support and exact owner-review evidence: do not sum their support counts or use a legacy vote with unknown kind as support for a new custom version. Repeated participation by one account cannot increase support within either calculation. A legacy badge attaches only to the exact legacy representative, never a conflicting custom fact set. Legacy rejection of a canonical barcode/basis suppresses the corresponding new fact alternatives too; new root-product rejection hides its search/get results and any bound legacy lookup result. Preserve legacy API response shapes and configured visibility thresholds while enforcing owner-only verification and shared rejection checks. Source-aware legacy lookup explicitly distinguishes community facts from an independently retained owner-reviewed snapshot. Owner approval can survive withdrawal of community support without transferring its badge to conflicting custom facts. Barcode-free re-creation of rejected content is handled through the existing moderator authority; moderation is not an assertion that every similar name has the same identity.

Extend the existing delete_my_account function itself so deletion from old and new clients removes the account's legacy and new contributions, receipts, retirement tombstones and consent state, then recomputes affected entries transactionally. Publication and deletion acquire the same account/profile lock order and recheck account existence under that lock; a stale token or in-flight request cannot recreate data after deletion. Moderation hides rejected content immediately from both search and get. Published data is not physically destroyed by ordinary client withdrawal if needed for moderation/idempotency, but withdrawn facts are not publicly readable.

## Consent and account boundaries

Expand the sharing disclosure to cover manually created products, optional barcodes, supplements and immediate unverified publication. Existing acknowledgment does not authorize the broader disclosure. Add a versioned server consent acknowledgment and require the new version before any custom-product upload. Preserve the existing sharing preference; do not silently reset it.

A server-controlled consent generation changes on every true-to-false sharing transition through a profile trigger or equivalent centralized database mechanism, including direct legacy profile updates. Consent version/generation are not freely writable client profile fields; acknowledgment uses an authenticated function. Queue operations capture that generation and the originating account UUID. The server validates both current permission and generation transactionally at submission. Reenabling sharing cannot make an old canceled operation eligible again without an explicit new sharing action.

New products enqueue automatically only when the originating account is signed in, its profile is loaded, sharing is on and the current disclosure is acknowledged. Products created signed out or without consent stay local. Owner/status mappings are keyed by account UUID plus local product UUID; imported community source identity and attribution are separate from account ownership. Removing an account mapping cannot erase the imported source attribution. Show “Share this product” to publish one selected local item after a product-only preview. This also repairs the originally reported item: review or complete its facts and explicitly share it. Do not bulk-upload existing journal history or infer ownership from legacy local records.

Signing out immediately closes the delivery gate, cancels active requests and pauses that account's pending operations. Signing in as another account never sends or exposes the previous account's queue. The same account can resume eligible operations after profile and consent checks. Sharing off cancels pending publication work; reenabling requires explicit resubmission of those old items. Account deletion closes the gate first; confirmed deletion removes the account's local operations and remote mappings while preserving local products. Failed deletion leaves delivery paused with a clear recovery action.

A canceled request already accepted by the server may have published. Cancellation does not promise retraction; “Remove my contribution” is a separate explicit withdrawal stored durably with its own operation UUID and expected contribution revision. It can retry while sharing is off, still requires the originating authenticated account, and shows “Removal pending” until acknowledgment, then “My contribution removed.” A newer concurrent publication makes an old withdrawal conflict rather than delete unseen new work. Replay returns the original withdrawal acknowledgment together with the current contribution revision and publication state; it never withdraws a newer revision or replaces current status with an obsolete Shared state. Removing one person's contribution does not claim the product disappeared if others still support it. Turning sharing off stops new publication and does not claim prior published items were deleted. The disclosure states this distinction.

## Durable delivery and status

Add custom product and sharing-operation models to the existing journal SwiftData container through a tested schema migration. Save a product revision, any optional intake and its eligible sharing operation in one local transaction. A failure rolls back the entire local transaction. An outbox operation contains its publication/withdrawal kind, only allowlisted product facts when publishing, owner UUID, operation/client revision IDs, expected server revision, consent version/generation, delivery state and retry metadata. Credentials are never persisted in it.

A serial delivery worker runs when the app launches, enters the foreground, restores connectivity or the person taps Retry. No new cron, permanent timer or background-service entitlement is needed. The worker checks ownership, expected revision and the operation-specific permission before sending and before committing a reply. Publication needs current sharing consent; withdrawal must remain deliverable when sharing is off. Late results from an old account or erased generation cannot recreate status or data.

Retry network errors, 429 and 5xx with exponential backoff and jitter, honoring Retry-After, with a capped delay and no tight retry loop. Validation/rejection/consent errors stop automatic attempts and show an actionable reason. Authentication refresh uses the existing account client and preserves the expected owner. Cancellation is propagated distinctly from network failure. Relaunch recovers interrupted in-flight operations. A lost response uses the same operation identity on retry.

Show durable status in Library product rows and details: “On this phone,” “Waiting to share,” “Sharing paused,” “Shared,” or “Couldn't share.” Show a sanitized reason and Retry/Edit actions where applicable. Only a server acknowledgment produces “Shared.” Verification is shown separately. Queue failures do not erase or fail the already committed local product save. Erase-all closes delivery first and clears local products, queue and statuses; stale callbacks are ignored.

The new durable queue covers custom-product sharing. The legacy scanned-label upload payload remains compatible; its source-aware reads use owner-only verification. Avoid double-submitting an imported or already shared product through either path.

## Cancellation, epochs and explicit review

Durable store epochs and live session epochs are distinct. Restore/reopen renews only eligible work into the current session after ownership, profile and consent checks; a stale callback cannot become authoritative merely because it names the same account. Store replacement/erase invalidates old store callbacks. Sharing off, sign-out, account deletion and local erase close admission before asynchronous work can suspend; failed deletion or credential removal leaves delivery paused.

An attempted publication retains its exact envelope, request identity, expected revision and attempt history. Canceling it does not assert that the server canceled it. Withdrawal preparation first resolves that envelope: a committed result supplies authenticated current state, while an uncommitted result creates a server cancellation fence that permanently rejects later submission of that envelope. Preparation has its own durable attempt state and bounded retry behavior. A removal already satisfied without a remote withdrawal uses a distinct `satisfied` state, never a fabricated receipt. Resolution and removal remain available with sharing disabled or the new-publication gate closed.

Conflict reconciliation is an explicit preview then confirmation. The preview captures the exact local revision, own mapping, ordered operation history, authenticated current server state and revision, and both epochs. Confirmation rechecks these values atomically before settling obsolete work and optionally enqueueing one new operation at the displayed compare-and-swap revision. Keep-current and publish are distinct decisions. No automatic rebase, resubmit or terminal-operation revival occurs.

This review also handles an older acknowledged receipt that has become stale because another device changed the contribution. Separate review metadata can record the deliberately accepted newer authority without rewriting the acknowledgment or original request. A newer unattempted pending descendant cannot hide an older unresolved conflict; the whole own-product chain is checked. Canceled publications with zero attempts and no saved envelope are inert history and do not block a new explicit sharing review. Attempted or envelope-bearing cancellations remain unresolved until the supported resolution/review path settles them. Reenabling sharing alone revives none of these operations.

Legacy import is staged when kind or serving structure is unknown. Preserve raw legacy serving text, require explicit kind and numeric product-serving completion where needed, and never derive either from consumed amount. Confirming that one selected product does not backfill unrelated history or infer contribution ownership.

## Library discovery and import

List standalone custom products independently of Recents. Replace the search placeholder with local and shared result groups, and rename the Foods segment to Products so it accurately includes drinks and supplements. Signed-out people can search local products and see a clear sign-in action for shared results.

Searching, importing, favoriting or logging a shared product does not publish personal intake or create agreement. Import retains immutable facts, kind, server product/revision identity and attribution. Optional verification evidence is bound to the exact imported content and source UUID/revision. Library wording describes owner review or unverified status at import, not current server moderation. Older imports without evidence show verification not checked. An edit drops that evidence; copied source attribution, support or delivery status cannot establish verification. It opens intake details for the person to choose consumption; nothing is logged by simply selecting a result. Show loading, empty, unavailable and retry states distinctly rather than treating connection errors as no matches.

## Compatibility and rollout

Use additive database tables and new RPC names. Older app builds continue using their original barcode APIs. Preserve existing support, rejection and account deletion tests, updating obsolete automatic-verification assertions to owner-only verification. Introduce a new app version with the disclosure, migration, editor, queue and search together; do not show a working sharing control in builds whose backend lacks the new endpoints.

Before hosted application, review the complete migration and verify it against a fresh synthetic database plus the current migration chain. Deploy backend capability first, then the client. Do not use config push or change authentication providers, CAPTCHA, journal export, HealthKit, relay, goals or medication logic.

Rollback the client independently while retaining additive hosted tables. If publication must be disabled, close the new-publication feature gate; preserve data, receipt replay, resolution, withdrawal, reads and old endpoints. The gate blocks fresh v2 publication that observes the committed disabled value; it does not drain already-running work or disable legacy publication. Any schema removal is a separately reviewed destructive action.

## Validation and release status

Local synthetic SQL validates fresh installation, seeded upgrades, active legacy/owner wrappers and concurrent operations. The owner upgrade includes a deliberately suspended old writer and an invariant-removal negative control. Portable tests exercise actual model/provider sources with explicitly bounded persistence/presentation ports; they do not establish SwiftData durability or SwiftUI rendering.

Actual Apple SwiftPM, generated Debug simulator build/tests, generic-device Release build and captured-image inspection remain mandatory on the integrated source. Existing narrow-width and accessibility-size capture fixtures must be rendered and inspected before changing layout. Backend capability must be deployed and verified before shipping the client; no source test or document substitutes for that release gate.

## Acceptance evidence

1. Create a barcode-free food, drink and one-ingredient supplement; save locally, acknowledge remote sharing, then find each from a second synthetic account as unverified.
2. Name-only products appear with missing facts, never fabricated zero amounts or a verified badge.
3. Preserve known zero, unknown, threshold states, supplement units, product serving definition and decimal precision through local persistence, wire contract and import.
4. Prove historical intake snapshots and consumption fields do not change when product facts are edited or shared. Assert the outbound key allowlist, including nested structures.
5. Persist product/optional intake/outbox atomically; injected failure writes none. Reopen a migrated existing store without data loss and keep products after deleting intakes.
6. Lose a server response and retry/relaunch: one contribution, no duplicate product/support count; reject modified duplicate request bodies and stale revisions.
7. Prevent cross-account delivery, stale consent, old callbacks after erase, and replay after withdrawal/account deletion. Exercise sign-out, failed sign-out/deletion, legacy profile sharing toggles and sharing changes during a request. Delete through the existing legacy RPC while a new submission is in flight and prove no resurrection. Withdraw offline while sharing is off, recover a lost reply, and replay an old publication: neither data nor Shared status returns. Replay a delayed withdrawal after deliberate republication and prove the newer revision stays published. Reject stale same-account edits/withdrawals from a second device without overwriting newer work.
8. Distinguish retryable errors, authentication, consent, invalid input, rate limits and moderation. Render pending/shared/paused/failed statuses accessibly.
9. Same names without barcodes do not auto-merge. Equivalent UPC/EAN resolves consistently. Conflicting supplement facts remain actual alternatives; repeated use never verifies a product.
10. Existing local items are not backfilled. Explicitly preview/share one selected legacy item after editing missing product facts; no unrelated journal records are uploaded.
11. Search is bounded, paginated and excludes rejected/withdrawn content; imported products preserve identity without generating an upload.
12. Legacy and new barcode identities group consistently without double-counted support or inherited verification. Legacy/new moderation applies across both surfaces; account deletion through an older client cleans both. Legacy barcode endpoints and account deletion remain compatible. Run SQL, Swift provider/UI/storage tests, source lint, privacy checks, generated project build and simulator coverage on the reviewed head.

## Review boundary

This specification describes shared product publication, discoverability and reliable delivery only. Private cross-device journal/product sync, iCloud backup, anonymous community access, recipe publication, health advice and automated bulk history upload are outside this change. The source implementation follows the approved design and the additional recovery rules below. Final review, actual Apple execution, reviewed backend deployment/capability checks and protected client release approval remain required.
