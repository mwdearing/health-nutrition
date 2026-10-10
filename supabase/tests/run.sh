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
