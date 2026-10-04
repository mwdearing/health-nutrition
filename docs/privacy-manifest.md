# Privacy manifest

Status: Current. Reviewed whenever the set of required-reason APIs changes.

The app ships `ios/HealthNutrition/Resources/PrivacyInfo.xcprivacy`, which
`ios/HealthNutrition/project.yml` already bundles because `Resources` is one of
the target's source paths. No project file change was needed for it to be
picked up.

## Tracking

`NSPrivacyTracking` is `false` and `NSPrivacyTrackingDomains` is empty. The app
has no analytics, no advertising identifier and no third-party SDK that reads
the identifier; nothing is shared with a data broker or an ad network, so there
is nothing to declare and nothing to opt out of.

## Collected data

`NSPrivacyCollectedDataTypes` is empty. The reasoning:

- The journal, recipes, favorites and repeat rules live on the device. They are
  written by the local stores under `ios/NutritionCore/Sources/NutritionJournal`
  and nothing uploads them.
- A barcode lookup sends only the barcode digits to Open Food Facts
  (`/api/v3/product/<barcode>`, see [the data source note](providers/open-food-facts.md))
  and nothing else from the device. That request returns product data; it does
  not transmit anything the app holds, and no free-text, identifier or location
  is attached to it.
- The optional relay sends journal entries to a receiver the user configures and
  owns themselves.
  Data that never leaves the device except at the user's explicit direction to
  their own endpoint is not "collection" by this app, and the app is the sender
  here, not the recipient (`ios/NutritionCore/Sources/NutritionUI/ConnectionsPrivacyView.swift`).
- Nothing is sold, shared for other purposes or used for tracking.

## Required-reason APIs

`NSPrivacyAccessedAPITypes` declares one category:

| Category | Reason | Where the code uses it |
| --- | --- | --- |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` | `ios/NutritionCore/Sources/NutritionProviders/OpenFoodFactsClient.swift` |

`OpenFoodFactsClient` takes a `monotonic` clock, defaulting to
`ProcessInfo.processInfo.systemUptime`, and uses it to measure elapsed time for
its own rate limiting: Open Food Facts allows 100 product reads per minute and
the client stays at 15, dropping lookups older than a 60 second window. Reason
35F9.1 covers measuring the amount of time that elapses inside the app between
events that happened in the app, which is exactly this. Wall-clock time
(`Date()`) is used separately for the request's `last_modified_t` handling,
where a real timestamp is what matters.

## Keeping it honest

`scripts/check_privacy_manifest.py` scans every `*.swift` file under `ios/` for
the required-reason APIs Apple lists, ignoring comments and string literals, and
fails when a category a source uses is not declared in the manifest with a
reason this project is entitled to, or when `NSPrivacyTracking` is not false.
The categories it knows are:

| Category | Reason expected | API spellings |
| --- | --- | --- |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | `UserDefaults`, `@AppStorage` |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` | `systemUptime`, `mach_absolute_time` |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | `creationDate`, `modificationDate`, `attributesOfItem` |
| `NSPrivacyAccessedAPICategoryDiskSpace` | `E174.1` | `volumeAvailableCapacity`, `systemFreeSize` |
| `NSPrivacyAccessedAPICategoryActiveKeyboards` | `54BD.1` | `activeInputModes` |

Findings print one per line as `path:line: message` and the script exits 1.
`.github/workflows/ios.yml` runs it, and its tests, in the `privacy-manifest`
job next to the Swift build jobs. When a new use of one of these APIs lands,
the check fails until the manifest and this table say why the reason applies.