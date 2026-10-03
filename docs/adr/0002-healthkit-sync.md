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

The spike uses synthetic amounts only: 250 mL of water and 10 g of protein, tagged with a fixed sync
identifier. It is not anyone's real intake.

Steps, each of which appends a line to an on-screen list and logs the same line with `Logger`:

1. Request authorization to share (write) `dietaryWater` and `dietaryProtein`, and to read the same
   two so the spike can query back what it wrote.
2. Save a 250 mL water sample and a 10 g protein sample with `HKMetadataKeySyncIdentifier` set to
   the spike id and `HKMetadataKeySyncVersion` set to 1, then list every sample that exists for that
   sync identifier with its UUID, sync version, timestamps and source.
3. Save the same sync identifier again with version 2 (higher) and list what exists afterwards.
4. Save it again with version 2 (equal) and with version 1 (lower), recording the result or the
   error of each, listing the samples after each save.
5. Delete the samples carrying the spike sync identifier **and** `HKSource.default()`, that is only
   the ones this app wrote, then report how many remain.

**Copy results** puts the whole transcript on the clipboard.

## How to run it

1. In this repository, run **Actions > ios > Run workflow**.
2. Set `configuration` to **Debug** (the default is Release, which has no spike in it). Leave
   `bundle_id` and `marketing_version` at their defaults.
3. Download the `HealthNutrition-unsigned.ipa` artifact. The build is unsigned, so sign it yourself
   (Apple developer certificate, AltStore or SideStore) and sideload it on your iPhone. The signing
   team id and profile stay local and are never committed.
4. On first launch, allow Health access for the app when iOS asks, for both read and write. The
   spike needs write access to `dietaryWater` and `dietaryProtein` to run at all.
5. Open the **HealthKit** tab and run the steps in order: request authorization, step 1, step 2, step
   3, step 4.
6. Tap **Copy results** and paste the transcript into the Results section below.
7. Step 4 deletes the samples, but check the Health app afterwards as well: the point of step 4 is
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
  in a release build reads or writes health data: the only caller is behind `#if DEBUG`.
- The writer (NC-07) follows what this table says, not what the documentation says. If the device
  shows that HealthKit ignores a lower version silently, the writer can skip the re-save instead of
  treating it as an error.
- If a re-save turns out to mint a new UUID, the journal cannot key a Health delete off the UUID it
  stored, and must delete by sync identifier and source instead. That is a design decision for the
  writer, taken after this run.
