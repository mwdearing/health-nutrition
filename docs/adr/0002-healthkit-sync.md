# ADR 0002: HealthKit sync identifier and sync version for the journal writer

Status: Accepted (device run 2026-10-03, iPhone, Debug build 0.1.64). The Results section below records
what HealthKit actually did; the journal writer follows it.

## Context

The journal already records an ordered, append-only history of intake revisions
(see [journal-store.md](../journal-store.md)), and every revision that is not a delete also has to
reach HealthKit so the Health app shows the same intake. The writer therefore needs HealthKit's
documented dedupe mechanism: a `HKMetadataKeySyncIdentifier` that identifies one logical sample and
an `HKMetadataKeySyncVersion` that says how current that sample is.

Apple's documentation states the intent plainly: if two samples of the same type carry the same sync
identifier, HealthKit keeps only the one with the higher sync version. What it does not settle, and
what the writer's idempotency and its delete both depend on, is the behaviour that actually matters
on a device:

1. Does a **higher** sync version replace the old sample, and is the sample's `UUID` stable across
   a replacement?
2. What happens when the same sync identifier is saved again with an **equal** version, or with a
   **lower** one: is it silently ignored, is it an error, or does it create a second sample?
3. Are the sample **UUIDs** stable across a re-save, or does HealthKit mint new ones every time?
   The journal's `delete` step keys off what it wrote, so a changing UUID is not harmless.
4. Does **delete by sync identifier** work, and can the delete be narrowed to the samples this app
   wrote (matched on `HKSource`) so a sample from another app is never touched?

A spike measures this before the writer is built, because a writer written to the documentation
rather than to the device is how duplicate samples and orphaned Health rows happen.

## The spike

The screen is `ios/HealthNutrition/Sources/Debug/HealthKitSpikeView.swift`, and the whole file is
wrapped in `#if DEBUG`, so it exists only in debug builds. Its tab appears in the app only in debug
builds too (`ios/HealthNutrition/Sources/RootView.swift`). The target carries the HealthKit
capability (`HealthNutrition.entitlements`) and the two usage strings, because HealthKit only
prompts for authorization when the binary declares it.

The spike uses synthetic amounts only: 250 mL of water and 10 g of protein. It is not anyone's real
intake.

Water and protein each carry their **own** sync identifier, the spike namespace with a `.water` and
a `.protein` suffix. A sync identifier identifies one piece of data, so one shared identifier would
let the water and protein writes resolve against each other and confound the sample counts and UUID
comparisons this spike exists to make.

A failed HealthKit query is recorded as an error, never as "no samples found". An unsuccessful
observation must not be paste-able into the Results table below as if it were an empty store. For the
same reason, if the cleanup in step 2 or step 3 cannot confirm an empty store, step 3 **aborts
without writing**: an unknown starting state would make every label below describe the wrong
operation, and would add samples to an experiment already in doubt.

Steps, each of which appends a row to an on-screen list and logs the same row with `Logger`:

1. Request authorization to share (write) `dietaryWater` and `dietaryProtein`, and to read the same
   two so the spike can query back what it wrote.
2. **Reset**: delete any app-owned spike samples left behind by an earlier or interrupted run, clear
   the transcript and re-lock the steps. Step 3 does the same cleanup implicitly as its own
   precondition; a leftover version-2 sample would otherwise make this run's version 1 a *lower*
   write and its version 2 an *equal* one, and every label below would be wrong.
3. Save a 250 mL water sample and a 10 g protein sample, each with `HKMetadataKeySyncIdentifier` set
   to its own spike id and `HKMetadataKeySyncVersion` set to 1, then list every sample that exists
   for those identifiers with its UUID, sync version, timestamps and source.
4. Save each identifier again with version 2 (higher) and list what exists afterwards.
5. Save each identifier again with version 2 (**equal** to what step 4 wrote) and then with version 1
   (**lower**), recording the result or error of each save in turn, and listing the samples after
   each.
6. Delete the samples carrying the spike sync identifiers **and** `HKSource.default()`, that is only
   the ones this app wrote, then report how many remain. This re-locks the sequence.

Each step is enabled only once the step before it has succeeded (authorize, version 1, version 2
higher, equal and lower, delete), so the experiment cannot be run out of order and a label can never
describe the wrong operation. Every button is also disabled while a step is running, so no step can
be silently dropped by tapping it mid-run. The screen shows which step is next.

**Copy results** puts a redacted transcript on the clipboard: the app's bundle identifier is replaced
with `<bundle-id>` (case-insensitively) and the device name with `<device>`, and a sample's source is
printed only as `this app` or `another app`, never as a bundle identifier. (The first device run
showed why: the source identifier HealthKit reported did not match `Bundle.main` text exactly, so it
slipped past the text replacement; it was redacted by hand before the transcript went in below.)

## How to run it

1. In this repository, run **Actions > ios > Run workflow**.
2. Set `configuration` to **Debug** (the default is Release, which has no spike in it).
3. **Set `bundle_id` to the bundle identifier of *your* HealthKit-capable provisioning profile.**
   Do not leave it at the default: the default `dev.example.HealthNutrition` is a placeholder, and a
   HealthKit profile is issued for an explicit App ID of your own. An ipa built with the placeholder
   cannot be signed and installed by a profile issued for your identifier, so the build will fail at
   the signing step. Take the identifier from the profile you will sign with, and use that same
   identifier for the App ID in the next step.
4. Leave `marketing_version` at its default.
5. Download the `HealthNutrition-unsigned.ipa` artifact.
6. **The signing profile must have the HealthKit capability.** The `unsigned-ipa` job builds with
   `CODE_SIGNING_ALLOWED=NO`, so the downloaded artifact carries no code signature and therefore no
   entitlement at all: `HealthNutrition.entitlements` exists in the source tree, but it is only
   embedded once the app is re-signed. Entitlements live in the code signature, so you must:

   - enable the **HealthKit** capability on the App ID for the bundle identifier from step 3 (in
     the developer portal, or in Xcode under Signing & Capabilities), and
   - regenerate the provisioning profile so it includes that capability, then sign and sideload the
     ipa with that profile (your own certificate, AltStore or SideStore).

   A profile without the HealthKit capability produces an app that installs but cannot run the spike:
   authorization fails even though the entitlements file is in the repository. Check the signed
   binary before installing, for example with `codesign -d --entitlements - <app path>`, and confirm
   `com.apple.developer.healthkit` is present.
7. The signing team id and profile stay local and are never committed.
8. On first launch, allow Health access for the app when iOS asks, for both read and write. The
   spike needs write access to `dietaryWater` and `dietaryProtein` to run at all.
9. Open the **HealthKit** tab and run the steps in order: request authorization, reset, step 1, step
   2, step 3 (equal then lower), step 4. Each step is enabled only once the step before it succeeded,
   and the screen shows which one is next, so the sequence cannot be run out of order.
10. Tap **Copy results** and paste the transcript into the Results section below. **Only the redacted
    transcript goes into this repository.** The button already replaces the app's bundle identifier
    with `<bundle-id>` and the device name with `<device>`, so the copied text carries no local
    deployment details. Paste that text as it stands; do not paste an unredacted screen capture or a
    transcript taken before redaction.
11. Step 4 deletes the samples, but check the Health app afterwards as well: the point of step 4 is
    partly to confirm that the delete actually removed them. If any sample survives, delete it by hand
    in the Health app and note that in the transcript.

## Results

Device run on 2026-10-03 (iPhone on the iOS 26 runtime, Debug build 0.1.64, sideloaded with a
HealthKit-capable profile; the exact iOS point release was not captured by the spike). The equal and
lower version behaviour below is observed, not documented by Apple, so it holds for this runtime only:
re-run the spike after each major iOS release before relying on it there.
Transcript as copied from the app; the source bundle identifier was redacted by hand to `<bundle-id>`
(see the redaction note above).

```text
HealthKit write spike (synthetic samples, bundle id and device name redacted)
existing spike samples: none
step 1 preflight: no leftover app-owned spike samples found
step 1: saving water 250 mL and protein 10 g at syncVersion 1
step 1: saved water 250 mL syncVersion=1 uuid=2BE9A68E-F245-4C4F-AAA6-737D167CEF7F
step 1: saved protein 10 g syncVersion=1 uuid=C5AF1A64-A663-4E93-BBF7-93EECE73D8EC
existing spike samples: 2
  HKQuantityTypeIdentifierDietaryWater 250 mL uuid=2BE9A68E-F245-4C4F-AAA6-737D167CEF7F syncVersion=1 start=2026-10-03T23:46:54Z end=2026-10-03T23:46:54Z source=<bundle-id> sourceVersion=Optional("64") own=true
  HKQuantityTypeIdentifierDietaryProtein 10 g uuid=C5AF1A64-A663-4E93-BBF7-93EECE73D8EC syncVersion=1 start=2026-10-03T23:46:54Z end=2026-10-03T23:46:54Z source=<bundle-id> sourceVersion=Optional("64") own=true
step 2 (higher version): saved water 250 mL syncVersion=2 uuid=5F10DA37-E5AE-4A03-8856-9832D227FE02
step 2 (higher version): saved protein 10 g syncVersion=2 uuid=6C8D66DE-D3D7-4E57-B777-9CCCFFE59EB2
existing spike samples: 2
  HKQuantityTypeIdentifierDietaryWater 250 mL uuid=5F10DA37-E5AE-4A03-8856-9832D227FE02 syncVersion=2 start=2026-10-03T23:46:59Z end=2026-10-03T23:46:59Z source=<bundle-id> sourceVersion=Optional("64") own=true
  HKQuantityTypeIdentifierDietaryProtein 10 g uuid=6C8D66DE-D3D7-4E57-B777-9CCCFFE59EB2 syncVersion=2 start=2026-10-03T23:46:59Z end=2026-10-03T23:46:59Z source=<bundle-id> sourceVersion=Optional("64") own=true
step 3a (equal version 2): saved water 250 mL syncVersion=2 uuid=7B46D2B9-F280-4BB8-9A4E-0E232E0A4A17
step 3a (equal version 2): saved protein 10 g syncVersion=2 uuid=B6362392-1D11-419D-A822-7CC35929D15E
existing spike samples: 2
  HKQuantityTypeIdentifierDietaryWater 250 mL uuid=7B46D2B9-F280-4BB8-9A4E-0E232E0A4A17 syncVersion=2 start=2026-10-03T23:47:05Z end=2026-10-03T23:47:05Z source=<bundle-id> sourceVersion=Optional("64") own=true
  HKQuantityTypeIdentifierDietaryProtein 10 g uuid=B6362392-1D11-419D-A822-7CC35929D15E syncVersion=2 start=2026-10-03T23:47:05Z end=2026-10-03T23:47:05Z source=<bundle-id> sourceVersion=Optional("64") own=true
step 3b (lower version 1): saved water 250 mL syncVersion=1 uuid=32C1A684-F39F-44B3-9980-2F90EC11F031
step 3b (lower version 1): saved protein 10 g syncVersion=1 uuid=C3383A82-F1C8-4B07-88ED-A4A3482FDB96
existing spike samples: 2
  HKQuantityTypeIdentifierDietaryWater 250 mL uuid=7B46D2B9-F280-4BB8-9A4E-0E232E0A4A17 syncVersion=2 start=2026-10-03T23:47:05Z end=2026-10-03T23:47:05Z source=<bundle-id> sourceVersion=Optional("64") own=true
  HKQuantityTypeIdentifierDietaryProtein 10 g uuid=B6362392-1D11-419D-A822-7CC35929D15E syncVersion=2 start=2026-10-03T23:47:05Z end=2026-10-03T23:47:05Z source=<bundle-id> sourceVersion=Optional("64") own=true
step 4: deleted 2 app-owned spike sample(s)
existing spike samples: none
```

| Question | Answer |
| --- | --- |
| Higher sync version: replaced, and is the UUID stable? | **Replaced.** Exactly one sample per identifier remains, carrying version 2, and it has a **new UUID**; the version-1 sample is gone. |
| Equal or lower sync version: ignored, error, or duplicate? | **Equal replaces** (one sample remains, version 2, again a new UUID). **Lower is silently ignored**: `save` reports success and returns a new object, but the store keeps the version-2 sample with its UUID unchanged. No error, no duplicate. |
| Are UUIDs stable across a re-save? | **No.** Every accepted save (higher or equal) mints a new UUID; the UUID a save returns for an ignored lower version does not exist in the store. |
| Delete by sync identifier, narrowed to `HKSource`? | **Works.** Querying by the two sync identifiers and filtering to `HKSource.default()` found both samples; deleting them left none. |

Permission sheet: on first authorization the system sheet listed only **Water** under both "write"
and "read", yet both the water and the protein writes were accepted. The writer must not infer what
was granted from what the sheet showed; it relies on the result of each save instead.

## Consequences

- The HealthKit capability and the two usage strings are in the app target, but nothing in a release
  build reads or writes health data yet: the only caller is behind `#if DEBUG`.
- **One sync identifier per (intake, nutrient)**, derived from the journal intake id and the nutrient,
  so two nutrients of one intake never resolve against each other.
- **The sync version is the journal revision number.** An edit writes the next revision with a higher
  version and HealthKit replaces the sample. Re-sending the same revision (a retry) replaces the
  sample again, so a retry is harmless **only if the sample is rebuilt entirely from the stored
  revision**: start and end come from the intake's own time, quantity and metadata from the revision,
  never `Date()` or any other attempt-specific value (the run shows HealthKit accepts an equal-version
  replacement whose timestamps differ).
- **A lower version is a no-op that still reports success**, so the writer must never rely on a
  successful save to mean "the store now holds this revision": it only ever sends the current
  revision, and verifies by querying the sync identifier when it needs certainty.
- **The journal never keys anything off a HealthKit UUID.** UUIDs change on every accepted save and
  the UUID returned for an ignored save does not exist. Deletes go by sync identifier **and**
  `HKSource.default()`, which the run showed works and touches only this app's samples.
- Authorization: the permission sheet under-reports which types are covered, so the writer does not
  infer anything from it. Write permission per type comes from
  `HKHealthStore.authorizationStatus(for:)` (`sharingAuthorized` or not), and a save failure is only
  treated as "not allowed in Health" when its error is `HKError.Code.errorAuthorizationDenied`; any
  other save error (invalid sample, restrictions, a transient store error) stays a retryable delivery
  error.
