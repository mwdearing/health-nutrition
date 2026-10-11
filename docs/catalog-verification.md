# Community catalog verification design

**Status: proposed design; owner approval required before SQL implementation.** This document defines a change to the community-label trust model. It does not assert that a label has been checked, that its nutrition values are accurate, or that any hosted project has applied the design.

## Decision requested

Approve or revise these policy choices before implementation:

1. Agreement among five accounts is not verification. Agreement may continue to make an entry visible as unverified, but only an explicit owner moderation action may set the verified status.
2. An approved canonical snapshot survives withdrawal of the submissions that informed it and deletion of their accounts. It becomes an owner-maintained catalog record with no contributor ownership or contributor identifiers attached. Withdrawal still deletes the account's submissions and recomputes the community entry.
3. A separate, owner-controlled moderation path approves, rejects, and revokes entries. App credentials and signed-in user accounts cannot invoke it.
4. A versioned lookup returns a verification source. The existing lookup remains available to older app versions and continues to return only community entries, preventing older clients from describing owner review as community verification.

An approval of this design is not authorization to apply a hosted migration. SQL implementation, tests, and any hosted application remain separate owner-reviewed steps.

## Current behavior and constraints

The private `catalog` schema currently has `submissions`, `entries`, `rejections`, and `settings`. `public.submit_label` accepts signed-in non-anonymous accounts with sharing enabled. A uniqueness constraint permits one current submission per account UUID, barcode, and basis; replacing a row updates its recency. `catalog.refresh_entry` evaluates at most the 100 newest submissions for a barcode and basis, and writes a single `catalog.entries` row. `min_shown` defaults to two and `min_devices` defaults to five. The resulting `entries.verified` is true at five agreeing account UUIDs. The public `lookup_label` returns `verified` and `supporting_devices`, and `submit_label` may return `verified`.

`catalog.rejections` already suppresses a key from lookup and causes a refresh to remove its entry, but it has no structured moderation history, approval operation, or revocation state. The catalog tables have RLS enabled with no app policies; app access is through narrowly granted public RPC functions. Account withdrawal deletes a user's submissions and recomputes affected entries. Account deletion calls withdrawal before deleting profile and auth rows.

The app currently decodes `verified: Bool` and `supporting_devices: Int`. `CommunityLabelMapping` renders every verified label as “Verified by the community: N people agree,” and unverified labels as shared-but-not-verified. Returning an owner-approved label through that contract unchanged would misstate its source. The app's submit result decoder also still recognizes `verified` for compatibility.

Relevant contracts are in `supabase/migrations/20261010200000_community_catalog.sql`, `20261010230000_catalog_hardening.sql`, `20261010240000_catalog_consensus_fixes.sql`, `20261010250000_canonical_rejections.sql`, `20261010260000_payload_bounds_and_acl.sql`, `supabase/tests/community_catalog.sql`, `docs/community-client.md`, `docs/community-catalog-app.md`, and the community provider/model and attribution mapping under `ios/NutritionCore`.

## Proposed trust model

There are two separate states for a barcode and basis:

- **Community candidate:** the current aggregate derived from eligible community submissions. It can be absent or shared without verification. It is never verified by agreement count. The five-account threshold is removed from trust decisions; if retained as a setting for compatibility or reporting, it has no path to set a verification flag.
- **Owner-approved canonical:** a copied, bounded payload that a project owner explicitly reviewed and approved. It is the only state that can be returned as verified. It is stored independently from submissions and independently from the newest-100 candidate window. A submission or refresh cannot create, alter, or delete it.

The canonical key is `(catalog.canonical_barcode(barcode), basis)`, preserving the existing UPC-A/leading-zero EAN-13 normalization and basis separation. Approval copies the reviewed values into the canonical row; it must not retain source submission IDs, account UUIDs, or a foreign key to a submission. Store only the key, `product_name`, `brand`, `serving_text`, `nutrients`, and `approved_at`, plus the minimum non-personal review provenance described below. Apply the same barcode, serving, text-length, nutrient-key, value-bound, payload-size, and precision validation used for submissions. `per_serving` requires a nonempty serving definition.

The public verification source is `owner_reviewed` for an active canonical and `community` for an aggregate. For an owner-reviewed row, `verified=true` and `supporting_devices=0`; zero means the response makes no claim about a community supporter count. For a community row, `verified=false` and `supporting_devices` remains the current distinct-account count. The UI must render owner review as “Reviewed by the catalog owner” (or owner-approved wording chosen by product review), with no “N people agree” claim. This is a review-status statement, not a nutrition-accuracy guarantee.

## Moderation authority, history, and visibility

Moderation belongs to the project owner. The proposed initial interface is direct database work in the project owner's authenticated administrative SQL context. No service-role API is required for this design. It is not an app feature. No moderation function is executable by `PUBLIC`, `anon`, or `authenticated`; approval tables have no grants to those roles; and no app anon key, user access token, or client-held credential can authorize moderation. Private schema tables remain unavailable through PostgREST. A later server-side admin API would require separate owner approval, keep its privileged credential server-side, and expose only owner-authenticated moderation actions; the mobile app must never receive that credential.

Keep an append-only private moderation audit with the canonical key, action (`approve`, `reject`, `revoke`, or `clear_rejection`), timestamp, bounded decision reason, and a non-personal payload digest or equivalent before/after reference. Do not record a submitter/account UUID or expose the moderator identity in lookup responses. The audit records the authority as the project-owner role; it does not need a personal moderator identifier. The audit must not include free-form personal data. Audit rows are immutable; corrections are recorded as later events. Public responses contain neither reason nor audit metadata.

Define action semantics as follows:

- **Approve:** validate and copy the explicitly reviewed payload into the canonical table in one transaction; clear an active rejection for that key in the same transaction; append an approval audit event. A prior community row may remain available internally but does not take precedence in lookup.
- **Reject:** append a rejection event and make the key unavailable from both sources. Remove any active canonical payload from public lookup and retain the rejection state so later submissions cannot restore visibility or verification automatically. New community submissions may be refused or accepted into the private candidate pool, but must not make the rejected key visible. The implementation must choose one behavior consistently; the recommendation is to accept under existing submission limits while suppressing lookup, avoiding a new externally distinguishable product-existence response.
- **Clear rejection:** an explicit owner action clears the suppression state and is audited. This alone does not approve or verify a label; a community aggregate may become visible as unverified.
- **Revoke approval:** remove the active canonical row and append a revocation event. Unless the key is also rejected, lookup may then fall back to a currently eligible community aggregate, always unverified. Revocation does not make the old approved payload public again. Re-approval requires a new explicit review and approval action.

These operations should be serialized per canonical key using the existing advisory-lock convention so concurrent submissions, refreshes, and owner actions cannot leave stale public state. Canonical writes must be independent of the `entries` refresh path.

## Withdrawal and account deletion

This design chooses **retention of the approved snapshot without contributor ownership**. Approval creates an independent owner-maintained product-label record. It does not retain the accounts or submissions that informed the decision. Therefore:

- `withdraw_my_submissions()` continues to delete every matching `catalog.submissions` row, re-run the community calculation, and preserve the daily usage count. It never deletes or changes an approved canonical snapshot.
- `delete_my_account()` continues to withdraw submissions before profile and auth deletion. The deletion cascade removes remaining account-owned data; it does not remove an approved canonical snapshot.
- The independent canonical record and audit keep no contributor UUID, submission ID, or user-linked foreign key. The audit records the reviewed payload digest and owner action, not its submitters. Support counts shown for the canonical are zero/unspecified, never historical contributor counts.
- Revocation or rejection is still available to remove an approved snapshot from lookup. Rejection suppresses both sources; revocation permits only an unverified community fallback.

Owner approval necessarily authorizes a generic product-label snapshot to remain as a catalog record even if a contributor later withdraws. If that retention policy is not acceptable, the alternative is to retain the canonical only while at least one source submission remains, which would require private provenance links and would cause withdrawal/deletion to revoke or remove approved values. The owner must choose explicitly; this document recommends the independent snapshot model above.

## Database and API shape to implement after approval

The following are required outcomes, not a migration script:

1. Add a private `catalog.approved_entries` table keyed by canonical barcode and basis. It stores a validated payload snapshot, approval timestamp, active state only if needed for operational convenience, and no submitter identity or source-row reference. Prefer deleting the active row on revoke/reject while keeping action history in the audit table.
2. Add a private append-only `catalog.moderation_audit` table with constrained action types, key, timestamp, bounded reason, and payload digest/reference. RLS remains enabled with no app policies; all app-role table privileges are revoked.
3. Replace the automatic community verification behavior in `catalog.refresh_entry`: community `entries.verified` is always false, regardless of account count. The existing newest-100 window remains only an aggregate calculation bound. Flooding can change which unverified community aggregate is shown, but cannot evict, overwrite, or revoke an approved canonical.
4. Change `submit_label` so consensus never returns `verified`; it continues returning `received` or `shared`. A submission for an approved key is stored under existing rules and may update the hidden/community aggregate only. It cannot modify the approved payload or the approval audit.
5. Add owner-only moderation operations for approve, reject, clear rejection, and revoke, or an equivalent tightly controlled owner-only administrative transaction interface. They validate input, lock the key, update active state and append audit atomically. Revoke execution from `PUBLIC`, `anon`, and `authenticated`; grant no moderation operation to the mobile role.
6. Add `public.lookup_label_v2` for signed-in non-anonymous callers with the existing profile check. It returns the current payload columns plus `verification_source`. It selects an active approved canonical first; otherwise it returns a non-rejected community row; rejection suppresses both. Owner-reviewed rows return `verified=true` and `supporting_devices=0`; community rows return `verified=false` and their current support count. It never returns moderation reasons, audit records, actor identifiers, or contributor IDs.
7. Keep `public.lookup_label` with its existing signature and response shape for old app versions, returning only eligible community rows and never any verified row. Keep it signed-in only. New app code moves to `lookup_label_v2` and decodes the source. This means older clients remain functional and cannot mislabel owner review; they simply do not receive owner-approved-only rows until updated.
8. Preserve the current authentication, sharing-opt-out, daily submission limit, barcode normalization, nutrient bounds, and account withdrawal checks. Continue requiring a live profile for lookup so a deleted account's stale access token reads nothing.

The updated client model should represent verification source explicitly (for example, `community` or `ownerReviewed`) while keeping the existing `verified` and supporter-count fields where useful. The attribution mapper must branch on source. `CommunitySubmitResult.verified` may remain decodable for backward compatibility, but current server behavior must not return it for community consensus. Update the public client and product docs to explain that community agreement is not verification and that owner review is not a claim of medical or nutrition accuracy.

## Acceptance cases

The SQL behavior suite and client contract tests for the implementation must cover at least:

1. **Five confirmed accounts do not verify:** five distinct account UUIDs submit mutually agreeing values. The community aggregate may be returned as shared, but `verified` is false, its source is `community`, and submit responses never return `verified`.
2. **Candidate flooding cannot replace approval:** owner approves a canonical payload; at least 100 newer malicious submissions are accepted or attempted within normal limits. Refreshes leave the approved payload and owner-reviewed source unchanged. No submission can overwrite the canonical snapshot.
3. **Unauthorized moderation fails:** anon and authenticated app roles cannot execute approve/reject/clear/revoke or mutate private approval/audit tables. A client request using the public anon key and an ordinary signed-in token cannot change canonical state.
4. **Owner approval works:** the project owner approves a valid payload; the audit records the action and bounded provenance; a signed-in lookup v2 returns the exact approved snapshot with `owner_reviewed`, `verified=true`, and no moderator or contributor identifier. Invalid payloads and invalid per-serving values fail atomically without changing prior state.
5. **Rejection suppresses both sources:** reject a key with both a community aggregate and an approved canonical; lookup v2 and the legacy lookup return no row. Additional submissions and refreshes cannot restore visibility. Clearing rejection is separately audited and does not itself mark the community row verified.
6. **Revocation falls back safely:** revoke an approved key with an eligible community aggregate; lookup v2 returns only that aggregate as unverified/community. Without an eligible aggregate it returns no row. Re-approval needs another owner action.
7. **Withdrawal preserves canonical ownership boundary:** withdraw an account whose submission informed an approved snapshot. Its submission disappears and community count/aggregate recompute, but the approved snapshot remains exactly unchanged, with no account UUID or submission link in canonical/audit data.
8. **Account deletion has the same boundary:** delete the account that supplied an approved candidate. Account-owned rows disappear and the stale token cannot look up labels; the owner-maintained canonical remains available to other signed-in callers, and exposes no contributor identity.
9. **Legacy compatibility:** the existing lookup keeps its old response shape and never returns owner-reviewed records. The v2 response includes the source, and UI tests assert distinct attribution wording with no fabricated supporter count.

## Migration, rollback, and re-verification

Implementation must be a new forward migration; do not edit or rewrite already-applied migrations. Before deployment, inventory the current `entries` and submissions and decide whether existing five-account `verified=true` rows receive owner review, become unverified community rows, or are hidden until reviewed. The safe default is to clear all automatic verified status and expose those values only as unverified community aggregates; do not copy them into `approved_entries` without a new explicit owner review.

Migration should create the separate canonical and audit structures, update functions and grants transactionally, and rebuild community entries under the no-auto-verification rule. Preserve the existing payload validator and key normalization. Add tests for both a clean install and an upgrade from the current schema. Confirm old and new RPC grants explicitly, including `PUBLIC` defaults on new Postgres functions/tables.

For rollout, deploy the app's source-aware v2 client before enabling canonical rows through the new lookup. Keep the legacy RPC until the supported client window permits retirement. Validate the five-account, flood, moderation ACL, withdrawal, deletion, and old-client cases in the local SQL suite and client tests before any hosted application.

Rollback is a new forward migration, not deletion of migration history. It should disable v2 exposure and moderation writes, restore the legacy lookup/submit contract only if doing so cannot re-enable consensus verification, and leave approved snapshots and audit data intact for review. Do not restore automatic five-account verification during rollback. If an operational rollback requires hiding approved rows, remove them from active lookup without deleting their audit history. Any later re-enable requires rerunning the full migration and ACL acceptance suite.

## Explicit owner decisions still needed

- Approve the proposed policy that only project-owner moderation verifies and that five-account consensus remains unverified.
- Approve permanent retention of the independent canonical snapshot after contributor withdrawal/account deletion, with no source identity retained.
- Confirm the initial moderation surface is the proposed owner-only administrative SQL context. A separately authenticated server-side owner API is deferred and needs separate approval. No app credential may participate.
- Approve the rejection behavior recommended here: accept submissions under normal limits but suppress both community and canonical lookup until the owner clears rejection.
- Decide whether any existing automatically verified entries will be manually reviewed before exposure as owner-reviewed; the proposed default is no bulk promotion.
- Confirm the exact user-facing owner-review attribution phrase before client implementation.
