-- Shared identity and safety bridge. Retain the installed legacy policy, including owner-only
-- verification when that migration is installed. No legacy vote verifies custom content.
-- Global lock order: live profile (account operations only), then the complete set of signed bigint
-- advisory keys sorted numerically, then products sorted by UUID, contributions, usage, derived rows.
-- Each barcode contributes catalog_v2|code and ALL three legacy code|basis hashes. Multi-product
-- operations collect the entire set before locking any product. Inner calls only reacquire held keys.
begin;
alter table catalog_v2.entries alter column kind drop not null;
create table catalog_v2.legacy_revisions (
 revision bigint primary key default nextval('catalog_v2.revisions_revision_seq'),
 product_id uuid not null references catalog_v2.products(id), content jsonb not null
);
create index legacy_revisions_product on catalog_v2.legacy_revisions(product_id);
alter table catalog_v2.legacy_revisions enable row level security;
revoke all on catalog_v2.legacy_revisions from public,anon,authenticated;

create function catalog_v2.lock_identities(codes text[]) returns void
language plpgsql set search_path='' as $$ declare k bigint; begin
 for k in select distinct hashtextextended(v,0) from unnest(codes) c cross join lateral
  (values ('catalog_v2|'||c),(c||'|per_100g'),(c||'|per_100ml'),(c||'|per_serving')) x(v)
  where c is not null order by 1 loop perform pg_advisory_xact_lock(k); end loop;
end $$;
create function catalog_v2.lock_products(ids uuid[]) returns void
language plpgsql set search_path='' as $$ begin
 perform 1 from catalog_v2.products where id=any(ids) order by id for update;
 perform 1 from catalog_v2.contributions where product_id=any(ids) order by product_id,account_id for update;
 perform 1 from catalog.submissions s join catalog_v2.barcode_bindings b on b.barcode=s.barcode
 where b.product_id=any(ids) order by b.product_id,s.device_id,s.basis for update of s;
end $$;
-- Caller already holds the complete identity lock set. Binding never infers kind.
create function catalog_v2.bind_legacy(code text) returns uuid
language plpgsql set search_path='' as $$ declare p uuid; begin
 select product_id into p from catalog_v2.barcode_bindings where barcode=code;
 if p is null then
  insert into catalog_v2.products default values returning id into p;
  insert into catalog_v2.barcode_bindings values(code,p);
 end if;
 return p;
end $$;
create function catalog_v2.legacy_basis(b text) returns text
language sql immutable set search_path='' as $$ select case b when 'per_100_g' then 'per_100g' when 'per_100_ml' then 'per_100ml' else b end $$;
create function catalog_v2.suppressed(p uuid,b text default null) returns boolean
language sql stable set search_path='' as $$ select exists(select 1 from catalog_v2.rejections where product_id=p)
 or exists(select 1 from catalog.rejections r join catalog_v2.barcode_bindings bb on bb.barcode=r.barcode
 where bb.product_id=p and r.basis=catalog_v2.legacy_basis(b)) $$;

-- Private retained implementations are never API-callable. Renaming preserves whichever reviewed
-- legacy policy preceded this migration; wrappers do not restore automatic verification.
alter function public.submit_label(text,text,text,text,text,jsonb) set schema catalog_v2;
alter function catalog_v2.submit_label(text,text,text,text,text,jsonb) rename to legacy_submit;
alter function public.lookup_label(text) set schema catalog_v2;
alter function catalog_v2.lookup_label(text) rename to legacy_lookup;
alter function catalog.refresh_entry(text,text) rename to refresh_entry_pre_bridge;

create function catalog_v2.legacy_rows(code text) returns table(content jsonb,support integer,reviewed boolean)
language plpgsql stable set search_path='' as $$ declare row record; has_owner boolean:=to_regclass('catalog.approved_entries') is not null; begin
 for row in select e.* from catalog.entries e where e.barcode=code order by e.basis loop
  if has_owner then
   if exists(select 1 from catalog_v2.legacy_approved(code) a where a->>'basis'=row.basis) then continue; end if;
  end if;
  content:=jsonb_build_object('content_type','legacy_label','name',row.product_name,'brand',row.brand,
   'barcode',code,'kind',null,'basis',row.basis,'serving',null,'raw_serving_text',row.serving_text,
   'nutrients',row.nutrients,'legacy_source','community'); support:=row.supporting_devices; reviewed:=false; return next;
 end loop;
 if has_owner then
  for row in select value from catalog_v2.legacy_approved(code) value loop
   content:=jsonb_build_object('content_type','legacy_label','name',row.value->>'product_name','brand',row.value->'brand',
    'barcode',code,'kind',null,'basis',row.value->>'basis','serving',null,'raw_serving_text',row.value->'serving_text',
    'nutrients',row.value->'nutrients','legacy_source','owner_reviewed'); support:=0; reviewed:=true; return next;
  end loop;
 end if;
end $$;
create function catalog_v2.legacy_approved(code text) returns setof jsonb
language plpgsql stable set search_path='' as $$ begin
 if to_regclass('catalog.approved_entries') is not null then
  return query execute 'select to_jsonb(a) from catalog.approved_entries a where barcode=$1 order by basis' using code;
 end if;
end $$;

-- Construct current visibility on every read, including receipt replay and subsequent search pages.
-- Custom and legacy groups stay separate even when numbers happen to agree.
create function catalog_v2.build_publication(p uuid) returns jsonb
language plpgsql stable set search_path='' as $$
declare item record; result jsonb; alternatives jsonb:='[]'; threshold text; v jsonb; src jsonb; begin
 if catalog_v2.suppressed(p) then return null; end if;
 select min_devices::text into threshold from catalog.settings;
 for item in
  with custom as (
   select min(r.revision) revision,count(*) support
   from catalog_v2.contributions c join catalog_v2.revisions r on r.revision=c.revision
   join public.profiles pr on pr.id=c.account_id join auth.users u on u.id=pr.id and not u.is_anonymous
   where c.product_id=p and c.state='active' and not catalog_v2.suppressed(p,r.content->>'basis')
   group by r.equivalence
  ), candidates as (
   select r.revision,r.content,g.support,exists(select 1 from catalog_v2.owner_reviews o where o.revision=r.revision)
    and exists(select 1 from jsonb_array_elements(r.content->'facts') f where f->>'state'='known') reviewed,
    not exists(select 1 from jsonb_array_elements(r.content->'facts') f where f->>'state'='known') missing,
    false legacy from custom g join catalog_v2.revisions r on r.revision=g.revision
   union all
   select lr.revision,l.content,l.support,l.reviewed,false,true
   from catalog_v2.barcode_bindings b cross join lateral catalog_v2.legacy_rows(b.barcode) l
   join catalog_v2.legacy_revisions lr on lr.product_id=p and lr.content=l.content
   where b.product_id=p and not catalog_v2.suppressed(p,l.content->>'basis')
  ) select * from candidates order by support desc,revision
 loop
  src:=jsonb_build_object('product_id',p,'representative_revision',item.revision::text,'attribution',case when item.legacy then 'Legacy label catalog' else 'Shared community product' end);
  v:=jsonb_build_object('status',case when item.reviewed then 'verified' else 'shared_unverified' end,'source',case when item.reviewed then 'owner_reviewed' else null end);
  if result is null then
   result:=jsonb_build_object('product_id',p,'representative_revision',item.revision::text,'product',item.content,'source',src,
    'verification',v,'support',jsonb_build_object('distinct_accounts',item.support::text,'verification_threshold',threshold),'missing_facts',item.missing);
  else
   alternatives:=alternatives||jsonb_build_array(jsonb_build_object('representative_revision',item.revision::text,'product',item.content,
    'support',jsonb_build_object('distinct_accounts',item.support::text,'verification_threshold',threshold)) ||
    case when item.legacy then jsonb_build_object('source',src,'verification',v) else '{}'::jsonb end);
  end if;
 end loop;
 return result||jsonb_build_object('alternatives',alternatives);
end $$;
create or replace function catalog_v2.refresh(p uuid) returns void
language plpgsql set search_path='' as $$ declare pub jsonb; begin
 -- Public callers already hold these locks; direct administrative refresh follows the same order.
 perform catalog_v2.lock_identities(array(select barcode from catalog_v2.barcode_bindings where product_id=p));
 perform catalog_v2.lock_products(array[p]);
 insert into catalog_v2.legacy_revisions(product_id,content)
 select p,l.content from catalog_v2.barcode_bindings b cross join lateral catalog_v2.legacy_rows(b.barcode) l
 where b.product_id=p and not exists(select 1 from catalog_v2.legacy_revisions lr where lr.product_id=p and lr.content=l.content);
 pub:=catalog_v2.build_publication(p);
 delete from catalog_v2.entries where product_id=p;
 if pub is not null then
  insert into catalog_v2.entries values(p,catalog_v2.search_name(pub#>>'{product,name}'),
    (select kind from catalog_v2.products where id=p),pub,pub#>>'{product,name}');
 end if;
end $$;
create or replace function catalog_v2.publication(p uuid) returns jsonb
language sql stable set search_path='' as $$ select catalog_v2.build_publication(p) $$;
create or replace function catalog_v2.current_state(p uuid,state text) returns text
language sql stable set search_path='' as $$ select case when state='active' and
 (catalog_v2.suppressed(p) or exists(select 1 from catalog_v2.contributions c join catalog_v2.revisions r on r.revision=c.revision
 where c.product_id=p and c.account_id=auth.uid() and catalog_v2.suppressed(p,r.content->>'basis')))
 then 'rejected' else coalesce(state,'none') end $$;

create or replace function catalog.refresh_entry(p_barcode text,p_basis text) returns void
language plpgsql security definer set search_path='' as $$ declare p uuid; code text:=catalog.canonical_barcode(p_barcode); begin
 perform catalog_v2.lock_identities(array[code]); p:=catalog_v2.bind_legacy(code);
 perform catalog_v2.lock_products(array[p]);
 perform catalog.refresh_entry_pre_bridge(code,p_basis);
 perform catalog_v2.refresh(p);
end $$;
-- Old clients retain their established authentication SQLSTATE as well as response shapes.
create function catalog_v2.live_legacy_account() returns uuid
language plpgsql set search_path='' as $$ declare a uuid:=auth.uid(); begin
 if a is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) then
  raise exception 'sign in with an account first' using errcode='28000';
 end if;
 perform 1 from public.profiles where id=a for update;
 if not found or not exists(select 1 from auth.users where id=a and not is_anonymous) then
  raise exception 'account not found' using errcode='28000';
 end if;
 return a;
end $$;
create function public.submit_label(p_barcode text,p_basis text,p_serving_text text,p_product_name text,p_brand text,p_nutrients jsonb) returns text
language plpgsql security definer set search_path='' as $$ declare a uuid; p uuid; code text; result text; begin
 a:=catalog_v2.live_legacy_account();
 if not catalog.valid_barcode(p_barcode) then raise exception 'invalid label' using errcode='22023'; end if;
 code:=catalog.canonical_barcode(p_barcode);
 perform catalog_v2.lock_identities(array[code]); p:=catalog_v2.bind_legacy(code);
 perform catalog_v2.lock_products(array[p]);
 result:=catalog_v2.legacy_submit(p_barcode,p_basis,p_serving_text,p_product_name,p_brand,p_nutrients);
 if catalog_v2.suppressed(p,p_basis) then return 'received'; end if;
 return result;
end $$;
create function public.lookup_label(p_barcode text)
returns table(basis text,serving_text text,product_name text,brand text,nutrients jsonb,supporting_devices integer,verified boolean)
language sql stable security definer set search_path='' as $$
 select l.* from catalog_v2.legacy_lookup(p_barcode) l
 where exists(select 1 from public.profiles where id=auth.uid())
 and not exists(select 1 from catalog_v2.barcode_bindings b where b.barcode=catalog.canonical_barcode(p_barcode) and catalog_v2.suppressed(b.product_id,l.basis)) $$;

-- One usage ledger across old and new endpoints. Existing accepted v2 operations are retained.
insert into catalog.usage(device_id,day,submissions) select account_id,day,submissions from catalog_v2.usage
on conflict(device_id,day) do update set submissions=catalog.usage.submissions+excluded.submissions;
-- Keep the old private table for additive rollback compatibility; all new increments use catalog.usage.

create or replace function catalog_v2.write_operation(body jsonb, withdrawing boolean) returns jsonb
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
create or replace function public.search_catalog_products_v2(p_query text,p_kind text default null,p_cursor text default null,p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path='' as $$
declare q text; fingerprint text; parts text[]; source_name text; last_name text; last_id uuid; row record; products jsonb:='[]'; next_cursor text; n integer:=0;
begin
 perform catalog_v2.live_account(); q:=catalog_v2.search_name(p_query);
 if q is null or char_length(catalog_v2.trim_whitespace(p_query)) not between 2 and 120 or q='' or p_limit is null or p_limit not between 1 and 20 or (p_kind is not null and p_kind not in ('food','drink','supplement')) then perform catalog_v2.fail('invalid_request'); end if;
 fingerprint:=md5(jsonb_build_array(q,p_kind)::text);
 if p_cursor is not null then
  if octet_length(p_cursor)>1024 then perform catalog_v2.fail('invalid_request'); end if;
  begin
   parts:=string_to_array(p_cursor,'.');
   if cardinality(parts)<>4 or parts[1]<>'2' or parts[2]<>fingerprint or parts[4]!~'^[A-Za-z0-9+/]*={0,2}$' then perform catalog_v2.fail('invalid_request'); end if;
   source_name:=convert_from(decode(parts[4],'base64'),'UTF8'); last_id:=parts[3]::uuid;
   if char_length(source_name) not between 1 and 120 or octet_length(source_name)>480
      or parts[3]<>last_id::text or parts[4]<>replace(encode(convert_to(source_name,'UTF8'),'base64'),E'\n','') then perform catalog_v2.fail('invalid_request'); end if;
   last_name:=catalog_v2.search_name(source_name);
   if last_name='' then perform catalog_v2.fail('invalid_request'); end if;
  exception when others then perform catalog_v2.fail('invalid_request'); end;
 end if;
 for row in
  select e.product_id,e.publication,catalog_v2.search_name(e.publication#>>'{product,name}') normalized_name,
   e.publication#>>'{product,name}' source_name from (
    select p.id product_id,p.kind,catalog_v2.publication(p.id) publication from catalog_v2.entries stored join catalog_v2.products p on p.id=stored.product_id
   ) e where e.publication is not null and strpos(catalog_v2.search_name(e.publication#>>'{product,name}'),q)>0
   and (p_kind is null or e.kind=p_kind)
   and (last_id is null or (catalog_v2.search_name(e.publication#>>'{product,name}') collate "C",e.product_id)>(last_name collate "C",last_id))
   order by catalog_v2.search_name(e.publication#>>'{product,name}') collate "C",e.product_id limit p_limit+1 loop
  n:=n+1;
  if n>p_limit then next_cursor:='2.'||fingerprint||'.'||last_id::text||'.'||replace(encode(convert_to(source_name,'UTF8'),'base64'),E'\n',''); exit; end if;
  products:=products||jsonb_build_array(row.publication); last_name:=row.normalized_name; last_id:=row.product_id; source_name:=row.source_name;
 end loop;
 return jsonb_build_object('products',products,'next_cursor',next_cursor);
end $$;

create or replace function catalog_v2.moderate(p uuid,rejected boolean,reviewed_revision bigint default null) returns void
language plpgsql set search_path='' as $$ begin
 perform catalog_v2.lock_identities(array(select barcode from catalog_v2.barcode_bindings where product_id=p));
 perform catalog_v2.lock_products(array[p]);
 if rejected then insert into catalog_v2.rejections values(p) on conflict do nothing;
 else delete from catalog_v2.rejections where product_id=p; end if;
 if reviewed_revision is not null then
  if not exists(select 1 from catalog_v2.revisions where revision=reviewed_revision and product_id=p and exists(select 1 from jsonb_array_elements(content->'facts') f where f->>'state'='known')) then perform catalog_v2.fail('invalid_request'); end if;
  insert into catalog_v2.owner_reviews values(reviewed_revision) on conflict do nothing;
 end if;
 perform catalog_v2.refresh(p);
end $$;

-- Both existing withdrawal and deletion RPCs enter the shared profile/identity/product lock order.
create function catalog_v2.erase_account_labels(deleting boolean) returns integer
language plpgsql set search_path='' as $$
declare a uuid; codes text[]; ids uuid[]; code text; p uuid; removed integer; begin
 a:=catalog_v2.live_legacy_account();
 select array_agg(distinct barcode) into codes from (
  select barcode from catalog.submissions where device_id=a
  union select b.barcode from catalog_v2.barcode_bindings b where deleting and b.product_id in (
   select product_id from catalog_v2.revisions where account_id=a union select product_id from catalog_v2.receipts where account_id=a
   union select product_id from catalog_v2.contributions where account_id=a union select product_id from catalog_v2.tombstones where account_id=a)
 ) x;
 perform catalog_v2.lock_identities(codes);
 select array_agg(distinct id) into ids from (
  select b.product_id id from catalog_v2.barcode_bindings b where b.barcode=any(codes)
  union select product_id from catalog_v2.revisions where deleting and account_id=a
  union select product_id from catalog_v2.contributions where deleting and account_id=a
  union select product_id from catalog_v2.receipts where deleting and account_id=a
  union select product_id from catalog_v2.tombstones where deleting and account_id=a
 ) x;
 perform catalog_v2.lock_products(ids);
 select count(*) into removed from catalog.submissions where device_id=a;
 -- Complete keys are already held before deleting either legacy or v2 contributions.
 delete from catalog.submissions where device_id=a;
 if deleting then
  delete from catalog.usage where device_id=a;
  delete from public.profiles where id=a;
  delete from auth.users where id=a;
 end if;
 foreach code in array coalesce(codes,'{}') loop
  perform catalog.refresh_entry_pre_bridge(code,'per_100g');
  perform catalog.refresh_entry_pre_bridge(code,'per_100ml');
  perform catalog.refresh_entry_pre_bridge(code,'per_serving');
 end loop;
 foreach p in array coalesce(ids,'{}') loop perform catalog_v2.refresh(p); end loop;
 return removed;
end $$;
create or replace function public.withdraw_my_submissions() returns integer
language sql security definer set search_path='' as $$ select catalog_v2.erase_account_labels(false) $$;
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path='' as $$ begin perform catalog_v2.erase_account_labels(true); end $$;

-- Maintenance obtains ALL identity keys before products, not one identity after another product.
create function catalog_v2.backfill_legacy() returns text[]
language plpgsql set search_path='' as $$ declare codes text[]; code text; ids uuid[]; p uuid; begin
 -- Freeze the existing product set before identity locks; a concurrent new identity is a later operation.
 select array_agg(id) into ids from catalog_v2.products;
 select array_agg(distinct barcode) into codes from (
  select barcode from catalog.submissions union select barcode from catalog.entries union select barcode from catalog.rejections
  union select barcode from catalog_v2.barcode_bindings
 ) x;
 if to_regclass('catalog.approved_entries') is not null then
  execute 'select $1 || coalesce(array_agg(barcode),''{}'') from catalog.approved_entries' into codes using coalesce(codes,'{}');
 end if;
 perform catalog_v2.lock_identities(codes);
 for code in select distinct unnest(codes) order by 1 loop perform catalog_v2.bind_legacy(code); end loop;
 select array_agg(id order by id) into ids from catalog_v2.products where id=any(ids)
 or id in(select product_id from catalog_v2.barcode_bindings where barcode=any(codes));
 perform catalog_v2.lock_products(ids);
 foreach p in array coalesce(ids,'{}') loop perform catalog_v2.refresh(p); end loop;
 return coalesce(codes,'{}');
end $$;
create or replace function catalog.revalidate_all() returns void
language plpgsql security definer set search_path='' as $$ declare l record; codes text[]; begin
 codes:=catalog_v2.backfill_legacy();
 -- Operate on the captured set only: discovering a newly committed identity here would invert locks.
 delete from catalog.submissions where barcode=any(codes) and not catalog.valid_nutrients(nutrients);
 delete from catalog.entries where barcode=any(codes);
 for l in select distinct barcode,basis from catalog.submissions where barcode=any(codes) order by barcode,basis loop
  perform catalog.refresh_entry_pre_bridge(l.barcode,l.basis);
 end loop;
 for l in select product_id from catalog_v2.barcode_bindings where barcode=any(codes) order by product_id loop
  perform catalog_v2.refresh(l.product_id);
 end loop;
end $$;
create or replace function catalog.refresh_all() returns trigger
language plpgsql security definer set search_path='' as $$ begin perform catalog.revalidate_all(); return new; end $$;

-- Optional source-aware owner API is preserved as installed, never copied from an unmerged dependency.
do $wrap$
declare n text; args text; callargs text; begin
 if to_regprocedure('public.lookup_label_v2(text)') is not null then
  alter function public.lookup_label_v2(text) set schema catalog_v2;
  alter function catalog_v2.lookup_label_v2(text) rename to legacy_lookup_v2;
  execute $ddl$create function public.lookup_label_v2(p_barcode text)
   returns table(basis text,serving_text text,product_name text,brand text,nutrients jsonb,supporting_devices integer,verified boolean,verification_source text)
   language sql stable security definer set search_path='' as $body$
    select l.* from catalog_v2.legacy_lookup_v2(p_barcode) l
    where not exists(select 1 from catalog_v2.barcode_bindings b where b.barcode=catalog.canonical_barcode(p_barcode) and catalog_v2.suppressed(b.product_id,l.basis))
   $body$ $ddl$;
  revoke all on function public.lookup_label_v2(text) from public,anon;
  grant execute on function public.lookup_label_v2(text) to authenticated;
 end if;
 foreach n in array array['owner_approve_label','owner_reject_label','owner_clear_rejection','owner_revoke_label'] loop
  select pg_get_function_arguments(p.oid),array_to_string(p.proargnames,',') into args,callargs
   from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where ns.nspname='catalog' and p.proname=n;
  if found then
   execute format('alter function catalog.%I(%s) rename to %I',n,args,n||'_pre_bridge');
   execute format($ddl$create function catalog.%I(%s) returns void language plpgsql security definer set search_path='' as $body$
    declare p uuid; code text:=catalog.canonical_barcode(p_barcode); begin
     if not catalog.valid_barcode(p_barcode) then raise exception 'invalid label' using errcode='22023'; end if;
     perform catalog_v2.lock_identities(array[code]); p:=catalog_v2.bind_legacy(code);
     perform catalog_v2.lock_products(array[p]);
     perform catalog.%I(%s); perform catalog_v2.refresh(p);
    end $body$ $ddl$,n,args,n||'_pre_bridge',callargs);
  end if;
 end loop;
end $wrap$;
select catalog_v2.backfill_legacy();
revoke all on all functions in schema catalog_v2 from public,anon,authenticated;
revoke all on all functions in schema catalog from public,anon,authenticated;
revoke all on function public.submit_label(text,text,text,text,text,jsonb),public.lookup_label(text) from public,anon,authenticated;
grant execute on function public.submit_label(text,text,text,text,text,jsonb),public.lookup_label(text) to authenticated;
commit;
