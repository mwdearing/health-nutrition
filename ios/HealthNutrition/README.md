# HealthNutrition (iOS app)

The iOS app target. It is a thin shell: the screens come from the `NutritionUI` library and the
data from the `NutritionJournal` store, both in the `NutritionCore` Swift package in
`../NutritionCore`.

The app makes one kind of network request: a barcode lookup in Add intake, when the user asks for
one. Nothing else leaves the device, and no request is sent while the user is typing. The lookup
reads a single product from Open Food Facts and nothing is sent back; see
[docs/providers/open-food-facts.md](../../docs/providers/open-food-facts.md) for the fields read, the
rate limits honoured and the attribution the licence requires.

HealthKit arrives as a debug-only spike first
(`Sources/Debug/HealthKitSpikeView.swift`, see [ADR 0002](../../docs/adr/0002-healthkit-sync.md)): the target
declares the capability and the usage strings, but nothing in a release build reads or writes health data.

## What the target contains

- `project.yml`: the XcodeGen spec for the `HealthNutrition` app (iOS 18, Swift 5 language mode).
- `HealthNutrition.entitlements`: the HealthKit capability. No signing team id, certificate or
  profile is ever committed here.
- `Sources/HealthNutritionApp.swift`: the app entry point. It creates one `SwiftDataJournalStore`
  and one `SwiftDataFavoritesStore` for the app's lifetime and hands them to the screens. One
  store instance per database file is required: the store serializes writes with a lock that
  belongs to the instance, so two instances on the same file would assign duplicate revision
  numbers (see [docs/journal-store.md](../../docs/journal-store.md)).
- `Sources/RootView.swift`: the tab shell with Today, Journal and Library, plus a HealthKit tab in
  debug builds only.
- `Sources/Debug/HealthKitSpikeView.swift`: the debug-only HealthKit write spike, whole file inside
  `#if DEBUG`. It writes synthetic samples to measure how HealthKit resolves a repeated sync
  identifier, and deletes them again.
- `Sources/AppServices.swift`: the store and view model setup, including the barcode lookup client the
  app shares for its lifetime.
- `Sources/BarcodeLookup.swift`: the adapter between the nutrition-data client and the lookup protocol
  the screens depend on. The screens never see the client or the source; this file fills in the
  attribution and serving definition that a licensed source requires.
- `Resources/Assets.xcassets`: an empty `AppIcon` and an `AccentColor`.

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

## Getting an unsigned build to install

Builds are unsigned until App Store release time. Nothing in this repository holds signing
material, and CI never signs anything.

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

The other two jobs (`swift-test` and `app-build`) run on pull requests and pushes to `main`, and
`app-build` produces a simulator build only, which needs no signing at all.

## Checks

CI has three jobs. `swift-test` runs the package tests in `ios/NutritionCore`, `app-build`
installs XcodeGen, generates this project and runs an unsigned
`xcodebuild ... -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`, and
`unsigned-ipa` is the manual device build described above.
