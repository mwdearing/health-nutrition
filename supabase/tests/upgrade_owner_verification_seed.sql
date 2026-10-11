-- Synthetic legacy state for applying the owner-verification migration as an upgrade.
\set ON_ERROR_STOP on
create or replace function pg_temp.as_upgrade_device(n int) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0')), false);
  perform set_config('request.jwt.claims', '{"is_anonymous": false}', false);
  perform set_config('role', 'authenticated', false);
end $$;

insert into auth.users (id)
select ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
from generate_series(9001, 9005) n;
select pg_temp.as_upgrade_device(9001);
select public.submit_label('0123456070004','per_100g',null,'Legacy Oat Bar','Old Brand',
  '{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}'::jsonb);
select pg_temp.as_upgrade_device(9002);
select public.submit_label('0123456070004','per_100g',null,'Legacy Oat Bar','Old Brand',
  '{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}'::jsonb);
select pg_temp.as_upgrade_device(9003);
select public.submit_label('0123456070004','per_100g',null,'Legacy Oat Bar','Old Brand',
  '{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}'::jsonb);
select pg_temp.as_upgrade_device(9004);
select public.submit_label('0123456070004','per_100g',null,'Legacy Oat Bar','Old Brand',
  '{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}'::jsonb);
select pg_temp.as_upgrade_device(9005);
select public.submit_label('0123456070004','per_100g',null,'Legacy Oat Bar','Old Brand',
  '{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}'::jsonb);
reset role;
do $$ begin
  if not exists (select 1 from catalog.entries where barcode = '0123456070004'
      and basis = 'per_100g' and supporting_devices = 5 and verified) then
    raise exception 'upgrade seed failed to establish a verified five-account legacy entry';
  end if;
end $$;

-- A separate pre-existing rejection must remain active through the upgrade.
insert into catalog.rejections (barcode, basis, reason)
values ('0123456070110', 'per_100g', 'preexisting upgrade fixture');
