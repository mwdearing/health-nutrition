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
-- Five devices send agreeing values: the fifth makes it verified; the first four never leak.
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
select pg_temp.check(public.submit_label('0123456070004','per_100g',null,'Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}') = 'verified', 'fifth agreeing device verifies');
select pg_temp.check((select supporting_devices from public.lookup_label('0123456070004')) = 5, 'five supporters');
select pg_temp.check((select (nutrients->>'energyKcal')::numeric from public.lookup_label('0123456070004')) = 400, 'median energy');
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
select pg_temp.check((select verified from catalog.entries where barcode = '0123456881006'), 'five agreeing devices verify');
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
select 'ALL OK' as result;
