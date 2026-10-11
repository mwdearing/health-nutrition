-- The pre-migration five-account row is demoted in place as a community aggregate, never bulk-approved.
\set ON_ERROR_STOP on
create or replace function pg_temp.check(ok boolean, msg text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', msg; end if;
end $$;
select pg_temp.check((select not verified and supporting_devices = 5
  from catalog.entries where barcode = '0123456070004' and basis = 'per_100g'),
  'upgrade demotes the old automatic verified row');
select pg_temp.check(not exists (select 1 from catalog.approved_entries),
  'upgrade does not bulk-promote legacy rows into approved snapshots');
select pg_temp.check(exists (select 1 from catalog.rejections where barcode = '0123456070110'
  and basis = 'per_100g' and reason = 'preexisting upgrade fixture'),
  'upgrade preserves a pre-existing rejection');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000009001', false);
select set_config('request.jwt.claims', '{"is_anonymous": false}', false);
set role authenticated;
select pg_temp.check((select not verified and product_name = 'Legacy Oat Bar'
  from public.lookup_label('0123456070004')),
  'legacy lookup exposes the upgraded row only as unverified community data');
select pg_temp.check((select not verified and verification_source = 'community'
  from public.lookup_label_v2('0123456070004')),
  'v2 lookup reports the upgraded row as community and unverified');
reset role;
