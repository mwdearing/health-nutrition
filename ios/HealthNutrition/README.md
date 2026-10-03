# HealthNutrition (iOS app)

The iOS app target. It is a thin shell: the screens come from the `NutritionUI` library and the
data from the `NutritionJournal` store, both in the `NutritionCore` Swift package in
`../NutritionCore`.

The app has no network access and no HealthKit capability yet. HealthKit arrives later, together
with the spike that measures write latency.

## What the target contains

- `project.yml`: the XcodeGen spec for the `HealthNutrition` app (iOS 18, Swift 5 language mode).
- `Sources/HealthNutritionApp.swift`: the app entry point. It creates one `SwiftDataJournalStore`
  and one `SwiftDataFavoritesStore` for the app's lifetime and hands them to the screens. One
  store instance per database file is required: the store serializes writes with a lock that
  belongs to the instance, so two instances on the same file would assign duplicate revision
  numbers (see [docs/journal-store.md](../../docs/journal-store.md)).
- `Sources/RootView.swift`: the tab shell with Today, Journal and Library.
- `Sources/AppServices.swift`: the store and view model setup.
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

## Checks

CI has two jobs: `swift-test` runs the package tests in `ios/NutritionCore`, and `app-build`
installs XcodeGen, generates this project and runs an unsigned
`xcodebuild ... -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
