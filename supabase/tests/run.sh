#!/usr/bin/env bash
# Applies the migrations to a throwaway Postgres 17 (podman or docker) with a stubbed auth.uid() and runs the
# behavior test. Usage: supabase/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
engine=$(command -v podman || command -v docker)
name=catalog-test-$$
"$engine" run -d --rm --name "$name" -e POSTGRES_PASSWORD=x docker.io/library/postgres:17-alpine >/dev/null
trap '"$engine" rm -f "$name" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 40); do "$engine" exec "$name" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 2; done
sleep 3
psql_() { "$engine" exec -i "$name" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
psql_ -f - < supabase/tests/stub.sql
for f in supabase/migrations/*.sql; do psql_ -f - < "$f"; done
psql_ -f - < supabase/tests/community_catalog.sql

# Exercise the forward migration against the pre-migration schema in a second database within the same disposable
# Postgres container. This reproduces a verified legacy row before applying the upgrade.
upgrade_db=catalog_upgrade
upgrade_migration=supabase/migrations/20261011203625_catalog_owner_verification.sql
"$engine" exec "$name" createdb -U postgres "$upgrade_db"
psql_upgrade_() { "$engine" exec -i "$name" psql -U postgres -d "$upgrade_db" -v ON_ERROR_STOP=1 -q "$@"; }
psql_upgrade_ -f - < supabase/tests/upgrade_owner_verification_stub.sql
found_upgrade_migration=0
for f in supabase/migrations/*.sql; do
  if [[ "$f" == "$upgrade_migration" ]]; then
    found_upgrade_migration=1
    break
  fi
  psql_upgrade_ -f - < "$f"
done
if [[ "$found_upgrade_migration" != 1 ]]; then
  echo "upgrade migration not found: $upgrade_migration" >&2
  exit 1
fi
psql_upgrade_ -f - < supabase/tests/upgrade_owner_verification_seed.sql
if upgrade_red_output=$(psql_upgrade_ -f - < supabase/tests/upgrade_owner_verification_red.sql 2>&1); then
  echo "pre-migration RED assertion unexpectedly passed" >&2
  exit 1
fi
if [[ "$upgrade_red_output" != *"FAILED: pre-upgrade community row is still automatically verified"* ]]; then
  printf '%s\n' "$upgrade_red_output" >&2
  echo "pre-migration RED assertion failed for an unexpected reason" >&2
  exit 1
fi
echo "RED reproduced: the seeded legacy community entry is automatically verified before upgrade"
psql_upgrade_ -f - < "$upgrade_migration"
psql_upgrade_ -f - < supabase/tests/upgrade_owner_verification_green.sql
echo "Upgrade path OK"
