# Health Nutrition

A native iOS app for a local food, supplement and hydration journal. This repository also contains the foundations for a shared catalog and optional HealthRelay intake-context integration.

## Implemented

- Today, quick-add water, Add intake, Journal, entry detail and Library screens
- Local SwiftData persistence with immutable revisions, product snapshots and destination outbox operations
- Favorites, recents, repeat entries and versioned personal recipes
- Versioned journal export and import, plus Erase all data in Settings, which clears the local stores and the community session on the phone
- On-demand barcode lookup, Nutrition Facts label capture and confirmation, and NIH DSLD provider components
- Open Food Facts name search, sent only when the person submits the search field
- Optional sign-in with Sign in with Apple or an emailed one-time code, in builds that carry the project settings
- Custom products with optional barcodes, serving information and structured facts; a selected product can be shared after review, and shared products can be found by name
- Community catalog client: label submission, a barcode fallback for barcodes that Open Food Facts does not know, and product search
- Bounded response reads for the Community, Open Food Facts and NIH DSLD transports
- Apple Health: Connect in Settings writes the nutrients and water of logged entries to HealthKit, with a debug-only device spike
- Intake-context canonical JSON, digest calculation and journal-revision encoding
- Swift package and app-target tests, source lint, privacy checks and unsigned build workflows
- A manual, reviewer-gated signed-upload workflow for beta builds

See the [documentation index](docs/README.md) for behavior, limitations and architecture decisions, and the [app target guide](ios/HealthNutrition/README.md) for builds and installation.

## Getting the app

Health Nutrition is not on the App Store. Signed beta builds go out through TestFlight: open a [Beta access request](https://github.com/mwdearing/health-nutrition/issues/new?template=beta_access.yml) and you will get the next step in that issue. GitHub Releases do not carry IPA files. If you would rather build it yourself, the manual `unsigned-ipa` workflow job and the Xcode instructions in the [app target guide](ios/HealthNutrition/README.md) remain available.

## Integration and release status

Apple Health delivery is enabled in every build and starts when the person connects Apple Health in Settings; device acceptance of the release path is still separate evidence. The HealthRelay destination stays disabled. The debug-only HealthKit spike is separate from normal journal delivery. See the [writer lifecycle](docs/healthkit-writer.md) and [intake-context contract](docs/intake-context.md).

The shared catalog backend is in source: Supabase migrations, row-level security and tests under `supabase/`, and the app's community client. The repository does not show that these migrations are applied to a hosted project, so no hosted shared service is established here. Community agreement never verifies a label; only an explicit owner review does. Shared custom products are implemented in source; the [0.1.17 release note](docs/releases/0.1.17-shared-products.md) records the deployment, validation and release status it was written with, and [the backend README](supabase/README.md) explains why checked-in configuration is not evidence of hosted state. Provider clients and fixtures do not establish a deployed shared service. Pull-request and push CI builds are unsigned; the signed beta workflow is manual and reviewer-gated, and public distribution still requires separate privacy, compatibility and release verification.

A source change is only implemented in source. Compilation in CI, device acceptance, enablement and release are separate states, and each needs its own evidence.

## Repository layout

- `.github/`: issue templates, the CODEOWNERS file and the CI workflows
- `catalog/`: the Python catalog package, its tests and its lock file
- `contracts/`: shared JSON schemas, fixtures and provider manifests
- `docs/`: public design notes, decision records and release notes, indexed in [docs/README.md](docs/README.md)
- `ios/`: the Swift package `NutritionCore` and the `HealthNutrition` app target
- `scripts/`: source lint, privacy checks, design-system helpers and their tests
- `supabase/`: the backend migrations, configuration and database tests

Use synthetic examples in public discussions and contributions. Do not publish personal health data, credentials or private deployment details.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
