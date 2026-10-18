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

`NSPrivacyCollectedDataTypes` currently declares four types. All four are
linked to the user, not used for tracking, and used for app functionality:

| Manifest data type | Data the app handles |
| --- | --- |
| `NSPrivacyCollectedDataTypeEmailAddress` | The email address used for an account or email-code sign-in. |
| `NSPrivacyCollectedDataTypeUserID` | The community account identifier. |
| `NSPrivacyCollectedDataTypeName` | The optional display name on the account profile. |
| `NSPrivacyCollectedDataTypeOtherUserContent` | Product-label facts submitted to the community catalog while sharing is on: product name, brand, barcode, serving text and nutrient amounts. |

The local journal is not uploaded as a journal. A barcode lookup sends the
barcode to Open Food Facts only after the person asks for a lookup; when that
source has no product, a signed-in person also gets a community-catalog lookup,
even when label sharing is off. See [the privacy statement](../PRIVACY.md) and
[account behavior](accounts.md). A signed-out lookup does not call the
authenticated community catalog, but Open Food Facts and an email sign-in
challenge are separate requests to external services.

A name search in Find products sends only the words the person typed (2 to 80
characters) to the Open Food Facts search service (`search.openfoodfacts.org`,
`/search`) and, in builds that carry a USDA key, to USDA FoodData Central
(`api.nal.usda.gov`, `/fdc/v1/foods/search`) when they submit the field, and
nothing else from the device. The USDA key travels in a request header, never in
the URL. Words typed in Thai script also send the language code `th` to Open
Food Facts, read from the words. Opening one of the results sends nothing: the
form is filled from the reply already received. It works signed out and is
limited to six Open Food Facts searches a minute.
The screen says so beside the results; supplements are not searched there.
When the person starts entering an amount for a USDA food, the app asks USDA for
that food's record (`api.nal.usda.gov`, `/fdc/v1/food/{fdcId}`) to read its cup,
tablespoon and teaspoon weights. The request carries only the USDA food id and
the USDA key in a header; no amount, name or other entry data is sent, and a
failed request only means those units are not offered.

The HealthRelay destination is unavailable in this version. After the person
connects Apple Health in Settings and allows it, nutrients from
real logged food and water entries are written to HealthKit on the device. That
is not data collection: nothing leaves the phone. The app reads back the
samples it wrote itself, to replace or remove them after an edit or delete, and,
only after the person asks on Today, their steps, active energy and weight. When the person connects Apple Health, the app also asks to read the nutrient types it
writes. Once the totals use that access, they will include nutrition other apps logged.
Those readings will stay on the phone and will not be sent anywhere.
A debug build's
HealthKit screen can also write separate test samples.
Erasing local journal rows does not remove HealthKit samples already written.
Photos and personal intake details such as amounts eaten, meal and time are not
sent with label submissions. Nothing is sold or used for tracking.

## Declared required-reason APIs

The shipped manifest declares two required-reason API categories:

| Category | Reason | Where the code uses it |
| --- | --- | --- |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` | `ios/NutritionCore/Sources/NutritionProviders/OpenFoodFactsClient.swift` |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | App display, reminder and disclosure preferences, and saved meals kept on this phone. |

`OpenFoodFactsClient` takes a `monotonic` clock, defaulting to
`ProcessInfo.processInfo.systemUptime`, and uses it to measure elapsed time for
its own rate limiting: Open Food Facts publishes 15 product reads per minute and
the client stays at 10, dropping lookups older than a 60 second window. Reason
35F9.1 covers measuring the amount of time that elapses inside the app between
events that happened in the app, which is exactly this. Wall-clock time
(`Date()`) is used separately for the request's `last_modified_t` handling,
where a real timestamp is what matters.

## The widget extension

The Today widget extension ships its own `ios/HealthNutrition/Widgets/PrivacyInfo.xcprivacy`. It declares no collected
data types and no required-reason APIs, and `NSPrivacyTracking` is `false`. The summary the widget shows never
leaves the device, so there is nothing to declare; the app's manifest declares nothing for it either. The extension
reads one small summary file from the App Group container and has no network access, no preferences and no clock
measurement. The summary file is left out of device backups and is cleared on erase (see [Widgets](widgets.md)).

## The Watch app and its widgets

The Watch app and the Watch widget extension each ship their own manifest (`Watch/PrivacyInfo.xcprivacy`,
`WatchWidgets/PrivacyInfo.xcprivacy`). Neither collects data and tracking is `false`: the summary comes from the
paired phone and stays on the Watch. The widget extension declares no required-reason APIs, like the phone's. The
Watch app declares `UserDefaults` with reason `CA92.1` because it keeps one number there, the highest erase
generation it has applied, for its own function. The receiver that uses it is compiled into the Watch app and the
phone app but not into either widget extension, which is pinned by a repo test.

## Keeping it honest

`scripts/check_privacy_manifest.py` scans the Swift code the app actually ships
for the required-reason APIs Apple lists, and fails when a category a source uses
is not declared with a reason Apple publishes for it, when a declaration is
malformed (an unknown category, an empty reasons array, a reason that is not a
string), when a declared reason is not one Apple publishes (a typo such as an
extra `BOGUS`, or a reason belonging to another category), or when
`NSPrivacyTracking` is not false. It also fails when one of the four collected
data types is missing, or is declared without linkage to the user, with
tracking on, or without the app-functionality purpose.

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

## Categories supported by the checker

The checker recognizes the categories below. The first two are the only
categories in the current manifest; the remaining rows describe scanner
coverage and are not manifest declarations.

| Category | Expected reason when the category is used | Published reasons accepted | API spellings |
| --- | --- | --- | --- |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | `CA92.1`, `1C8F.1`, `C56D.1`, `AC6B.1` | `UserDefaults`, `@AppStorage` |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` | `35F9.1`, `8FFB.1`, `3D61.1` | `systemUptime`, `mach_absolute_time` |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | `DDA9.1`, `C617.1`, `3B52.1`, `0A2A.1` | `FileAttributeKey.creationDate`/`.modificationDate`, `URLResourceKey.creationDateKey`/`contentModificationDateKey`, an attribute subscript such as `attributes[.creationDate]`, `attributesOfItem`, `stat`, `fstat`, `lstat`, `fstatat`, `getattrlist`, `getattrlistbulk`, `getattrlistat`, `fgetattrlist` |
| `NSPrivacyAccessedAPICategoryDiskSpace` | `E174.1` | `85F4.1`, `E174.1`, `7D9E.1`, `B728.1` | `statfs`, `fstatfs`, `statvfs`, `fstatvfs`, `volumeAvailableCapacity…`, `volumeTotalCapacityKey`, `systemSize`, `systemFreeSize` |
| `NSPrivacyAccessedAPICategoryActiveKeyboards` | `54BD.1` | `3EC4.1`, `54BD.1` | `activeInputModes` |

The reason codes above are the ones Apple publishes per category; anything else
is rejected, so a manifest cannot carry a code the store would refuse. Apple's
disk-space category holds the `statfs`/`statvfs` family and the volume-capacity
keys, while the `getattrlist` family belongs to the file-timestamp category
alongside `stat`, `fstat`, `lstat` and `fstatat`.

The timestamp row matches real file metadata access only. A domain property that
merely happens to be called `creationDate` or `modificationDate` is not an access
to Apple's API and does not match, so a false positive can never be silenced by
adding an inaccurate `C617.1` declaration.

`//` comments, `/* */` comments and the text of string literals are masked
before matching, including the raw and extended literal forms and escaped
delimiters such as `"say \"UserDefaults.standard\" only"`. An interpolated
expression is code and is scanned as such, so `"defaults: \(UserDefaults.standard)"`
is matched, while everything up to the opening parenthesis and everything after
the closing one stays literal text, so `"\(value) UserDefaults"` is not.

Findings print one per line as `path:line: message` and the script exits 1.
`.github/workflows/ios.yml` runs it, and its tests, in the `privacy-manifest`
job next to the Swift build jobs. When a new use of one of these APIs lands,
the check fails until the manifest and this table say why the reason applies.

## Inactive app screen

When a scene is inactive or backgrounded, a scene-scoped opaque UIKit window covers its tabs and
presented sheets. The app installs it on `UIScene.willDeactivateNotification`, before UIKit captures
the app-switcher preview, and removes it only after SwiftUI reports that same scene active again.
Each notification is matched to the scene that owns the window, so activity in another app window
does not cover this one. The shield does not become key; authentication presentation remains owned
by the system. The simulator UI test uses synthetic text and deactivates the scene with Notification
Center; the simulator draws system UI over the app, so the test reads a counter of how often the
shield was raised and checks the sheet is restored. The real app-switcher preview is checked on a
physical device. Its synthetic authentication-return sheet checks that a modal remains available
after return; it does not launch a live sign-in or CAPTCHA flow.
