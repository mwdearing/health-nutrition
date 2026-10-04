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

`scripts/check_privacy_manifest.py` scans the Swift code the app actually ships
for the required-reason APIs Apple lists, and fails when a category a source uses
is not declared with a reason Apple publishes for it, when a declared reason is
not one Apple publishes (a typo such as an extra `BOGUS`, or a reason belonging
to another category), or when `NSPrivacyTracking` is not false.

### Which code is scanned

The scope comes from the build description, not from the directory layout. The
script reads `ios/HealthNutrition/project.yml` for the app target's source paths
and the NutritionCore products it links, then `ios/NutritionCore/Package.swift`
for those products' target directories and their target dependencies. That is
`ios/HealthNutrition/Sources` plus `NutritionCore`, `NutritionDomain`,
`NutritionProviders`, `NutritionJournal` and `NutritionUI`, which is what ends
up in the app binary. Test targets and `JournalStoreSpike`, a standalone target
the app does not link, are never scanned: a restricted API used only there does
not ship and must not demand a declaration. A missing or unreadable
`project.yml` or `Package.swift` is a usage error rather than a silent full scan.

### What is matched

| Category | Reason this app declares | Published reasons accepted | API spellings |
| --- | --- | --- | --- |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | `CA92.1`, `1C8F.1`, `C56D.1`, `AC9B.1` | `UserDefaults`, `@AppStorage` |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` | `35F9.1`, `8FFB.1`, `3D61.1` | `systemUptime`, `mach_absolute_time` |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | `C617.1`, `0A2A.1`, `E9D9.1`, `3D62.1` | `FileAttributeKey.creationDate`/`.modificationDate`, `URLResourceKey.creationDateKey`/`contentModificationDateKey`, an attribute subscript such as `attributes[.creationDate]`, `attributesOfItem`, `stat`/`fstat`/`lstat` |
| `NSPrivacyAccessedAPICategoryDiskSpace` | `E174.1` | `E174.1`, `85F4.1`, `7D9E.1` | `statfs`, `statvfs`, `fstatfs`, `fstatvfs`, `getattrlist`, `getattrlistbulk`, `getattrlistat`, `fgetattrlist`, `volumeAvailableCapacity…`, `volumeTotalCapacityKey`, `systemSize`, `systemFreeSize` |
| `NSPrivacyAccessedAPICategoryActiveKeyboards` | `54BD.1` | `54BD.1`, `3EC4.1` | `activeInputModes` |

The timestamp row matches real file metadata access only. A domain property that
merely happens to be called `creationDate` or `modificationDate` is not an access
to Apple's API and does not match, so a false positive can never be silenced by
adding an inaccurate `C617.1` declaration.

`//` comments, `/* */` comments and the text of string literals are masked
before matching, including the raw and extended literal forms. An interpolated
expression is code, so `"defaults: \(UserDefaults.standard)"` is matched while
the surrounding prose is not.

Findings print one per line as `path:line: message` and the script exits 1.
`.github/workflows/ios.yml` runs it, and its tests, in the `privacy-manifest`
job next to the Swift build jobs. When a new use of one of these APIs lands,
the check fails until the manifest and this table say why the reason applies.