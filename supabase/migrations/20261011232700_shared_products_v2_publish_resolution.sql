-- Resolve a lost publication reply without publishing or changing account sharing preferences.
-- Markers are permanent until profile erasure; rollback must retain this fence or disable writes.
begin;

-- Wrap the accepted legacy bridge, retaining its complete, sorted identity/product lock sets.
-- Fail closed if an intervening migration changed the implementation or trusted owner.
do $$ declare p pg_catalog.pg_proc%rowtype; begin
 select * into strict p from pg_catalog.pg_proc where oid='catalog_v2.write_operation(jsonb,boolean)'::regprocedure;
 if md5(p.prosrc)<>'d500f383fd7df9af46fc28bc4892e6ac' or p.prosecdef
    or p.proowner<>(select proowner from pg_catalog.pg_proc where oid='public.submit_catalog_product_v2(jsonb)'::regprocedure)
    or p.proowner<>(select oid from pg_catalog.pg_roles where rolname=current_user)
    or p.proconfig is distinct from array['search_path=""']::text[] then
  raise exception 'unexpected catalog writer implementation or owner';
 end if;
end $$;
alter function catalog_v2.write_operation(jsonb,boolean) rename to write_operation_before_publish_cancellation;

alter table catalog_v2.settings add column max_new_publish_cancellations_per_day integer not null default 256
 check(max_new_publish_cancellations_per_day between 1 and 10000);
create table catalog_v2.publish_cancellations (
 account_id uuid not null references public.profiles(id) on delete cascade,
 operation_id uuid not null,
 canonical_body text not null check(octet_length(canonical_body)<=16384),
 created_at timestamptz not null default transaction_timestamp(),
 primary key(account_id,operation_id)
);
create index publish_cancellations_account_created on catalog_v2.publish_cancellations(account_id,created_at);
alter table catalog_v2.publish_cancellations enable row level security;
revoke all on catalog_v2.publish_cancellations from public,anon,authenticated;

-- Only the minimal pre-replay envelope checks. Preserve raw UUID/decimal/Unicode spelling.
create function catalog_v2.publish_operation_id(body jsonb) returns uuid
language plpgsql immutable security invoker set search_path='' as $$ begin
 if body is null or jsonb_typeof(body)<>'object' then perform catalog_v2.fail('invalid_request'); end if;
 if octet_length(catalog_v2.canonical(body))>16384 then perform catalog_v2.fail('invalid_request'); end if;
 if jsonb_typeof(body->'operation_id') is distinct from 'string'
    or (body->>'operation_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
  perform catalog_v2.fail('invalid_request');
 end if;
 return (body->>'operation_id')::uuid;
end $$;

-- Pure fresh-publication validation, matching the retained writer before its policy/identity work.
-- No consent lookup, product existence, barcode binding, moderation, CAS, or identity allocation.
create function catalog_v2.validate_publish_cancellation(body jsonb) returns void
language plpgsql immutable security invoker set search_path='' as $$ begin
 if not catalog_v2.object_shape(body,array['operation_id','client_revision_id','product_id','expected_server_revision','consent_version','consent_generation','product'])
    or not catalog_v2.valid_product(body->'product') then perform catalog_v2.fail('invalid_request'); end if;
 if jsonb_typeof(body->'client_revision_id')<>'string'
    or (body->>'client_revision_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or jsonb_typeof(body->'product_id') not in ('string','null') then perform catalog_v2.fail('invalid_request'); end if;
 if body->>'product_id' is not null and (body->>'product_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then perform catalog_v2.fail('invalid_request'); end if;
 if body->'expected_server_revision'<>'null'::jsonb and
    (jsonb_typeof(body->'expected_server_revision')<>'string' or (body->>'expected_server_revision')!~'^[1-9][0-9]*$') then perform catalog_v2.fail('invalid_request'); end if;
 if body->'product_id'='null'::jsonb and body->'expected_server_revision'<>'null'::jsonb then perform catalog_v2.fail('invalid_request'); end if;
 if body->'consent_version' is distinct from '2'::jsonb or jsonb_typeof(body->'consent_generation')<>'string'
    or (body->>'consent_generation')!~'^(0|[1-9][0-9]*)$' then perform catalog_v2.fail('invalid_request'); end if;
end $$;

create function catalog_v2.write_operation(body jsonb, withdrawing boolean) returns jsonb
language plpgsql security invoker set search_path='' as $$ declare a uuid; op uuid; begin
 a:=catalog_v2.live_account();
 op:=catalog_v2.publish_operation_id(body);
 -- Receipt-first replay remains authoritative inside the unchanged legacy writer.
 if exists(select 1 from catalog_v2.receipts where account_id=a and operation_id=op) then
  return catalog_v2.write_operation_before_publish_cancellation(body,withdrawing);
 end if;
 if exists(select 1 from catalog_v2.publish_cancellations where account_id=a and operation_id=op) then
  perform catalog_v2.fail('operation_conflict');
 end if;
 return catalog_v2.write_operation_before_publish_cancellation(body,withdrawing);
end $$;

-- Explicit rebinding is required after rename; never rely on cached SQL function resolution.
create or replace function public.submit_catalog_product_v2(p_request jsonb) returns jsonb
language sql security definer set search_path='' as $$ select catalog_v2.write_operation(p_request,false) $$;
create or replace function public.withdraw_catalog_product_v2(p_request jsonb) returns jsonb
language sql security definer set search_path='' as $$ select catalog_v2.write_operation(p_request,true) $$;

create function catalog_v2.resolve_publish_for_withdrawal(body jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare a uuid; op uuid; canonical_body text; prior catalog_v2.receipts%rowtype;
 canceled catalog_v2.publish_cancellations%rowtype; result jsonb; day_start timestamptz; retry_seconds integer;
begin
 a:=catalog_v2.live_account();
 op:=catalog_v2.publish_operation_id(body);
 canonical_body:=catalog_v2.canonical(body);
 select * into prior from catalog_v2.receipts where account_id=a and operation_id=op;
 if found then
  if exists(select 1 from catalog_v2.publish_cancellations where account_id=a and operation_id=op) then raise exception 'catalog operation invariant failed'; end if;
  if prior.operation<>'publish' or convert_to(prior.canonical_body,'UTF8')<>convert_to(canonical_body,'UTF8') then
   perform catalog_v2.fail('operation_conflict');
  end if;
  result:=catalog_v2.receipt(a,op,true);
  if result is null then raise exception 'catalog receipt invariant failed'; end if;
  return jsonb_build_object('outcome','committed','receipt',result);
 end if;
 select * into canceled from catalog_v2.publish_cancellations where account_id=a and operation_id=op;
 if found then
  if convert_to(canceled.canonical_body,'UTF8')<>convert_to(canonical_body,'UTF8') then perform catalog_v2.fail('operation_conflict'); end if;
  return jsonb_build_object('outcome','canceled_before_commit','operation_id',op,'replayed',true);
 end if;
 perform catalog_v2.validate_publish_cancellation(body);
 day_start:=date_trunc('day',transaction_timestamp() at time zone 'UTC') at time zone 'UTC';
 if (select count(*) from catalog_v2.publish_cancellations where account_id=a and created_at>=day_start and created_at<day_start+interval '24 hours')
    >=(select max_new_publish_cancellations_per_day from catalog_v2.settings) then
  retry_seconds:=greatest(1,least(86400,ceil(extract(epoch from day_start+interval '24 hours'-transaction_timestamp()))::integer));
  perform catalog_v2.fail('rate_limited',jsonb_build_object('retry_after_seconds',retry_seconds::text));
 end if;
 insert into catalog_v2.publish_cancellations(account_id,operation_id,canonical_body) values(a,op,canonical_body);
 return jsonb_build_object('outcome','canceled_before_commit','operation_id',op,'replayed',false);
end $$;
create function public.resolve_catalog_publish_for_withdrawal_v2(p_request jsonb) returns jsonb
language sql security definer set search_path='' as $$ select catalog_v2.resolve_publish_for_withdrawal(p_request) $$;

-- Newly created functions otherwise inherit PUBLIC EXECUTE, including the recreated writer name.
revoke all on function catalog_v2.write_operation_before_publish_cancellation(jsonb,boolean),
 catalog_v2.write_operation(jsonb,boolean),catalog_v2.publish_operation_id(jsonb),
 catalog_v2.validate_publish_cancellation(jsonb),catalog_v2.resolve_publish_for_withdrawal(jsonb)
 from public,anon,authenticated;
revoke all on function public.submit_catalog_product_v2(jsonb),public.withdraw_catalog_product_v2(jsonb),
 public.resolve_catalog_publish_for_withdrawal_v2(jsonb) from public,anon,authenticated;
grant execute on function public.submit_catalog_product_v2(jsonb),public.withdraw_catalog_product_v2(jsonb),
 public.resolve_catalog_publish_for_withdrawal_v2(jsonb) to authenticated;

-- Publish the capability atomically with the complete fence and resolver.
create or replace function public.catalog_capabilities_v2() returns jsonb
language plpgsql security definer set search_path='' as $$ declare a uuid; c catalog_v2.consent%rowtype; begin
 a:=catalog_v2.live_account(); select * into c from catalog_v2.consent where account_id=a;
 return jsonb_build_object('supported_version',2,'publish_resolution_version',1,'enabled',(select enabled from catalog_v2.settings),'limits',jsonb_build_object('max_envelope_bytes',16384,'max_facts',64,'max_search_limit',20),'current_consent_version',2,
 'caller_acknowledgment',case when c.acknowledged_version is not null then jsonb_build_object('version',c.acknowledged_version,'generation',c.acknowledged_generation::text) else null end,
 'consent_generation',coalesce(c.generation,0)::text,'sharing_permission',(select share_labels from public.profiles where id=a));
end $$;
revoke all on function public.catalog_capabilities_v2() from public,anon,authenticated;
grant execute on function public.catalog_capabilities_v2() to authenticated;
commit;
