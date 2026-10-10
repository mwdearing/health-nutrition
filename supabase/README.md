# Supabase backend

Community label catalog (see `migrations/`). Labels are submitted by devices that opted in, by nutrient values only, and a label is verified when enough distinct devices agree. Only verified labels are readable.

- Tables live in the private `catalog` schema (not exposed by the API, row-level security on, no policies). The app uses three functions in `public`: `submit_label`, `lookup_label`, `withdraw_my_submissions`, all for signed-in (anonymous sign-in) users only.
- Tunables are one row in `catalog.settings`: `min_devices` (5), `tolerance_percent` (2), `daily_limit` (60).
- Moderation: insert a row into `catalog.rejections` (barcode, basis) as the project owner; the label is never verified.
- Test: `supabase/tests/run.sh` (needs podman or docker).
