-- Behavior test for the community catalog migration. Runs against a plain Postgres with a stubbed auth.uid().
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/community_catalog.sql (after the stub and the migration).
\set ON_ERROR_STOP on
create or replace function pg_temp.as_device(n int) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0')), false);
  perform set_config('request.jwt.claims', '{"is_anonymous": false}', false);
  perform set_config('role', 'authenticated', false);
end $$;
create or replace function pg_temp.check(ok boolean, msg text) returns void language plpgsql as $$
begin if ok is not true then raise exception 'FAILED: %', msg; end if; end $$;

reset role;
insert into auth.users (id) select ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid from generate_series(1, 10) n;
-- Five devices send agreeing values: the fifth makes the unverified community label visible.
select pg_temp.as_device(1);
select pg_temp.check(public.submit_label('0123456070004','per_100g',null,'Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}') = 'received', 'first is received');
select pg_temp.check((select count(*) from public.lookup_label('0123456070004')) = 0, 'a single submission is not shown');
select pg_temp.as_device(2); select pg_temp.check(public.submit_label('0123456070004','per_100g',null,'Oat Bar','Acme','{"energyKcal":401,"protein":10.1,"carbohydrates":60,"fat":12}') = 'shared', 'two agreeing devices are shown without a badge');
select pg_temp.check((select not verified from public.lookup_label('0123456070004')), 'shown but not verified');
select pg_temp.as_device(3); select public.submit_label('0123456070004','per_100g',null,'Oat Bar','Acme','{"energyKcal":399,"protein":10,"carbohydrates":59.5,"fat":12}');
select pg_temp.as_device(4); select public.submit_label('0123456070004','per_100g',null,'Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}');
-- An outlier does not join the group and does not block it.
select pg_temp.as_device(6); select pg_temp.check(public.submit_label('0123456070004','per_100g',null,'Oat Bar','Acme','{"energyKcal":250,"protein":3,"carbohydrates":30,"fat":1}') = 'shared', 'outlier does not change the shown label');
select pg_temp.as_device(5);
select pg_temp.check(public.submit_label('0123456070004','per_100g',null,'Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}') = 'shared', 'fifth agreeing device remains community shared');
select pg_temp.check((select supporting_devices from public.lookup_label('0123456070004')) = 5, 'five community supporters');
select pg_temp.check((select not verified from public.lookup_label('0123456070004')), 'five accounts never verify a community label');
select pg_temp.check((select verification_source = 'community' and not verified from public.lookup_label_v2('0123456070004')), 'v2 marks five-account label as community, not verified');
select pg_temp.check((select (nutrients->>'energyKcal')::numeric from public.lookup_label('0123456070004')) = 400, 'median energy');
-- A submit_label call that began on the old function body cannot restore automatic verification after the upgrade.
reset role;
do $$ begin
  begin
    insert into catalog.entries (barcode, basis, product_name, nutrients, supporting_devices, verified)
    values ('0123456070996', 'per_100g', 'Old Writer Insert', '{"energyKcal":400,"protein":10,"fat":12}', 5, true);
  exception when check_violation then null;
  end;
  if exists (select 1 from catalog.entries where barcode = '0123456070996' and basis = 'per_100g' and verified) then
    raise exception 'FAILED: old community writer can insert a verified entry';
  end if;
end $$;
do $$ begin
  begin
    insert into catalog.entries (barcode, basis, product_name, nutrients, supporting_devices, verified)
    values ('0123456070004', 'per_100g', 'Old Writer Update', '{"energyKcal":400,"protein":10,"fat":12}', 5, true)
    on conflict (barcode, basis) do update set verified = excluded.verified;
  exception when check_violation then null;
  end;
  if exists (select 1 from catalog.entries where barcode = '0123456070004' and basis = 'per_100g' and verified) then
    raise exception 'FAILED: old community writer can restore a verified entry';
  end if;
end $$;
select pg_temp.as_device(5);
-- The same device twice does not count twice.
select pg_temp.as_device(5); select public.submit_label('0123456070004','per_100g',null,'Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}');
select pg_temp.check((select supporting_devices from public.lookup_label('0123456070004')) = 5, 'a device counts once');
-- Withdrawing a supporter drops it below the bar.
select pg_temp.as_device(4); select pg_temp.check(public.withdraw_my_submissions() = 1, 'withdraw reports one label');
select pg_temp.check((select not verified from public.lookup_label('0123456070004')), 'badge removed after withdrawal');
select pg_temp.check((select supporting_devices from public.lookup_label('0123456070004')) = 4, 'four supporters left');
-- Rejecting a label removes it at once and keeps it out.
reset role; insert into catalog.rejections (barcode, basis, reason) values ('0123456070004', 'per_100g', 'test');
select pg_temp.as_device(9);
select pg_temp.check((select count(*) from public.lookup_label('0123456070004')) = 0, 'rejected label is gone');
select pg_temp.as_device(5); select public.submit_label('0123456070004','per_100g',null,'Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}');
select pg_temp.check((select count(*) from public.lookup_label('0123456070004')) = 0, 'rejected label stays gone');
-- Withdrawing does not reset the daily limit.
reset role; update catalog.settings set daily_limit = 3;
select pg_temp.as_device(10);
select public.submit_label('0123456070042','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}');
select public.submit_label('0123456070059','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}');
select public.withdraw_my_submissions();
select public.submit_label('0123456070066','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}');
do $$ begin perform public.submit_label('0123456070073','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}'); raise exception 'withdraw reset the limit'; exception when sqlstate '53400' then null; end $$;
reset role; update catalog.settings set daily_limit = 60;
-- Anonymous sign-ins are refused.
reset role; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000099', false), set_config('request.jwt.claims', '{"is_anonymous": true}', false); set role authenticated;
do $$ begin perform public.submit_label('0123456070080','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}'); raise exception 'anonymous submit accepted'; exception when sqlstate '28000' then null; end $$;
do $$ begin perform public.lookup_label('0123456070004'); exception when sqlstate '28000' then null; end $$;

-- A bad check digit, a per-serving label with no serving, and a wrong length are refused.
select pg_temp.as_device(7);
do $$ begin perform public.submit_label('0123456070005','per_100g',null,'X',null,'{"energyKcal":1,"protein":1,"fat":1}'); raise exception 'bad check digit accepted'; exception when sqlstate '22023' then null; end $$;
do $$ begin perform public.submit_label('0123456070004','per_serving',null,'X',null,'{"energyKcal":1,"protein":1,"fat":1}'); raise exception 'per-serving without serving accepted'; exception when sqlstate '22023' then null; end $$;
do $$ begin perform public.submit_label('01234560700000','per_100g',null,'X',null,'{"energyKcal":1,"protein":1,"fat":1}'); exception when sqlstate '22023' then null; end $$;
-- Every counted supporter agrees with the shown value: a middle seed cannot pull in two low and two high values
-- that disagree with each other.
reset role; delete from catalog.entries; delete from catalog.submissions; delete from catalog.usage;
insert into catalog.submissions (device_id, barcode, basis, product_name, nutrients)
select ('00000000-0000-0000-0000-' || lpad((100 + n)::text, 12, '0'))::uuid, '0123456880009', 'per_100g', 'Spread',
  jsonb_build_object('energyKcal', e, 'protein', 5, 'fat', 5)
from (values (1, 100), (2, 100), (3, 108), (4, 116), (5, 116)) v(n, e);
select catalog.refresh_entry('0123456880009', 'per_100g');
select pg_temp.check((select count(*) from catalog.entries where barcode = '0123456880009' and verified) = 0, 'no verified badge without five mutually agreeing devices');
-- Changing a tunable re-checks existing entries.
insert into catalog.submissions (device_id, barcode, basis, product_name, nutrients)
select ('00000000-0000-0000-0000-' || lpad((200 + n)::text, 12, '0'))::uuid, '0123456881006', 'per_100g', 'Jam',
  '{"energyKcal":50,"protein":1,"fat":1}'::jsonb
from generate_series(1, 5) n;
select catalog.refresh_entry('0123456881006', 'per_100g');
select pg_temp.check((select not verified from catalog.entries where barcode = '0123456881006'), 'five agreeing devices never verify');
update catalog.settings set min_devices = 6;
select pg_temp.check((select not verified from catalog.entries where barcode = '0123456881006'), 'raising the bar removes the badge');
update catalog.settings set min_devices = 5;

-- Equivalent codes (UPC-A and the same code with a leading zero) join one consensus; a stale token reads nothing.
reset role; delete from catalog.entries; delete from catalog.submissions; delete from catalog.usage;
select pg_temp.as_device(1); select public.submit_label('123456000315','per_100g',null,'Cola',null,'{"energyKcal":42,"protein":0,"carbohydrates":10.6}');
select pg_temp.as_device(2); select pg_temp.check(public.submit_label('0123456000315','per_100g',null,'Cola',null,'{"energyKcal":42,"protein":0,"carbohydrates":10.6}') = 'shared', 'UPC-A and EAN-13 forms join one label');
select pg_temp.check((select count(*) from public.lookup_label('123456000315')) = 1, 'lookup finds it by the 12-digit form');
-- Per-serving values with different serving definitions never count together.
select pg_temp.as_device(3); select public.submit_label('0123456000315','per_serving','30 g','Cola',null,'{"energyKcal":90,"protein":1,"carbohydrates":20}');
select pg_temp.as_device(4); select public.submit_label('0123456000315','per_serving','60 g','Cola',null,'{"energyKcal":90,"protein":1,"carbohydrates":20}');
select pg_temp.check((select count(*) from public.lookup_label('123456000315') where basis = 'per_serving') = 0, 'different serving definitions do not agree');
select pg_temp.as_device(5); select public.submit_label('0123456000315','per_serving','30 g','Cola',null,'{"energyKcal":90,"protein":1,"carbohydrates":20}');
select pg_temp.check((select supporting_devices from public.lookup_label('123456000315') where basis = 'per_serving') = 2, 'same serving definition agrees');
-- The final median still has every supporter in tolerance.
reset role; delete from catalog.entries; delete from catalog.submissions;
insert into catalog.submissions (device_id, barcode, basis, product_name, nutrients)
select ('00000000-0000-0000-0000-' || lpad((300 + n)::text, 12, '0'))::uuid, '0123456000315', 'per_100g', 'Mix',
  jsonb_build_object('protein', p, 'fat', p, 'carbohydrates', p)
from (values (1, 0), (2, 0), (3, 0), (4, 0.2), (5, 0.6), (6, 0.7)) v(n, p);
select catalog.refresh_entry('0123456000315', 'per_100g');
select pg_temp.check((select count(*) from catalog.entries where barcode = '0123456000315' and verified) = 0, 'supporters are re-checked against the final median');
-- A replacement counts as the newest submission.
reset role; update catalog.submissions set updated_at = now() + interval '1 hour' where device_id = '00000000-0000-0000-0000-000000000306';
-- A deleted account reads nothing with its stale token.
reset role; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000999', false), set_config('request.jwt.claims', '{"is_anonymous": false}', false); set role authenticated;
select pg_temp.check((select count(*) from public.lookup_label('123456000315')) = 0, 'no profile, no lookup');
reset role;
-- A rejection written with the 12-digit form blocks the 13-digit label.
reset role; delete from catalog.entries; delete from catalog.submissions; delete from catalog.rejections;
insert into catalog.rejections (barcode, basis, reason) values ('123456000315', 'per_100g', 'test');
select pg_temp.check((select barcode from catalog.rejections) = '0123456000315', 'a 12-digit rejection is stored in the 13-digit form');
select pg_temp.as_device(1); select public.submit_label('123456000315','per_100g',null,'Cola',null,'{"energyKcal":42,"protein":0,"carbohydrates":10.6}');
select pg_temp.as_device(2); select public.submit_label('0123456000315','per_100g',null,'Cola',null,'{"energyKcal":42,"protein":0,"carbohydrates":10.6}');
select pg_temp.check((select count(*) from public.lookup_label('123456000315')) = 0, 'a rejected label is never shown');
reset role; delete from catalog.rejections;
-- Invalid input is refused.
select pg_temp.as_device(7);
do $$ begin perform public.submit_label('12','per_100g',null,'X',null,'{"energyKcal":1,"protein":1,"fat":1}'); raise exception 'short barcode accepted'; exception when sqlstate '22023' then null; end $$;
do $$ begin perform public.submit_label('0123456070004','per_100g',null,'X',null,'{"energyKcal":1,"protein":1}'); raise exception 'two nutrients accepted'; exception when sqlstate '22023' then null; end $$;
do $$ begin perform public.submit_label('0123456070004','per_100g',null,'X',null,'{"energyKcal":1,"protein":1,"fat":1,"evil":3}'); raise exception 'unknown key accepted'; exception when sqlstate '22023' then null; end $$;
do $$ begin perform public.submit_label('0123456070004','per_100g',null,'X',null,'{"energyKcal":99999,"protein":1,"fat":1}'); raise exception 'huge value accepted'; exception when sqlstate '22023' then null; end $$;
do $$ begin perform public.submit_label('0123456070004','per_100g',null,'X',null,'{"energyKcal":"1","protein":1,"fat":1}'); raise exception 'string value accepted'; exception when sqlstate '22023' then null; end $$;
-- Rate limit.
reset role; update catalog.settings set daily_limit = 2;
select pg_temp.as_device(8);
select public.submit_label('0123456070011','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}');
select public.submit_label('0123456070028','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}');
do $$ begin perform public.submit_label('0123456070035','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}'); raise exception 'limit not enforced'; exception when sqlstate '53400' then null; end $$;
-- Direct table and private function access is denied.
do $$ begin perform 1 from catalog.submissions; raise exception 'table readable'; exception when insufficient_privilege then null; end $$;
do $$ begin perform catalog.refresh_entry('0123456070004','per_100g'); raise exception 'private function callable'; exception when insufficient_privilege then null; end $$;
-- Anonymous (no sign-in) callers are denied.
reset role; select set_config('request.jwt.claim.sub', '', false); set role anon;
do $$ begin perform public.lookup_label('0123456070004'); raise exception 'anon can call'; exception when insufficient_privilege then null; end $$;
-- An anonymous user never gets a profile.
reset role; insert into auth.users (id, is_anonymous) values ('00000000-0000-0000-0000-000000000061', true);
select pg_temp.check((select count(*) from public.profiles where id = '00000000-0000-0000-0000-000000000061') = 0, 'no profile for an anonymous user');
-- Profiles: a person reads and edits only their own; sharing off blocks submitting; deleting removes everything.
reset role;
insert into auth.users (id) values ('00000000-0000-0000-0000-000000000051'), ('00000000-0000-0000-0000-000000000052');
select pg_temp.check((select count(*) from public.profiles where id in ('00000000-0000-0000-0000-000000000051','00000000-0000-0000-0000-000000000052')) = 2, 'a profile is created for each new user');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000051', false), set_config('request.jwt.claims', '{"is_anonymous": false}', false);
set role authenticated;
select pg_temp.check((select count(*) from public.profiles) = 1, 'a person sees only their own profile');
update public.profiles set display_name = 'Pat', share_labels = false;
do $$ begin perform public.submit_label('0123456070097','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}'); raise exception 'submitted with sharing off'; exception when sqlstate '42501' then null; end $$;
update public.profiles set share_labels = true;
select public.submit_label('0123456070097','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}');
do $$ begin update public.profiles set id = '00000000-0000-0000-0000-000000000052'; raise exception 'took over another profile'; exception when insufficient_privilege or unique_violation then null; end $$;
select public.delete_my_account();
do $$ begin perform public.submit_label('0123456070103','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}'); raise exception 'deleted account could submit'; exception when sqlstate '28000' then null; end $$;
reset role;
select pg_temp.check((select count(*) from catalog.submissions where device_id = '00000000-0000-0000-0000-000000000051') = 0, 'account deletion removes submissions');
select pg_temp.check((select count(*) from public.profiles where id = '00000000-0000-0000-0000-000000000051') = 0, 'account deletion removes the profile');
select pg_temp.check((select count(*) from auth.users where id = '00000000-0000-0000-0000-000000000051') = 0, 'account deletion removes the sign-in');
reset role;
-- Platform default grants are closed: no delete or truncate on profiles, no direct call of the trigger helper.
reset role;
select pg_temp.check(not has_table_privilege('authenticated', 'public.profiles', 'DELETE'), 'authenticated cannot delete profiles');
select pg_temp.check(not has_table_privilege('authenticated', 'public.profiles', 'TRUNCATE'), 'authenticated cannot truncate profiles');
select pg_temp.check(not has_table_privilege('anon', 'public.profiles', 'SELECT'), 'anon cannot read profiles');
select pg_temp.check(has_table_privilege('authenticated', 'public.profiles', 'UPDATE'), 'authenticated can still update its profile');
select pg_temp.check(not has_function_privilege('authenticated', 'public.touch_profile()', 'EXECUTE'), 'touch_profile is not callable');
select pg_temp.check(not has_function_privilege('anon', 'public.touch_profile()', 'EXECUTE'), 'touch_profile is not callable by anon');
-- Nutrient payloads are bounded in size and scale.
select pg_temp.check(catalog.valid_nutrients('{"energyKcal":120.55,"protein":3,"fat":2}'::jsonb), 'a normal payload is valid');
select pg_temp.check(not catalog.valid_nutrients(jsonb_build_object('energyKcal', 1, 'protein', 1, 'fat', ('0.' || repeat('0', 5000) || '1')::numeric)), 'a payload with thousands of digits is refused');
select pg_temp.check(not catalog.valid_nutrients('{"energyKcal":1.2345,"protein":1,"fat":1}'::jsonb), 'a value with more than three decimals is refused');
-- Rows stored under an older, looser validator are removed and the entries rebuilt.
insert into auth.users (id) values ('00000000-0000-0000-0000-000000000071'), ('00000000-0000-0000-0000-000000000072') on conflict do nothing;
insert into catalog.submissions (device_id, barcode, basis, product_name, nutrients)
values ('00000000-0000-0000-0000-000000000071', '0000000099990', 'per_100g', 'Old', '{"energyKcal":1.23456,"protein":1,"fat":1}'),
       ('00000000-0000-0000-0000-000000000072', '0000000099990', 'per_100g', 'Old', '{"energyKcal":1,"protein":1,"fat":1}');
insert into catalog.entries (barcode, basis, product_name, nutrients, supporting_devices, verified)
values ('0000000099990', 'per_100g', 'Old', '{"energyKcal":1.23456,"protein":1,"fat":1}', 2, false);
select catalog.revalidate_all();
select pg_temp.check((select count(*) from catalog.submissions where barcode = '0000000099990') = 1, 'an over-precise stored row is removed');
select pg_temp.check((select count(*) from catalog.entries where barcode = '0000000099990') = 0, 'the entry is rebuilt from the valid rows only');
-- Owner-maintained snapshots are separate from the capped community candidate window.
reset role;
insert into auth.users (id)
select ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid
from generate_series(1000, 1100) n on conflict do nothing;
select pg_temp.as_device(1000); select public.submit_label('0123456070004','per_100g',null,'Community Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}');
select pg_temp.as_device(1001); select public.submit_label('0123456070004','per_100g',null,'Community Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}');
select pg_temp.as_device(1002); select public.submit_label('0123456070004','per_100g',null,'Community Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}');
select pg_temp.as_device(1003); select public.submit_label('0123456070004','per_100g',null,'Community Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}');
select pg_temp.as_device(1004); select public.submit_label('0123456070004','per_100g',null,'Community Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}');
select pg_temp.as_device(8); reset role;
select catalog.owner_approve_label(
  '0123456070004', 'per_100g', null, 'Owner Oat Bar', 'Reviewed Acme',
  '{"energyKcal":410,"protein":11,"carbohydrates":61,"fat":13}'::jsonb,
  'reviewed'
);
select pg_temp.check(
  (select product_name = 'Owner Oat Bar' and nutrients = '{"energyKcal":410,"protein":11,"carbohydrates":61,"fat":13}'::jsonb
        and verified and supporting_devices = 0 and verification_source = 'owner_reviewed'
   from public.lookup_label_v2('0123456070004')),
  'owner approval returns the exact owner-reviewed snapshot with no supporter count'
);
select pg_temp.check((select count(*) = 0 from public.lookup_label('0123456070004')),
  'legacy lookup hides the community row while an owner-approved canonical is active');
select pg_temp.check(
  (select count(*) = 1 and min(action) = 'approve' and min(payload_digest) is not null
   from catalog.moderation_audit where barcode = '0123456070004' and basis = 'per_100g'),
  'approval is audited with a payload digest'
);
select pg_temp.check(
  not exists (select 1 from information_schema.columns where table_schema = 'catalog'
    and table_name in ('approved_entries', 'moderation_audit')
    and column_name in ('device_id', 'submitter_id', 'submission_id')),
  'canonical and audit rows have no source account or submission identifier'
);
-- Newer submissions are accepted under normal limits and cannot alter the canonical snapshot.
do $$
declare n integer;
begin
  for n in 1000..1100 loop
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-' || lpad(n::text, 12, '0'), false);
    perform set_config('request.jwt.claims', '{"is_anonymous": false}', false);
    perform set_config('role', 'authenticated', false);
    perform public.submit_label('0123456070004','per_100g',null,'Flood Label','Flood Brand',
      '{"energyKcal":800,"protein":100,"carbohydrates":100,"fat":100}'::jsonb);
  end loop;
end $$;
reset role;
select catalog.refresh_entry('0123456070004', 'per_100g');
select pg_temp.check(
  (select product_name = 'Owner Oat Bar' and nutrients->>'energyKcal' = '410'
        and verification_source = 'owner_reviewed' and verified and supporting_devices = 0
   from public.lookup_label_v2('0123456070004')),
  '101 newer candidates cannot replace the approved canonical snapshot'
);
select pg_temp.check((select count(*) = 0 from public.lookup_label('0123456070004')),
  'legacy lookup still hides the community row after candidate flooding while canonical approval is active');
-- Invalid canonical payloads and incomplete serving definitions fail atomically.
do $$ begin
  perform catalog.owner_approve_label('0123456070004','per_serving',null,'Bad','Brand',
    '{"energyKcal":410,"protein":11,"fat":13}'::jsonb,'reviewed');
  raise exception 'per-serving approval without a serving was accepted';
exception when sqlstate '22023' then null; end $$;
select pg_temp.check((select product_name = 'Owner Oat Bar' from catalog.approved_entries
  where barcode = '0123456070004' and basis = 'per_100g'), 'failed approval left prior canonical untouched');
do $$ begin
  perform catalog.owner_approve_label('0123456070004','per_100g',null,'Bad','Brand',
    '{"energyKcal":99999,"protein":11,"fat":13}'::jsonb,'reviewed');
  raise exception 'out-of-bounds nutrient approval was accepted';
exception when sqlstate '22023' then null; end $$;
select pg_temp.check((select product_name = 'Owner Oat Bar' from catalog.approved_entries
  where barcode = '0123456070004' and basis = 'per_100g'), 'invalid nutrient approval left prior canonical untouched');
-- Rejection suppresses both sources, even after more submissions and refreshes.
select catalog.owner_reject_label('0123456070004','per_100g','needs_recheck');
select pg_temp.check((select count(*) = 0 from public.lookup_label_v2('0123456070004')), 'rejection hides canonical from v2');
select pg_temp.check((select count(*) = 0 from public.lookup_label('0123456070004')), 'rejection hides community from legacy');
select pg_temp.check(not exists (select 1 from catalog.approved_entries where barcode = '0123456070004'), 'rejection removes active canonical');
select pg_temp.as_device(1005);
select pg_temp.check(public.submit_label('0123456070004','per_100g',null,'Flood Label','Flood Brand',
  '{"energyKcal":800,"protein":100,"carbohydrates":100,"fat":100}'::jsonb) = 'received',
  'rejected keys continue accepting submissions under normal limits');
reset role; select catalog.refresh_entry('0123456070004', 'per_100g');
select pg_temp.check((select count(*) = 0 from public.lookup_label_v2('0123456070004')), 'refresh and new submissions cannot restore rejected v2 visibility');
select pg_temp.check((select count(*) = 0 from public.lookup_label('0123456070004')), 'refresh and new submissions cannot restore rejected legacy visibility');
select pg_temp.check((select count(*) = 1 from catalog.moderation_audit where barcode = '0123456070004' and action = 'reject'), 'rejection is audited');
select pg_temp.check((select count(distinct payload_digest) = 1 and bool_and(payload_digest is not null) from catalog.moderation_audit where barcode = '0123456070004' and basis = 'per_100g' and action in ('approve', 'reject')), 'approval and rejection share the canonical payload digest');
select catalog.owner_clear_rejection('0123456070004','per_100g','reviewed');
select pg_temp.check((select verification_source = 'community' and not verified
  from public.lookup_label_v2('0123456070004')), 'clearing rejection shows community only and does not verify it');
select pg_temp.check((select count(*) = 1 from catalog.moderation_audit where barcode = '0123456070004' and action = 'clear_rejection'), 'clear rejection is separately audited');
-- Revocation removes the canonical and falls back to community without a badge.
select catalog.owner_approve_label('0123456070004','per_100g',null,'Owner Oat Bar','Reviewed Acme',
  '{"energyKcal":410,"protein":11,"carbohydrates":61,"fat":13}'::jsonb,'reviewed');
select catalog.owner_revoke_label('0123456070004','per_100g','withdrawn');
select pg_temp.check((select verification_source = 'community' and not verified
  from public.lookup_label_v2('0123456070004')), 'revocation falls back to unverified community entry');
select pg_temp.check((select count(*) = 1 and bool_and(not verified) from public.lookup_label('0123456070004')),
  'legacy lookup exposes the community fallback again after revocation');
select pg_temp.check(not exists (select 1 from catalog.approved_entries where barcode = '0123456070004'), 'revocation removes active canonical');
select pg_temp.check((select count(*) = 1 from catalog.moderation_audit where barcode = '0123456070004' and action = 'revoke'), 'revocation is audited');
select pg_temp.check((select count(distinct payload_digest) = 1 and bool_and(payload_digest is not null) from catalog.moderation_audit where barcode = '0123456070004' and basis = 'per_100g' and action in ('approve', 'reject', 'revoke')), 'identical reviewed payloads keep one digest across reapproval and revocation');
-- A revoked approval with no eligible community aggregate does not return a row.
select catalog.owner_approve_label('0123456070110','per_100g',null,'Isolated Label','Acme',
  '{"energyKcal":200,"protein":5,"carbohydrates":20}'::jsonb,'reviewed');
select catalog.owner_revoke_label('0123456070110','per_100g','withdrawn');
select pg_temp.check((select count(*) = 0 from public.lookup_label_v2('0123456070110')), 'revocation without community fallback returns no row');
-- Revoked values require another explicit approval to return as owner-reviewed.
select catalog.owner_approve_label('0123456070004','per_100g',null,'Owner Oat Bar','Reviewed Acme',
  '{"energyKcal":410,"protein":11,"carbohydrates":61,"fat":13}'::jsonb,'reviewed');
-- Withdrawal and deletion remove source submissions while preserving the independent snapshot.
select pg_temp.check((select count(*) > 0 from catalog.submissions where device_id = '00000000-0000-0000-0000-000000001000'
  and barcode = '0123456070004'), 'source account submitted the approved label');
select pg_temp.as_device(1000); select public.withdraw_my_submissions(); reset role;
select pg_temp.check((select product_name = 'Owner Oat Bar' and nutrients = '{"energyKcal":410,"protein":11,"carbohydrates":61,"fat":13}'::jsonb
  and verified and supporting_devices = 0 from public.lookup_label_v2('0123456070004')), 'withdrawal preserves the exact canonical snapshot');
select pg_temp.check(not exists (select 1 from catalog.submissions where device_id = '00000000-0000-0000-0000-000000001000'
  and barcode = '0123456070004'), 'withdrawal removes source submission');
select pg_temp.as_device(2); select public.delete_my_account(); reset role;
select pg_temp.as_device(8); reset role;
select pg_temp.check((select product_name = 'Owner Oat Bar' from public.lookup_label_v2('0123456070004')),
  'account deletion preserves independent canonical for another signed-in account');
-- App roles cannot invoke owner functions, read/write snapshots or read/alter audit rows.
select pg_temp.check(not has_function_privilege('anon', 'catalog.owner_approve_label(text,text,text,text,text,jsonb,text)', 'EXECUTE'), 'anon cannot approve');
select pg_temp.check(not has_function_privilege('anon', 'catalog.owner_reject_label(text,text,text)', 'EXECUTE'), 'anon cannot reject');
select pg_temp.check(not has_function_privilege('anon', 'catalog.owner_clear_rejection(text,text,text)', 'EXECUTE'), 'anon cannot clear rejection');
select pg_temp.check(not has_function_privilege('anon', 'catalog.owner_revoke_label(text,text,text)', 'EXECUTE'), 'anon cannot revoke');
select pg_temp.check(not has_function_privilege('authenticated', 'catalog.owner_approve_label(text,text,text,text,text,jsonb,text)', 'EXECUTE'), 'authenticated cannot approve');
select pg_temp.check(not has_function_privilege('authenticated', 'catalog.owner_reject_label(text,text,text)', 'EXECUTE'), 'authenticated cannot reject');
select pg_temp.check(not has_function_privilege('authenticated', 'catalog.owner_clear_rejection(text,text,text)', 'EXECUTE'), 'authenticated cannot clear rejection');
select pg_temp.check(not has_function_privilege('authenticated', 'catalog.owner_revoke_label(text,text,text)', 'EXECUTE'), 'authenticated cannot revoke');
select pg_temp.check(not has_table_privilege('authenticated', 'catalog.approved_entries', 'SELECT,INSERT,UPDATE,DELETE'), 'authenticated cannot access canonical table');
select pg_temp.check(not has_table_privilege('authenticated', 'catalog.moderation_audit', 'SELECT,INSERT,UPDATE,DELETE'), 'authenticated cannot access audit table');
select pg_temp.check(not has_table_privilege('anon', 'catalog.approved_entries', 'SELECT,INSERT,UPDATE,DELETE'), 'anon cannot access canonical table');
select pg_temp.check(not has_table_privilege('anon', 'catalog.moderation_audit', 'SELECT,INSERT,UPDATE,DELETE'), 'anon cannot access audit table');
select pg_temp.check((select relrowsecurity from pg_class where oid = 'catalog.approved_entries'::regclass), 'canonical table has RLS enabled');
select pg_temp.check((select relrowsecurity from pg_class where oid = 'catalog.moderation_audit'::regclass), 'audit table has RLS enabled');
select pg_temp.check(not has_table_privilege('authenticated', 'catalog.approved_entries', 'TRUNCATE'), 'authenticated cannot truncate canonical table');
select pg_temp.check(not has_table_privilege('authenticated', 'catalog.moderation_audit', 'TRUNCATE'), 'authenticated cannot truncate audit table');
-- Audit history rejects UPDATE and DELETE, even from the SQL owner interface.
do $$ begin update catalog.moderation_audit set reason = 'changed' where barcode = '0123456070004';
  raise exception 'audit row was mutable'; exception when sqlstate '42501' then null; end $$;
do $$ begin delete from catalog.moderation_audit where barcode = '0123456070004';
  raise exception 'audit row was deletable'; exception when sqlstate '42501' then null; end $$;
-- A deleted user's stale token remains unable to use either lookup.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false), set_config('request.jwt.claims', '{"is_anonymous": false}', false);
set role authenticated;
select pg_temp.check((select count(*) = 0 from public.lookup_label_v2('0123456070004')), 'deleted account stale token cannot use v2 lookup');
select pg_temp.check((select count(*) = 0 from public.lookup_label('0123456070004')), 'deleted account stale token cannot use legacy lookup');
reset role;
select 'ALL OK' as result;
