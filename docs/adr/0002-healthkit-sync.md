# ADR 0002: HealthKit sync identifier and sync version for the journal writer

Status: Proposed. The device run has not happened yet, so the Results section below is pending.

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
observation must not be paste-able into the Results table below as if it were an empty store.

Steps, each of which appends a row to an on-screen list and logs the same row with `Logger`:

1. Request authorization to share (write) `dietaryWater` and `dietaryProtein`, and to read the same
   two so the spike can query back what it wrote.
2. **Reset**: delete any app-owned spike samples left behind by an earlier or interrupted run, so
   this run's version 1 really is the first write. Step 1 does this automatically too; a leftover
   version-2 sample would otherwise make this run's version 1 a *lower* write and its version 2 an
   *equal* one, and every label below would be wrong.
3. Save a 250 mL water sample and a 10 g protein sample, each with `HKMetadataKeySyncIdentifier` set
   to its own spike id and `HKMetadataKeySyncVersion` set to 1, then list every sample that exists
   for those identifiers with its UUID, sync version, timestamps and source.
4. Save each identifier again with version 2 (higher) and list what exists afterwards.
5. Save each identifier again with version 2 (**equal** to what step 4 wrote) and then with version 1
   (**lower**), recording the result or error of each save in turn, and listing the samples after
   each.
6. Delete the samples carrying the spike sync identifiers **and** `HKSource.default()`, that is only
   the ones this app wrote, then report how many remain.

Every step button is disabled while a step is running, so no step can be silently dropped by tapping
it mid-run.

**Copy results** puts the whole transcript on the clipboard.

## How to run it

1. In this repository, run **Actions > ios > Run workflow**.
2. Set `configuration` to **Debug** (the default is Release, which has no spike in it). Leave
   `bundle_id` and `marketing_version` at their defaults.
3. Download the `HealthNutrition-unsigned.ipa` artifact.
4. **The signing profile must have the HealthKit capability.** The `unsigned-ipa` job builds with
   `CODE_SIGNING_ALLOWED=NO`, so the downloaded artifact carries no code signature and therefore no
   entitlement at all: `HealthNutrition.entitlements` exists in the source tree, but it is only
   embedded once the app is re-signed. Entitlements live in the code signature, so you must:

   - enable the **HealthKit** capability on the App ID for the bundle identifier you sign with (in
     the developer portal, or in Xcode under Signing & Capabilities), and
   - regenerate the provisioning profile so it includes that capability, then sign and sideload the
     ipa with that profile (your own certificate, AltStore or SideStore).

   A profile without the HealthKit capability produces an app that installs but cannot run the spike:
   authorization fails even though the entitlements file is in the repository. Check the signed
   binary before installing, for example with `codesign -d --entitlements - <app path>`, and confirm
   `com.apple.developer.healthkit` is present.
5. The signing team id and profile stay local and are never committed.
6. On first launch, allow Health access for the app when iOS asks, for both read and write. The
   spike needs write access to `dietaryWater` and `dietaryProtein` to run at all.
7. Open the **HealthKit** tab and run the steps in order: request authorization, reset, step 1, step
   2, step 3 (equal then lower), step 4.
8. Tap **Copy results** and paste the transcript into the Results section below.
9. Step 4 deletes the samples, but check the Health app afterwards as well: the point of step 4 is
   partly to confirm that the delete actually removed them. If any sample survives, delete it by hand
   in the Health app and note that in the transcript.

## Results

**Pending.** To be filled in from the device run: the transcript copied out of the spike, plus the
answer to each of the four questions above. Until it is filled in, this ADR stays Proposed and the
journal writer must not assume a particular dedupe behaviour.

| Question | Answer |
| --- | --- |
| Higher sync version: replaced, and is the UUID stable? | pending device run |
| Equal or lower sync version: ignored, error, or duplicate? | pending device run |
| Are UUIDs stable across a re-save? | pending device run |
| Delete by sync identifier, narrowed to `HKSource`? | pending device run |

## Consequences

- The HealthKit capability and the two usage strings are in the app target from now on, but nothing
  in a release build reads or writes health data: the only caller is behind `#if DEBUG`. The
  capability is only inert until someone sideloads a HealthKit-enabled signed build, so the run
  instructions above are a prerequisite for the spike, not an optional extra.
- Each quantity gets its own sync identifier in the writer too, derived from the journal intake id
  and the nutrient, so two nutrients in one intake never resolve against each other.
- The writer (NC-07) follows what this table says, not what the documentation says. If the device
  shows that HealthKit ignores a lower version silently, the writer can skip the re-save instead of
  treating it as an error.
- If a re-save turns out to mint a new UUID, the journal cannot key a Health delete off the UUID it
  stored, and must delete by sync identifier and source instead. That is a design decision for the
  writer, taken after this run.
