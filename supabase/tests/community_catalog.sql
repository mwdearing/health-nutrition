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
begin if not ok then raise exception 'FAILED: %', msg; end if; end $$;

reset role;
-- Five devices send agreeing values: the fifth makes it verified; the first four never leak.
select pg_temp.as_device(1);
select pg_temp.check(public.submit_label('0123456789012','per_100g',null,'Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}') = 'received', 'first is received');
select pg_temp.check((select count(*) from public.lookup_label('0123456789012')) = 0, 'a single submission is not shown');
select pg_temp.as_device(2); select pg_temp.check(public.submit_label('0123456789012','per_100g',null,'Oat Bar','Acme','{"energyKcal":401,"protein":10.1,"carbohydrates":60,"fat":12}') = 'shared', 'two agreeing devices are shown without a badge');
select pg_temp.check((select not verified from public.lookup_label('0123456789012')), 'shown but not verified');
select pg_temp.as_device(3); select public.submit_label('0123456789012','per_100g',null,'Oat Bar','Acme','{"energyKcal":399,"protein":10,"carbohydrates":59.5,"fat":12}');
select pg_temp.as_device(4); select public.submit_label('0123456789012','per_100g',null,'Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}');
-- An outlier does not join the group and does not block it.
select pg_temp.as_device(6); select pg_temp.check(public.submit_label('0123456789012','per_100g',null,'Oat Bar','Acme','{"energyKcal":250,"protein":3,"carbohydrates":30,"fat":1}') = 'shared', 'outlier does not change the shown label');
select pg_temp.as_device(5);
select pg_temp.check(public.submit_label('0123456789012','per_100g',null,'Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}') = 'verified', 'fifth agreeing device verifies');
select pg_temp.check((select supporting_devices from public.lookup_label('0123456789012')) = 5, 'five supporters');
select pg_temp.check((select (nutrients->>'energyKcal')::numeric from public.lookup_label('0123456789012')) = 400, 'median energy');
-- The same device twice does not count twice.
select pg_temp.as_device(5); select public.submit_label('0123456789012','per_100g',null,'Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}');
select pg_temp.check((select supporting_devices from public.lookup_label('0123456789012')) = 5, 'a device counts once');
-- Withdrawing a supporter drops it below the bar.
select pg_temp.as_device(4); select pg_temp.check(public.withdraw_my_submissions() = 1, 'withdraw reports one label');
select pg_temp.check((select not verified from public.lookup_label('0123456789012')), 'badge removed after withdrawal');
select pg_temp.check((select supporting_devices from public.lookup_label('0123456789012')) = 4, 'four supporters left');
-- Rejecting a label removes it at once and keeps it out.
reset role; insert into catalog.rejections (barcode, basis, reason) values ('0123456789012', 'per_100g', 'test');
select pg_temp.as_device(9);
select pg_temp.check((select count(*) from public.lookup_label('0123456789012')) = 0, 'rejected label is gone');
select pg_temp.as_device(5); select public.submit_label('0123456789012','per_100g',null,'Oat Bar','Acme','{"energyKcal":400,"protein":10,"carbohydrates":60,"fat":12}');
select pg_temp.check((select count(*) from public.lookup_label('0123456789012')) = 0, 'rejected label stays gone');
-- Withdrawing does not reset the daily limit.
reset role; update catalog.settings set daily_limit = 3;
select pg_temp.as_device(10);
select public.submit_label('0123456789020','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}');
select public.submit_label('0123456789021','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}');
select public.withdraw_my_submissions();
select public.submit_label('0123456789022','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}');
do $$ begin perform public.submit_label('0123456789023','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}'); raise exception 'withdraw reset the limit'; exception when sqlstate '53400' then null; end $$;
reset role; update catalog.settings set daily_limit = 60;
-- Anonymous sign-ins are refused.
reset role; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000099', false), set_config('request.jwt.claims', '{"is_anonymous": true}', false); set role authenticated;
do $$ begin perform public.submit_label('0123456789030','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}'); raise exception 'anonymous submit accepted'; exception when sqlstate '28000' then null; end $$;
do $$ begin perform public.lookup_label('0123456789012'); exception when sqlstate '28000' then null; end $$;
-- Invalid input is refused.
select pg_temp.as_device(7);
do $$ begin perform public.submit_label('12','per_100g',null,'X',null,'{"energyKcal":1,"protein":1,"fat":1}'); raise exception 'short barcode accepted'; exception when sqlstate '22023' then null; end $$;
do $$ begin perform public.submit_label('0123456789012','per_100g',null,'X',null,'{"energyKcal":1,"protein":1}'); raise exception 'two nutrients accepted'; exception when sqlstate '22023' then null; end $$;
do $$ begin perform public.submit_label('0123456789012','per_100g',null,'X',null,'{"energyKcal":1,"protein":1,"fat":1,"evil":3}'); raise exception 'unknown key accepted'; exception when sqlstate '22023' then null; end $$;
do $$ begin perform public.submit_label('0123456789012','per_100g',null,'X',null,'{"energyKcal":99999,"protein":1,"fat":1}'); raise exception 'huge value accepted'; exception when sqlstate '22023' then null; end $$;
do $$ begin perform public.submit_label('0123456789012','per_100g',null,'X',null,'{"energyKcal":"1","protein":1,"fat":1}'); raise exception 'string value accepted'; exception when sqlstate '22023' then null; end $$;
-- Rate limit.
reset role; update catalog.settings set daily_limit = 2;
select pg_temp.as_device(8);
select public.submit_label('0123456789013','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}');
select public.submit_label('0123456789014','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}');
do $$ begin perform public.submit_label('0123456789015','per_100g',null,'A',null,'{"energyKcal":1,"protein":1,"fat":1}'); raise exception 'limit not enforced'; exception when sqlstate '53400' then null; end $$;
-- Direct table and private function access is denied.
do $$ begin perform 1 from catalog.submissions; raise exception 'table readable'; exception when insufficient_privilege then null; end $$;
do $$ begin perform catalog.refresh_entry('0123456789012','per_100g'); raise exception 'private function callable'; exception when insufficient_privilege then null; end $$;
-- Anonymous (no sign-in) callers are denied.
reset role; select set_config('request.jwt.claim.sub', '', false); set role anon;
do $$ begin perform public.lookup_label('0123456789012'); raise exception 'anon can call'; exception when insufficient_privilege then null; end $$;
reset role;
select 'ALL OK' as result;
