# Health Nutrition

A native iOS app for a local food, supplement and hydration journal. This repository also contains the foundations for a shared catalog and optional HealthRelay intake-context integration.

## Implemented

- Today, quick-add water, Add intake, Journal, entry detail and Library screens
- Local SwiftData persistence with immutable revisions, product snapshots and destination outbox operations
- Favorites, recents, repeat entries and versioned personal recipes
- Versioned journal export and import, plus local data deletion
- On-demand barcode lookup, Nutrition Facts label capture and confirmation, and NIH DSLD provider components
- HealthKit write planning and a delivery worker, with a debug-only device spike
- Intake-context canonical JSON, digest calculation and journal-revision encoding
- Swift package and app-target tests, source lint, privacy checks and unsigned build workflows
- A manual, reviewer-gated signed-upload workflow for beta builds

See the [documentation index](docs/README.md) for behavior, limitations and architecture decisions, and the [app target guide](ios/HealthNutrition/README.md) for builds and installation.

## Getting the app

Health Nutrition is not on the App Store. Signed beta builds go out through TestFlight: open a [Beta access request](https://github.com/mwdearing/health-nutrition/issues/new?template=beta_access.yml) and you will get the next step in that issue. GitHub Releases do not carry IPA files. If you would rather build it yourself, the manual `unsigned-ipa` workflow job and the Xcode instructions in the [app target guide](ios/HealthNutrition/README.md) remain available.

## Integration and release status

The app keeps both HealthKit and HealthRelay destinations disabled. Implemented planners, workers and encoders do not establish enabled end-to-end delivery or device acceptance. The debug-only HealthKit spike is separate from normal journal delivery. See the [writer lifecycle](docs/healthkit-writer.md) and [intake-context contract](docs/intake-context.md).

The shared catalog service and community publishing remain planned work. Provider clients and fixtures do not establish a deployed shared service. Pull-request and push CI builds are unsigned; the signed beta workflow is manual and reviewer-gated, and public distribution still requires separate privacy, compatibility and release verification.

Use synthetic examples in public discussions and contributions. Do not publish personal health data, credentials or private deployment details.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
