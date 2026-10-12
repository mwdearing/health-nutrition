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

-- The single pure authority for fresh operation shape, UUIDs, CAS syntax and consent syntax.
-- The common pre-replay envelope/operation-ID checks stay before receipt/marker lookup.
-- No account/policy lookups, identity allocation, moderation, or CAS execution occur here.
create function catalog_v2.validate_operation_envelope(body jsonb, withdrawing boolean) returns uuid
language plpgsql immutable security invoker set search_path='' as $$ declare pid uuid; begin
 if withdrawing then
  if not catalog_v2.object_shape(body,array['operation_id','client_revision_id','product_id','expected_server_revision']) then perform catalog_v2.fail('invalid_request'); end if;
 else
  if not catalog_v2.object_shape(body,array['operation_id','client_revision_id','product_id','expected_server_revision','consent_version','consent_generation','product']) or not catalog_v2.valid_product(body->'product') then perform catalog_v2.fail('invalid_request'); end if;
 end if;
 begin
  if jsonb_typeof(body->'client_revision_id')<>'string' or (body->>'client_revision_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then perform catalog_v2.fail('invalid_request'); end if;
  perform (body->>'client_revision_id')::uuid;
  if jsonb_typeof(body->'product_id') not in ('string','null') or (withdrawing and body->>'product_id' is null) then perform catalog_v2.fail('invalid_request'); end if;
  if body->>'product_id' is not null and (body->>'product_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then perform catalog_v2.fail('invalid_request'); end if;
  pid:=(body->>'product_id')::uuid;
 exception when invalid_text_representation then perform catalog_v2.fail('invalid_request'); end;
 if (withdrawing or body->'expected_server_revision'<>'null'::jsonb) and
  (jsonb_typeof(body->'expected_server_revision')<>'string' or (body->>'expected_server_revision')!~'^[1-9][0-9]*$') then perform catalog_v2.fail('invalid_request'); end if;
 if not withdrawing then
  if body->'product_id'='null'::jsonb and body->'expected_server_revision'<>'null'::jsonb then perform catalog_v2.fail('invalid_request'); end if;
  if body->'consent_version' is distinct from '2'::jsonb or jsonb_typeof(body->'consent_generation')<>'string' or (body->>'consent_generation')!~'^(0|[1-9][0-9]*)$' then perform catalog_v2.fail('invalid_request'); end if;
 end if;
 return pid;
end $$;

-- Retain the actual legacy bridge with only its fresh validation block extracted above.
-- Receipt lookup/comparison and everything from feature policy through lock acquisition,
-- identity/CAS, quota and receipt persistence remain verbatim from the guarded writer.
create or replace function catalog_v2.write_operation_before_publish_cancellation(body jsonb, withdrawing boolean) returns jsonb
language plpgsql set search_path='' as $$
declare a uuid; op uuid; pid uuid; code text; canonical_body text; prior catalog_v2.receipts%rowtype;
 c catalog_v2.contributions%rowtype; consent catalog_v2.consent%rowtype; rev bigint; used integer; content jsonb; source_name text; identity_created boolean:=false;
begin
 a:=catalog_v2.live_account();
 if body is null or jsonb_typeof(body)<>'object' then perform catalog_v2.fail('invalid_request'); end if;
 canonical_body:=catalog_v2.canonical(body);
 if octet_length(canonical_body)>16384 then perform catalog_v2.fail('invalid_request'); end if;
 begin
  if jsonb_typeof(body->'operation_id') is distinct from 'string' or (body->>'operation_id')!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then perform catalog_v2.fail('invalid_request'); end if;
  op:=(body->>'operation_id')::uuid;
 exception when invalid_text_representation then perform catalog_v2.fail('invalid_request'); end;
 select * into prior from catalog_v2.receipts where account_id=a and operation_id=op;
 if found then
  if prior.canonical_body<>canonical_body or prior.operation<>(case when withdrawing then 'withdraw' else 'publish' end) then perform catalog_v2.fail('operation_conflict'); end if;
  return catalog_v2.receipt(a,op,true);
 end if;
 pid:=catalog_v2.validate_operation_envelope(body,withdrawing);
 if not withdrawing then
  if not(select enabled from catalog_v2.settings) then perform catalog_v2.fail('unavailable'); end if;
  select * into consent from catalog_v2.consent where account_id=a;
  if not(select share_labels from public.profiles where id=a) or consent.acknowledged_version is distinct from 2 or consent.acknowledged_generation is distinct from consent.generation or body->>'consent_generation' is distinct from coalesce(consent.generation,0)::text then
   perform catalog_v2.fail('consent_required',jsonb_build_object('consent_generation',coalesce(consent.generation,0)::text)); end if;
  code:=body#>>'{product,barcode}';
  code:=case when length(code)=12 then '0'||code else code end;
  -- Include an explicitly addressed identity even for a rejected attempt to change its binding.
  perform catalog_v2.lock_identities(array[code]||array(select barcode from catalog_v2.barcode_bindings where product_id=pid));
  if code is not null then
   if pid is null then select product_id into pid from catalog_v2.barcode_bindings where barcode=code;
   elsif exists(select 1 from catalog_v2.barcode_bindings where barcode=code and product_id<>pid) then perform catalog_v2.fail('invalid_request'); end if;
  end if;
  if pid is null then
   insert into catalog_v2.products default values returning id into pid;
   identity_created:=true;
  end if;
 end if;
 if withdrawing then
  perform catalog_v2.lock_identities(array(select barcode from catalog_v2.barcode_bindings where product_id=pid));
 end if;
 perform catalog_v2.lock_products(array[pid]);
 if not exists(select 1 from catalog_v2.products where id=pid) then perform catalog_v2.fail('invalid_request'); end if;
 if not withdrawing then
  if exists(select 1 from catalog_v2.products where id=pid and kind is not null and kind<>body#>>'{product,kind}') then perform catalog_v2.fail('invalid_request'); end if;
  update catalog_v2.products set kind=body#>>'{product,kind}' where id=pid and kind is null;
  -- Barcode identities are immutable; adding/changing/removing one through an update is not permitted.
  if not identity_created and (select b.barcode from catalog_v2.barcode_bindings b where b.product_id=pid) is distinct from code then perform catalog_v2.fail('invalid_request'); end if;
  if code is not null then insert into catalog_v2.barcode_bindings values(code,pid) on conflict do nothing; end if;
  if catalog_v2.suppressed(pid,body#>>'{product,basis}') then perform catalog_v2.fail('rejected'); end if;
 end if;
 select * into c from catalog_v2.contributions where product_id=pid and account_id=a for update;
 if c.revision::text is distinct from body->>'expected_server_revision' or (withdrawing and c.revision is null) then
  perform catalog_v2.fail('revision_conflict',jsonb_build_object('current_revision',c.revision::text,'current_state',catalog_v2.current_state(pid,c.state))); end if;
 if withdrawing then
  select r.content,r.source_name into content,source_name from catalog_v2.revisions r where r.revision=c.revision;
 else content:=catalog_v2.display_product(body->'product'); source_name:=body#>>'{product,name}'; end if;
 insert into catalog_v2.revisions(product_id,account_id,content,equivalence,source_name) values(pid,a,content,catalog_v2.equivalence(content),source_name) returning revision into rev;
 insert into catalog_v2.contributions values(pid,a,rev,case when withdrawing then 'withdrawn' else 'active' end)
 on conflict(product_id,account_id) do update set revision=excluded.revision,state=excluded.state;
 if withdrawing then
  insert into catalog_v2.tombstones values(pid,a,rev) on conflict(product_id,account_id) do update set revision=excluded.revision;
 else
  insert into catalog.usage as u values(a,current_date,1) on conflict(device_id,day) do update set submissions=u.submissions+1 returning submissions into used;
  if used>(select daily_limit from catalog.settings) then perform catalog_v2.fail('rate_limited',jsonb_build_object('retry_after_seconds','86400')); end if;
 end if;
 perform catalog_v2.refresh(pid);
 insert into catalog_v2.receipts values(a,op,canonical_body,case when withdrawing then 'withdraw' else 'publish' end,pid,rev);
 return catalog_v2.receipt(a,op,false);
end $$;

create function catalog_v2.write_operation(body jsonb, withdrawing boolean) returns jsonb
language plpgsql security invoker set search_path='' as $$ declare a uuid; op uuid; begin
 a:=catalog_v2.live_account();
 op:=catalog_v2.publish_operation_id(body);
 -- Receipt-first replay remains authoritative inside the retained legacy writer.
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
 perform catalog_v2.validate_operation_envelope(body,false);
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
 catalog_v2.validate_operation_envelope(jsonb,boolean),catalog_v2.resolve_publish_for_withdrawal(jsonb)
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
