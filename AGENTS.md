# Contributing rules (for people and automated tools)

This repository is public. Everything committed here is visible to everyone.

- Use synthetic examples and test data only.
- Never commit personal health data, credentials, tokens or private
  deployment details (hostnames, local paths, account names).
- Keep private plans and internal tool or agent instructions out of the
  repository.
- Write commit messages as plain descriptions of the change, without
  attribution trailers or tool credits.
- Tests first: add or update a failing test before the change that fixes it.
- Swift code lives in `ios/`, the Python catalog service in `catalog/`, shared
  definitions in `contracts/`, and public design notes in `docs/`.
