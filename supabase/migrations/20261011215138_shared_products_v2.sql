-- Additive v2 catalog. No client can access the private storage or administrative helpers.
-- Writer lock order: live profile -> sorted canonical barcode advisory locks -> sorted product UUIDs
-- -> sorted (product, account) contributions -> usage -> derived entries. Bridges and erasure must
-- collect their complete lock sets first and follow this same order. Receipts are checked under the
-- profile lock before identity creation or permission/consent checks. Replays never publish.
begin;
create schema catalog_v2;
revoke all on schema catalog_v2 from public, anon, authenticated;
create collation catalog_v2.unicode_lower (provider = icu, locale = 'und', deterministic = true);
create table catalog_v2.settings (singleton boolean primary key default true check(singleton), enabled boolean not null default true);
insert into catalog_v2.settings default values;
create table catalog_v2.consent (
 account_id uuid primary key references public.profiles(id) on delete cascade,
 generation bigint not null default 0 check(generation>=0), acknowledged_version integer,
 acknowledged_generation bigint
);
-- NULL kind is reserved for a future legacy-only identity, never guessed from a barcode.
create table catalog_v2.products (id uuid primary key default gen_random_uuid(),
 kind text check(kind in ('food','drink','supplement')));
create table catalog_v2.barcode_bindings (
 barcode text primary key, product_id uuid not null unique references catalog_v2.products(id)
);
create table catalog_v2.revisions (
 revision bigint generated always as identity primary key,
 product_id uuid not null references catalog_v2.products(id),
 account_id uuid not null references public.profiles(id) on delete cascade,
 content jsonb not null, equivalence jsonb not null,
 source_name text not null check(char_length(source_name) between 1 and 120 and octet_length(source_name)<=480)
);
create index revisions_product on catalog_v2.revisions(product_id);
create table catalog_v2.contributions (
 product_id uuid not null references catalog_v2.products(id),
 account_id uuid not null references public.profiles(id) on delete cascade,
 revision bigint not null, state text not null check(state in ('active','withdrawn','rejected')),
 primary key(product_id,account_id)
);
create table catalog_v2.receipts (
 account_id uuid not null references public.profiles(id) on delete cascade,
 operation_id uuid not null, canonical_body text not null, operation text not null,
 product_id uuid not null references catalog_v2.products(id), revision bigint not null,
 primary key(account_id,operation_id)
);
create table catalog_v2.tombstones (
 product_id uuid not null references catalog_v2.products(id),
 account_id uuid not null references public.profiles(id) on delete cascade,
 revision bigint not null, primary key(product_id,account_id)
);
create table catalog_v2.usage (
 account_id uuid not null references public.profiles(id) on delete cascade,
 day date not null, submissions integer not null, primary key(account_id,day)
);
create table catalog_v2.entries (
 product_id uuid primary key references catalog_v2.products(id),
 normalized_name text collate "C" not null, kind text not null, publication jsonb not null,
 source_name text not null check(char_length(source_name) between 1 and 120 and octet_length(source_name)<=480)
);
create index entries_search on catalog_v2.entries(normalized_name,product_id);
create table catalog_v2.rejections (product_id uuid primary key references catalog_v2.products(id));
-- Review attaches to immutable representative content; client agreement never writes this table.
create table catalog_v2.owner_reviews (revision bigint primary key references catalog_v2.revisions(revision) on delete cascade);
do $$ declare t text; begin
 foreach t in array array['settings','consent','products','barcode_bindings','revisions','contributions','receipts','tombstones','usage','entries','rejections','owner_reviews'] loop
  execute format('alter table catalog_v2.%I enable row level security',t);
 end loop;
end $$;
revoke all on all tables in schema catalog_v2 from public,anon,authenticated;
revoke all on all sequences in schema catalog_v2 from public,anon,authenticated;

create function catalog_v2.fail(code text, metadata jsonb default '{}'::jsonb) returns void
language plpgsql set search_path='' as $$ begin
 raise exception 'catalog request failed' using errcode='P0001', detail=(jsonb_build_object('code',code)||metadata)::text;
end $$;

-- JSONB's serializer uses spaces/short escapes; the contract instead defines these exact UTF-8 bytes.
create function catalog_v2.quote_scalar(s text) returns text
language plpgsql immutable strict set search_path='' as $$
declare out text := '"'; c text; n integer;
begin
 for i in 1..char_length(s) loop
  c := substr(s,i,1); n := ascii(c);
  out := out || case when n<32 then chr(92)||'u'||lpad(to_hex(n),4,'0')
                    when c in ('"',chr(92)) then chr(92)||c else c end;
 end loop;
 return out||'"';
end $$;
create function catalog_v2.canonical(j jsonb, depth integer default 0) returns text
language plpgsql immutable strict set search_path='' as $$
declare result text; begin
 -- Valid envelopes are at most four containers deep; bound recursion before visiting unknown fields.
 if depth>8 then perform catalog_v2.fail('invalid_request'); end if;
 case jsonb_typeof(j)
 when 'object' then
  select '{'||coalesce(string_agg(catalog_v2.quote_scalar(key)||':'||catalog_v2.canonical(value,depth+1),',' order by key collate "C"),'')||'}' into result from jsonb_each(j);
 when 'array' then
  select '['||coalesce(string_agg(catalog_v2.canonical(value,depth+1),',' order by ord),'')||']' into result from jsonb_array_elements(j) with ordinality a(value,ord);
 when 'string' then result:=catalog_v2.quote_scalar(j#>>'{}');
 when 'number' then result:=trim_scale((j#>>'{}')::numeric)::text;
 else result:=j::text;
 end case;
 return result;
end $$;
create function catalog_v2.trim_whitespace(s text) returns text
language sql immutable strict set search_path='' as $$
 select regexp_replace(s,U&'^[\0009-\000D\0020\0085\00A0\1680\2000-\200A\2028\2029\202F\205F\3000]+|[\0009-\000D\0020\0085\00A0\1680\2000-\200A\2028\2029\202F\205F\3000]+$','','g');
$$;
create function catalog_v2.search_name(s text) returns text
language sql immutable strict set search_path='' as $$
 select btrim(regexp_replace(lower(normalize(s,NFKC) collate catalog_v2.unicode_lower),
 U&'[\0009-\000D\0020\0085\00A0\1680\2000-\200A\2028\2029\202F\205F\3000]+',' ','g'));
$$;
create function catalog_v2.object_shape(j jsonb, required text[], optional text[] default '{}') returns boolean
language sql immutable set search_path='' as $$
 select coalesce(jsonb_typeof(j)='object' and j ?& required and not exists
 (select 1 from jsonb_object_keys(case when jsonb_typeof(j)='object' then j else '{}' end) k where not(k=any(required||optional))),false);
$$;
create function catalog_v2.decimal_value(j jsonb, positive boolean default false) returns boolean
language plpgsql immutable set search_path='' as $$ begin
 if j is null or jsonb_typeof(j)<>'string' or (j#>>'{}')!~'^(0|[1-9][0-9]*)(\.[0-9]{1,6})?$' or char_length(j#>>'{}')>17 then return false; end if;
 return (j#>>'{}')::numeric<=1000000000 and (not positive or (j#>>'{}')::numeric>0);
end $$;
create function catalog_v2.unit_dimension(u text) returns text
language sql immutable set search_path='' as $$ select case
 when u in ('g','mg','mcg','kg','oz') then 'mass'
 when u in ('mL','L','fl oz','cup','tbsp','tsp') then 'volume'
 when u='kcal' then 'energy' when u='IU' then 'IU'
 when u in ('serving','scoop','tablet','capsule','piece','gummy') then u else null end $$;
create function catalog_v2.unit_factor(u text) returns numeric
language sql immutable set search_path='' as $$ select case u
 when 'mg' then .001 when 'mcg' then .000001 when 'kg' then 1000 when 'oz' then 28.349523125
 when 'L' then 1000 when 'fl oz' then 29.5735295625 when 'cup' then 236.5882365
 when 'tbsp' then 14.78676478125 when 'tsp' then 4.92892159375 else 1 end $$;
create function catalog_v2.valid_barcode(s text) returns boolean
language plpgsql immutable set search_path='' as $$ declare total integer:=0; begin
 if s is null then return true; end if;
 if s!~'^([0-9]{8}|[0-9]{12}|[0-9]{13})$' then return false; end if;
 for i in 1..length(s) loop total:=total+substr(s,length(s)-i+1,1)::integer * case when i%2=0 then 3 else 1 end; end loop;
 return total%10=0;
end $$;
create function catalog_v2.valid_product(p jsonb) returns boolean
language plpgsql immutable set search_path='' as $$
declare f jsonb; s jsonb; keys text[]:='{}'; k text; dim text;
begin
 if not catalog_v2.object_shape(p,array['name','brand','barcode','kind','basis','serving','facts']) then return false; end if;
 if jsonb_typeof(p->'name')<>'string' or char_length(p->>'name') not between 1 and 120 or char_length(normalize(p->>'name',NFC))>120 or catalog_v2.search_name(p->>'name')='' then return false; end if;
 if jsonb_typeof(p->'brand') not in ('null','string') or char_length(p->>'brand')>80 or char_length(normalize(p->>'brand',NFC))>80 then return false; end if;
 if jsonb_typeof(p->'barcode') not in ('null','string') or not catalog_v2.valid_barcode(p->>'barcode') then return false; end if;
 if coalesce(p->>'kind','') not in ('food','drink','supplement') or coalesce(p->>'basis','') not in ('per_100_g','per_100_ml','per_serving') then return false; end if;
 s:=p->'serving';
 if s<>'null'::jsonb then
  if not catalog_v2.object_shape(s,array['quantity','unit'],array['text']) or not catalog_v2.decimal_value(s->'quantity',true) then return false; end if;
  if catalog_v2.unit_dimension(s->>'unit') is null or s->>'unit' in ('kcal','IU') then return false; end if;
  if s?'text' and (jsonb_typeof(s->'text')<>'string' or char_length(s->>'text')>80 or char_length(normalize(s->>'text',NFC))>80) then return false; end if;
 end if;
 if jsonb_typeof(p->'facts')<>'array' then return false; end if;
 if jsonb_array_length(p->'facts')>64 then return false; end if;
 for f in select value from jsonb_array_elements(p->'facts') loop
  if not catalog_v2.object_shape(f,array['key','display_name','state'],array['amount','unit']) then return false; end if;
  k:=f->>'key';
  if jsonb_typeof(f->'key')<>'string' or char_length(k) not between 1 and 64 or k collate "C"=any(keys) then return false; end if;
  keys:=array_append(keys,k);
  if k not in ('energyKcal','fat','saturatedFat','transFat','cholesterol','sodium','carbohydrates','fiber','sugars','addedSugars','protein','vitaminD','calcium','iron','potassium') and not(left(k,11)='ingredient:' and char_length(k)>11) then return false; end if;
  if jsonb_typeof(f->'display_name')<>'string' or char_length(f->>'display_name') not between 1 and 120 or char_length(normalize(f->>'display_name',NFC))>120 or catalog_v2.search_name(f->>'display_name')='' then return false; end if;
  if coalesce(f->>'state','')='known' then
   if not catalog_v2.decimal_value(f->'amount') or not(f?'unit') then return false; end if;
   if p->>'basis'='per_serving' and s='null'::jsonb then return false; end if;
  elsif f->>'state'='below_reporting_threshold' then
   if f?'amount' then return false; end if;
  elsif f->>'state' in ('unknown','not_applicable') then
   if f?'amount' or f?'unit' then return false; end if;
  else return false;
  end if;
  if f?'unit' then
   dim:=catalog_v2.unit_dimension(f->>'unit');
   if dim is null or jsonb_typeof(f->'unit')<>'string' then return false; end if;
   if k='energyKcal' and dim<>'energy' then return false; end if;
   if left(k,11)<>'ingredient:' and k<>'energyKcal' and dim<>'mass' then return false; end if;
  end if;
 end loop;
 return true;
end $$;
-- Only display strings normalize. Fact key bytes are deliberately left untouched.
create function catalog_v2.display_product(p jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$ declare result jsonb:=p; f jsonb; facts jsonb:='[]'; begin
 result:=jsonb_set(result,'{name}',to_jsonb(normalize(p->>'name',NFC)));
 if p->>'brand' is not null then result:=jsonb_set(result,'{brand}',to_jsonb(normalize(p->>'brand',NFC))); end if;
 if p#>>'{serving,text}' is not null then result:=jsonb_set(result,'{serving,text}',to_jsonb(normalize(p#>>'{serving,text}',NFC))); end if;
 for f in select value from jsonb_array_elements(p->'facts') loop facts:=facts||jsonb_build_array(jsonb_set(f,'{display_name}',to_jsonb(normalize(f->>'display_name',NFC)))); end loop;
 return jsonb_set(result,'{facts}',facts);
end $$;
create function catalog_v2.equivalence(p jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare f jsonb; facts jsonb:='[]'; v jsonb; s jsonb:=p->'serving'; begin
 if s<>'null'::jsonb then s:=jsonb_build_object('dimension',catalog_v2.unit_dimension(s->>'unit'),'quantity',(s->>'quantity')::numeric*catalog_v2.unit_factor(s->>'unit')); end if;
 for f in select value from jsonb_array_elements(p->'facts') order by value->>'key' collate "C" loop
  v:=f-array['display_name','amount','unit'];
  if f->>'state'='known' then v:=v||jsonb_build_object('dimension',catalog_v2.unit_dimension(f->>'unit'),'amount',(f->>'amount')::numeric*catalog_v2.unit_factor(f->>'unit'));
  elsif f?'unit' then v:=v||jsonb_build_object('unit',f->>'unit'); end if;
  facts:=facts||jsonb_build_array(v);
 end loop;
 return jsonb_build_object('kind',p->'kind','basis',p->'basis','serving',s,'facts',facts);
end $$;

create function catalog_v2.live_account() returns uuid
language plpgsql set search_path='' as $$ declare a uuid:=auth.uid(); begin
 if a is null or coalesce(auth.jwt()->>'is_anonymous','false')<>'false' then perform catalog_v2.fail('unauthorized'); end if;
 perform 1 from public.profiles p where p.id=a for update;
 if not found or not exists(select 1 from auth.users u where u.id=a and not u.is_anonymous) then perform catalog_v2.fail('unauthorized'); end if;
 return a;
end $$;
create function catalog_v2.permission_generation() returns trigger
language plpgsql security definer set search_path='' as $$ begin
 if old.share_labels and not new.share_labels then
  insert into catalog_v2.consent(account_id,generation) values(new.id,1)
  on conflict(account_id) do update set generation=catalog_v2.consent.generation+1;
 end if;
 return new;
end $$;
create trigger catalog_v2_permission_generation after update of share_labels on public.profiles
 for each row execute function catalog_v2.permission_generation();

create function public.catalog_capabilities_v2() returns jsonb
language plpgsql security definer set search_path='' as $$ declare a uuid; c catalog_v2.consent%rowtype; begin
 a:=catalog_v2.live_account(); select * into c from catalog_v2.consent where account_id=a;
 return jsonb_build_object('supported_version',2,'enabled',(select enabled from catalog_v2.settings),'limits',jsonb_build_object('max_envelope_bytes',16384,'max_facts',64,'max_search_limit',20),'current_consent_version',2,
 'caller_acknowledgment',case when c.acknowledged_version is not null then jsonb_build_object('version',c.acknowledged_version,'generation',c.acknowledged_generation::text) else null end,
 'consent_generation',coalesce(c.generation,0)::text,'sharing_permission',(select share_labels from public.profiles where id=a));
end $$;
create function public.acknowledge_catalog_consent_v2(p_version integer) returns jsonb
language plpgsql security definer set search_path='' as $$ declare a uuid; g bigint; begin
 a:=catalog_v2.live_account();
 if p_version is distinct from 2 then perform catalog_v2.fail('invalid_request'); end if;
 insert into catalog_v2.consent(account_id,acknowledged_version,acknowledged_generation) values(a,2,0)
 on conflict(account_id) do update set acknowledged_version=2,acknowledged_generation=catalog_v2.consent.generation returning generation into g;
 return jsonb_build_object('version',2,'generation',g::text,'acknowledged',true);
end $$;

-- Caller holds product lock. Select an actual representative, never averages. Earliest accepted revision
-- wins support ties, and every active account contributes at most one support to one alternative.
create function catalog_v2.refresh(p uuid) returns void
language plpgsql set search_path='' as $$
declare grp record; content jsonb; source_name text; representative_source text; alternatives jsonb:='[]'; publication jsonb; threshold text; missing boolean; reviewed boolean; begin
 delete from catalog_v2.entries where product_id=p;
 if exists(select 1 from catalog_v2.rejections where product_id=p) then return; end if;
 select min_devices::text into threshold from catalog.settings;
 for grp in
  select r.equivalence,count(*) as support,min(r.revision) as representative
  from catalog_v2.contributions c join catalog_v2.revisions r on r.revision=c.revision
  join public.profiles pr on pr.id=c.account_id join auth.users u on u.id=pr.id and not u.is_anonymous
  where c.product_id=p and c.state='active' group by r.equivalence order by count(*) desc,min(r.revision)
 loop
  select r.content,r.source_name into content,source_name from catalog_v2.revisions r where r.revision=grp.representative;
  if publication is null then
   representative_source:=source_name;
   missing:=not exists(select 1 from jsonb_array_elements(content->'facts') f where f->>'state'='known');
   reviewed:=not missing and exists(select 1 from catalog_v2.owner_reviews where revision=grp.representative);
   publication:=jsonb_build_object('product_id',p,'representative_revision',grp.representative::text,'product',content,
    'source',jsonb_build_object('product_id',p,'representative_revision',grp.representative::text,'attribution','Shared community product'),
    'verification',jsonb_build_object('status',case when reviewed then 'verified' else 'shared_unverified' end,'source',case when reviewed then 'owner_reviewed' else null end),
    'support',jsonb_build_object('distinct_accounts',grp.support::text,'verification_threshold',threshold),'missing_facts',missing);
  else
   alternatives:=alternatives||jsonb_build_array(jsonb_build_object('representative_revision',grp.representative::text,'product',content,'support',jsonb_build_object('distinct_accounts',grp.support::text,'verification_threshold',threshold)));
  end if;
 end loop;
 if publication is not null then insert into catalog_v2.entries values(p,catalog_v2.search_name(publication#>>'{product,name}'),publication#>>'{product,kind}',publication||jsonb_build_object('alternatives',alternatives),representative_source); end if;
end $$;
-- Private owner-only moderation path follows the product lock order, never granted to application roles.
create function catalog_v2.moderate(p uuid, rejected boolean, reviewed_revision bigint default null) returns void
language plpgsql set search_path='' as $$ begin
 perform 1 from catalog_v2.products where id=p for update;
 if rejected then insert into catalog_v2.rejections values(p) on conflict do nothing;
 else delete from catalog_v2.rejections where product_id=p; end if;
 if reviewed_revision is not null then
  if not exists(select 1 from catalog_v2.revisions where revision=reviewed_revision and product_id=p and exists(select 1 from jsonb_array_elements(content->'facts') f where f->>'state'='known')) then perform catalog_v2.fail('invalid_request'); end if;
  insert into catalog_v2.owner_reviews values(reviewed_revision) on conflict do nothing;
 end if;
 perform catalog_v2.refresh(p);
end $$;
create function catalog_v2.publication(p uuid) returns jsonb
language sql set search_path='' as $$ select e.publication from catalog_v2.entries e
 where e.product_id=p and not exists(select 1 from catalog_v2.rejections r where r.product_id=p) $$;
-- Moderation changes visibility, not an account's accepted revision or withdrawal history.
create function catalog_v2.current_state(p uuid, state text) returns text
language sql set search_path='' as $$ select case when state='active' and exists
 (select 1 from catalog_v2.rejections where product_id=p) then 'rejected' else coalesce(state,'none') end $$;
create function catalog_v2.receipt(a uuid, op uuid, replay boolean) returns jsonb
language sql set search_path='' as $$
 select jsonb_build_object('operation_id',op,'product_id',r.product_id,'acknowledged_revision',r.revision::text,
 'current_revision',c.revision::text,'current_state',catalog_v2.current_state(c.product_id,c.state),'publication',catalog_v2.publication(r.product_id),'replayed',replay)
 from catalog_v2.receipts r join catalog_v2.contributions c on c.product_id=r.product_id and c.account_id=a
 where r.account_id=a and r.operation_id=op $$;

create function catalog_v2.write_operation(body jsonb, withdrawing boolean) returns jsonb
language plpgsql set search_path='' as $$
declare a uuid; op uuid; pid uuid; code text; canonical_body text; prior catalog_v2.receipts%rowtype;
 c catalog_v2.contributions%rowtype; consent catalog_v2.consent%rowtype; rev bigint; used integer; content jsonb; source_name text;
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
  if code is not null then
   code:=case when length(code)=12 then '0'||code else code end;
   perform pg_advisory_xact_lock(hashtextextended('catalog_v2|'||code,0));
   if pid is null then select product_id into pid from catalog_v2.barcode_bindings where barcode=code;
   elsif exists(select 1 from catalog_v2.barcode_bindings where barcode=code and product_id<>pid) then perform catalog_v2.fail('invalid_request'); end if;
  end if;
  if pid is null then insert into catalog_v2.products default values returning id into pid; end if;
 end if;
 perform 1 from catalog_v2.products where id=pid for update;
 if not found then perform catalog_v2.fail('invalid_request'); end if;
 if not withdrawing then
  if exists(select 1 from catalog_v2.products where id=pid and kind is not null and kind<>body#>>'{product,kind}') then perform catalog_v2.fail('invalid_request'); end if;
  update catalog_v2.products set kind=body#>>'{product,kind}' where id=pid and kind is null;
  -- Barcode identities are immutable; adding/changing/removing one through an update is not permitted.
  if exists(select 1 from catalog_v2.barcode_bindings b where b.product_id=pid and b.barcode is distinct from code) then perform catalog_v2.fail('invalid_request'); end if;
  if code is not null then insert into catalog_v2.barcode_bindings values(code,pid) on conflict do nothing; end if;
  if exists(select 1 from catalog_v2.rejections where product_id=pid) then perform catalog_v2.fail('rejected'); end if;
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
  insert into catalog_v2.usage as u values(a,current_date,1) on conflict(account_id,day) do update set submissions=u.submissions+1 returning submissions into used;
  if used>(select daily_limit from catalog.settings) then perform catalog_v2.fail('rate_limited',jsonb_build_object('retry_after_seconds','86400')); end if;
 end if;
 perform catalog_v2.refresh(pid);
 insert into catalog_v2.receipts values(a,op,canonical_body,case when withdrawing then 'withdraw' else 'publish' end,pid,rev);
 return catalog_v2.receipt(a,op,false);
end $$;
create function public.submit_catalog_product_v2(p_request jsonb) returns jsonb
language sql security definer set search_path='' as $$ select catalog_v2.write_operation(p_request,false) $$;
create function public.withdraw_catalog_product_v2(p_request jsonb) returns jsonb
language sql security definer set search_path='' as $$ select catalog_v2.write_operation(p_request,true) $$;
create function public.get_my_catalog_contribution_v2(p_product_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$ declare a uuid; c catalog_v2.contributions%rowtype; begin
 a:=catalog_v2.live_account(); if p_product_id is null then perform catalog_v2.fail('invalid_request'); end if;
 select * into c from catalog_v2.contributions where product_id=p_product_id and account_id=a;
 return jsonb_build_object('product_id',p_product_id,'current_revision',c.revision::text,'current_state',catalog_v2.current_state(p_product_id,c.state));
end $$;
create function public.get_catalog_product_v2(p_product_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$ begin
 perform catalog_v2.live_account(); if p_product_id is null then perform catalog_v2.fail('invalid_request'); end if;
 return jsonb_build_object('product',catalog_v2.publication(p_product_id));
end $$;
create function public.search_catalog_products_v2(p_query text,p_kind text default null,p_cursor text default null,p_limit integer default 20) returns jsonb
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
 for row in select e.* from catalog_v2.entries e where strpos(e.normalized_name,q)>0 and (p_kind is null or e.kind=p_kind)
  and not exists(select 1 from catalog_v2.rejections r where r.product_id=e.product_id)
  and (last_id is null or (e.normalized_name,e.product_id)>(last_name collate "C",last_id))
  order by e.normalized_name,e.product_id limit p_limit+1 loop
  n:=n+1;
  if n>p_limit then next_cursor:='2.'||fingerprint||'.'||last_id::text||'.'||replace(encode(convert_to(source_name,'UTF8'),'base64'),E'\n',''); exit; end if;
  products:=products||jsonb_build_array(row.publication); last_name:=row.normalized_name; last_id:=row.product_id; source_name:=row.source_name;
 end loop;
 return jsonb_build_object('products',products,'next_cursor',next_cursor);
end $$;
revoke all on all functions in schema catalog_v2 from public,anon,authenticated;
revoke all on function public.catalog_capabilities_v2(),public.acknowledge_catalog_consent_v2(integer),public.submit_catalog_product_v2(jsonb),public.withdraw_catalog_product_v2(jsonb),public.search_catalog_products_v2(text,text,text,integer),public.get_catalog_product_v2(uuid),public.get_my_catalog_contribution_v2(uuid) from public,anon,authenticated;
grant execute on function public.catalog_capabilities_v2(),public.acknowledge_catalog_consent_v2(integer),public.submit_catalog_product_v2(jsonb),public.withdraw_catalog_product_v2(jsonb),public.search_catalog_products_v2(text,text,text,integer),public.get_catalog_product_v2(uuid),public.get_my_catalog_contribution_v2(uuid) to authenticated;
commit;
