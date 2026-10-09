# HealthNutrition (iOS app)

The iOS app target. It is a thin shell: the screens come from the `NutritionUI` library and the
data from the `NutritionJournal` store, both in the `NutritionCore` Swift package in
`../NutritionCore`.

The app makes one kind of network request: a barcode lookup in Add intake, when the user asks for
one. Nothing else leaves the device, and no request is sent while the user is typing. The lookup
reads a single product from Open Food Facts and nothing is sent back; see
[docs/providers/open-food-facts.md](../../docs/providers/open-food-facts.md) for the fields read, the
rate limits honored and the attribution the license requires.

The target includes the journal's HealthKit planner and delivery worker. A release build's
`AppServices` keeps both HealthKit and HealthRelay destinations disabled, so a normal journal save
queues no external delivery at all. See the [writer lifecycle](../../docs/healthkit-writer.md) for retry
and deletion behavior.

A debug build enables the HealthKit destination only, so the real worker can be exercised on a device
against real entries (`Sources/Debug/HealthKitDeliveryDebug.swift`): a section that requests write access
for every mapped type, runs one delivery pass, and reports the queue and the last run's outcomes. The
HealthRelay destination stays off in every build. The separate debug-only spike
(`Sources/Debug/HealthKitSpikeView.swift`) records the device observations in
[ADR 0002](../../docs/adr/0002-healthkit-sync.md). Release builds contain neither surface.

## What the target contains

- `project.yml`: the XcodeGen spec for the `HealthNutrition` app (iOS 18, Swift 5 language mode).
- `HealthNutrition.entitlements`: the HealthKit capability. No signing team id, certificate or
  profile is ever committed here.
- `Sources/HealthNutritionApp.swift`: the app entry point. It creates one `SwiftDataJournalStore`,
  one `SwiftDataFavoritesStore` and one `SwiftDataRecipeStore` for the app's lifetime and hands them
  to the screens. One
  store instance per database file is required: the store serializes writes with a lock that
  belongs to the instance, so two instances on the same file would assign duplicate revision
  numbers (see [docs/journal-store.md](../../docs/journal-store.md)).
- `Sources/RootView.swift`: the tab shell with Today, Journal and Library, plus a HealthKit tab in
  debug builds only. Library opens the personal recipes in its own navigation stack
  (see [docs/recipes.md](../../docs/recipes.md)).
- `Sources/RecipeNavigation.swift`: the recipe sheet's presentation and navigation stack on one small
  `@MainActor` object, so the erase on the Connections and privacy screen can close the sheet and drop
  its routes without a UI test.
- `Sources/Debug/HealthKitDeliveryDebug.swift`: the debug-only driver for the real HealthKit delivery
  worker, whole file inside `#if DEBUG`. It asks HealthKit for write access to every type in
  `HealthKitWritePlanner.mappings`, runs `healthKitDelivery.runOnce(now:)` on the app becoming active
  and after every journal change, and shows the pending, needing-attention and suspended counts plus
  the last run's outcome list. Today shows the same counts as one line. Nothing here changes the
  worker, the writer or any journal behavior.
- `Sources/Debug/HealthKitSpikeView.swift`: the debug-only HealthKit write spike, whole file inside
  `#if DEBUG`. It writes synthetic samples to measure how HealthKit resolves a repeated sync
  identifier, and deletes them again. Its sections share the HealthKit tab with the delivery driver
  above.
- `Sources/AppServices.swift`: the store and view model setup, including the barcode lookup client the
  app shares for its lifetime.
- `Sources/BarcodeLookup.swift`: the adapter between the nutrition-data client and the lookup protocol
  the screens depend on. The screens never see the client or the source; this file fills in the
  attribution and serving definition that a licensed source requires.
- `Resources/Assets.xcassets`: an `AccentColor` and a placeholder `AppIcon` (a single 1024-point image, the accent color with a plain mark) so a signed archive can be uploaded; replace it with the real icon when there is one.
- `Tests/`: the app target's own XCTest bundle, hosted by the app so `@testable import HealthNutrition`
  works. See [Running the tests](#running-the-tests).

## Generating the project

There is no `.xcodeproj` in the repository. Generate one from the spec:

```sh
cd ios/HealthNutrition
brew install xcodegen
xcodegen generate
open HealthNutrition.xcodeproj
```

Re-run `xcodegen generate` after you change `project.yml`. Never commit the generated project; it
is ignored by git and CI regenerates it.

## Running on a device

CI builds without signing, so the app runs in the iOS Simulator with no setup. To run it on an
iPhone you need your own signing team:

1. Open the generated `HealthNutrition.xcodeproj`, select the `HealthNutrition` target, then
   **Signing & Capabilities**.
2. Tick **Automatically manage signing**, choose your Apple ID under **Team**, and pick your
   device or a registered device destination.
3. Set the bundle identifier to something unique to you if the default one is already taken by
   another team.

The team is a local setting in Xcode and is deliberately not committed: `project.yml` never sets
`DEVELOPMENT_TEAM`, so every developer signs with their own account. If you do add a team id to
the generated project, keep it there and do not copy it into `project.yml` or any committed file.

## Getting a build to install

Most people should ask for a signed beta build instead of building one: open a
[Beta access request](https://github.com/mwdearing/health-nutrition/issues/new?template=beta_access.yml)
issue. Signed uploads come from the manual `signed-beta` workflow, which runs only on `main`
behind a reviewer-approved environment; the key material lives in that environment's secrets
and never in the repository. GitHub Releases do not carry IPA files.

The rest of this section is the self-build path. Nothing in this repository holds signing
material, and the regular CI jobs never sign anything.

To get a device build, run the workflow by hand: **Actions > ios > Run workflow**. Inputs:

- `bundle_id` (default `dev.example.HealthNutrition`, a placeholder: enter your own bundle identifier when you run the workflow, matching the provisioning profile you sign with)
- `configuration` (default `Release`, or `Debug` for the HealthKit spike, which only exists in
  debug builds)
- `marketing_version` (default empty, which uses `0.1.<run number>`)

That runs the `unsigned-ipa` job, which only ever runs on `workflow_dispatch`. It generates the
project with XcodeGen, builds for `iphoneos` with `CODE_SIGNING_ALLOWED=NO`, and uploads two
artifacts:

- `HealthNutrition-unsigned.ipa`
- `HealthNutrition-unsigned.ipa.sha256` (the checksum of the ipa)

The ipa is **unsigned**, so it will not install as it is. Sign it yourself (AltStore, SideStore,
a free or paid Apple developer certificate, your own provisioning profile) and then sideload it
on your iPhone. Do not commit any certificate, profile or team id while doing so.

The other jobs (`swift-test`, `app-build` and `app-test`) run on pull requests and pushes to
`main`, and `app-build` produces a simulator build only, which needs no signing at all.

## Running the tests

The app target has its own test bundle, `Tests/`, which is hosted by the app: the tests read the
app's own types through `@testable import HealthNutrition`, which is what makes the erase reset and
the store wiring testable without a UI test. Each test builds `AppServices` on its own throwaway
files in a temporary directory, so no test reads or writes the app's real Application Support
directory and no two tests share a store.

```sh
cd ios/HealthNutrition
xcodegen generate
xcodebuild -project HealthNutrition.xcodeproj -scheme HealthNutrition \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO test
```

Name a simulator that is actually installed on the machine;
`xcrun simctl list devices available` lists them. In Xcode, select the `HealthNutritionTests` bundle
in the Test navigator and press Run.

## Checks

CI has five jobs. `swift-test` runs the package tests in `ios/NutritionCore`, `app-build`
installs XcodeGen, generates this project and runs an unsigned
`xcodebuild ... -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`,
`app-test` does the same and then runs
`xcodebuild ... -destination 'platform=iOS Simulator,name=<picked at run time>' CODE_SIGNING_ALLOWED=NO test`
for the app tests above, `privacy-manifest` checks the privacy manifest against the Swift sources,
and `unsigned-ipa` is the manual device build described above.
