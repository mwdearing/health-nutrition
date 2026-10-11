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
for f in supabase/migrations/*.sql; do
  if [[ "$f" == *shared_products_v2.sql ]]; then
    if [[ -n ${CATALOG_OWNER_MIGRATION:-} ]]; then psql_ -f - < "$CATALOG_OWNER_MIGRATION"; fi
    if [[ ${CATALOG_TEST_SEEDED:-0} == 1 ]]; then
      psql_ -f - <<'SQL'
insert into auth.users(id) values ('30000000-0000-4000-8000-000000000001'),('30000000-0000-4000-8000-000000000002');
set role authenticated;
set request.jwt.claim.sub='30000000-0000-4000-8000-000000000001';
select public.submit_label('96385074','per_100g',null,'Synthetic upgrade seed',null,'{"protein":3,"fat":2,"salt":1}');
set request.jwt.claim.sub='30000000-0000-4000-8000-000000000002';
select public.submit_label('96385074','per_100g',null,'Synthetic upgrade seed',null,'{"protein":3,"fat":2,"salt":1}');
reset role;
insert into catalog.rejections(barcode,basis) values('4006381333931','per_100g');
SQL
    fi
  fi
  if [[ "$f" == *shared_products_v2_legacy_bridge.sql && ${CATALOG_TEST_SEEDED:-0} == 1 ]]; then
    # An already deployed v2 writer used its original ledger before the bridge.
    psql_ -f - <<'SQL'
set role authenticated;
set request.jwt.claim.sub='30000000-0000-4000-8000-000000000001';
select public.acknowledge_catalog_consent_v2(2);
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',null,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic historical v2 quota','brand',null,'barcode',null,'kind','food',
 'basis','per_100_g','serving',null,'facts','[]'::jsonb)));
reset role;
SQL
  fi
  psql_ -f - < "$f"
done
psql_ -f - < supabase/tests/shared_products_v2_resolution.sql
if [[ ${CATALOG_TEST_FOCUS:-} == resolution ]]; then
  python3 supabase/tests/shared_products_v2_resolution.py "$engine" "$name"
  exit 0
fi
if [[ ${CATALOG_TEST_FOCUS:-} != bridge && ${CATALOG_TEST_FOCUS:-} != refresh ]]; then
  psql_ -f - < supabase/tests/community_catalog.sql
  if [[ ${CATALOG_TEST_FOCUS:-} == legacy ]]; then exit 0; fi
  psql_ -f - < supabase/tests/shared_products_v2.sql
fi
python3 supabase/tests/shared_products_v2_concurrency.py "$engine" "$name"
python3 supabase/tests/shared_products_v2_resolution.py "$engine" "$name"
