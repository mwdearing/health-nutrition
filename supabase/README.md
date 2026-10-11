# Supabase backend

Community label catalog (see `migrations/`). Labels are submitted by signed-in accounts that have sharing on, as nutrient values only. A label is shown to other people once 2 accounts agree, and carries the verified badge once 5 agree within 2 percent. A single submission is never shown. Agreement is checked against the shown value, so every counted account is within tolerance of it, and at most the 100 newest submissions per label are considered.

- Tables live in the private `catalog` schema (not exposed by the API, row-level security on, no policies). The app uses three functions in `public`: `submit_label`, `lookup_label`, `withdraw_my_submissions`, all for signed-in accounts only (anonymous sign-ins are refused).
- Tunables are one row in `catalog.settings`: `min_devices` (5), `tolerance_percent` (2), `daily_limit` (60).
- Moderation: insert a row into `catalog.rejections` (barcode, basis) as the project owner; the label is never verified.
- Test: `supabase/tests/run.sh` (needs podman or docker).

## Configuration
`config.toml` mirrors the hosted Auth settings (Apple on, email confirmation on, six-digit email codes, anonymous sign-ins off). `supabase config push` applies it to the project at once and has no confirmation step, so run it only when the file matches what you want live, with the Apple secret supplied as the `SUPABASE_AUTH_EXTERNAL_APPLE_SECRET` environment variable. Email templates cannot be changed on the free plan with the default mail service; a custom mail sender is needed first.
