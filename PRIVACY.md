# Privacy

Health Nutrition is a local journal for food, supplements and water. What you log stays on your iPhone unless you turn on a destination yourself.

- **Where data lives.** Entries, product snapshots, recipes and goals are stored in the app's own database on the device. There is no account, no sign-in and no server run by the project that receives your journal.
- **Apple Health.** Writing nutrients to Apple Health is a destination you can enable in the app; until then nothing is written. When enabled, the app writes only the nutrients of the entries you log and can remove what it wrote. It does not read your other Health data. You can revoke access in the Health app (profile picture > Privacy > Apps > Health Nutrition).
- **Your own receiver.** The optional HealthRelay destination sends intake context only to a receiver you run and pair with. It is off by default; the project operator has no receiver of yours.
- **Barcode lookups.** When you scan or type a barcode, the barcode alone is sent to the public product database you chose (Open Food Facts, or the NIH Dietary Supplement Label Database for supplements) to fetch label facts. No amounts, times or identity go with it.
- **Label scanning.** Nutrition Facts and Supplement Facts panels are read on the device. Camera frames are used for the barcode and the panel text and are not stored or sent. A planned option to share scanned product facts (the label's own numbers, never your amounts, times or identity) with a community catalog is not active in this build; when it ships it will be announced in the app and can be turned off under Settings > Privacy.
- **No telemetry.** There is no analytics, advertising, crash-reporting upload or AI upload in the app.
- **Export and deletion.** You can export your journal to a file you keep, import it on another device, and erase all data in the app.

Questions or concerns: open an issue at https://github.com/mwdearing/health-nutrition/issues (never include real health data). Security reports: see [SECURITY.md](SECURITY.md).
