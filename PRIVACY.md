# Privacy

Health Nutrition is a local journal for food, supplements and water. What you log stays on your iPhone unless you turn on a destination yourself.

- **Where data lives.** Entries, product snapshots, recipes and goals are stored in the app's own database on the device. There is no account, no sign-in and no server run by the project that receives your journal. Like any app data, the database is included in your iCloud Backup or computer backup if you have those turned on; it is covered by Apple's or your own backup protection, not by the project.
- **Apple Health.** Writing nutrients to Apple Health is not available in this version: the switch under Connections is present but cannot be turned on, and nothing is written or read. When a later version enables it, the app will write only the nutrients of the entries you log, will be able to remove what it wrote, and will not read your other Health data; access can be revoked in the Health app (profile picture > Privacy > Apps > Health Nutrition).
- **Your own receiver.** The HealthRelay destination is also not available in this version. When enabled in a later version it will send intake context only to a receiver you run and pair with; the project operator has no receiver of yours.
- **Barcode lookups.** Scanning or typing a barcode only fills in the field. When you tap Look up, the barcode alone is sent to Open Food Facts (world.openfoodfacts.org) to fetch label facts; no amounts, times or identity go with it, and nothing is sent if you do not tap Look up.
- **Label scanning.** Nutrition Facts and Supplement Facts panels are read on the device. Camera frames are used for the barcode and the panel text and are not stored or sent. A planned option to share scanned product facts (the label's own numbers, never your amounts, times or identity) with a community catalog is not active in this build; when it ships it will be announced in the app and can be turned off under Settings > Privacy.
- **No telemetry.** There is no analytics, advertising, crash-reporting upload or AI upload in the app.
- **Export and deletion.** You can export your journal to a file you keep, import it on another device, and erase all data in the app.

Questions or concerns: open an issue at https://github.com/mwdearing/health-nutrition/issues (never include real health data). Security reports: see [SECURITY.md](SECURITY.md).
