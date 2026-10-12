-- Bound every public embedding and expose complete alternatives through authenticated keyset pages.
-- Existing request/receipt identity and historical migration bytes are unchanged.
begin;
create function catalog_v2.public_rows(p uuid)
returns table(ordinal bigint,revision bigint,support bigint,reviewed boolean,missing boolean,legacy boolean,content jsonb)
language sql stable set search_path='' as $$
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
  ) select row_number() over(order by support desc,revision),revision,support::bigint,reviewed,missing,legacy,content
 from candidates where not catalog_v2.suppressed(p) order by support desc,revision;
$$;
create function catalog_v2.public_row(p uuid,r bigint,content jsonb,support bigint,reviewed boolean,missing boolean,legacy boolean,representative boolean)
returns jsonb language plpgsql stable set search_path='' as $$
declare result jsonb; src jsonb; verification jsonb; begin
 -- Display-only projection for historical names whose original CHECK bounded btrim, not raw bytes.
 -- Stored submissions, approvals and immutable legacy source revisions are never changed.
 if legacy and content->>'name'<>btrim(content->>'name') then
  content:=jsonb_set(content,'{name}',to_jsonb(btrim(content->>'name')))||jsonb_build_object('name_display_trimmed',true);
 end if;
 src:=jsonb_build_object('product_id',p,'representative_revision',r::text,'attribution',case when legacy then 'Legacy label catalog' else 'Shared community product' end);
 verification:=jsonb_build_object('status',case when reviewed then 'verified' else 'shared_unverified' end,'source',case when reviewed then 'owner_reviewed' else null end);
 result:=jsonb_build_object('representative_revision',r::text,'product',content,'support',jsonb_build_object('distinct_accounts',support::text,'verification_threshold',(select min_devices::text from catalog.settings)));
 if legacy or representative then result:=result||jsonb_build_object('source',src,'verification',verification); end if;
 if representative then result:=result||jsonb_build_object('product_id',p,'missing_facts',missing); end if;
 return result;
end $$;

-- All cursor material is public: product UUID, fingerprint of ordered public revisions/support/review,
-- last public revision. No account, contribution or moderation-reason data enters it.
create function catalog_v2.alternatives_cursor(p uuid,fingerprint text,last_revision bigint) returns text
language sql immutable set search_path='' as $$ select '1.'||p::text||'.'||fingerprint||'.'||last_revision::text $$;

create function catalog_v2.bounded_publication(p uuid,cursor text,lim integer,as_publication boolean) returns jsonb
language plpgsql stable set search_path='' as $$
declare total bigint; fingerprint text; parts text[]; after_ordinal bigint:=1; row record;
 result jsonb; candidate jsonb; alternatives jsonb:='[]'; value jsonb; next_cursor text; included integer:=0;
 byte_limit integer:=case when as_publication then 261120 else 262144 end;
begin
 if p is null or lim is null or lim not between 1 and 20 then perform catalog_v2.fail('invalid_request'); end if;
 select count(*),md5(jsonb_build_array((select min_devices from catalog.settings),coalesce(string_agg(jsonb_build_array(r.revision,r.support,r.reviewed)::text,',' order by r.ordinal),''))::text)
 into total,fingerprint from catalog_v2.public_rows(p) r;
 if cursor is not null then
  if as_publication or octet_length(cursor)>1024 then perform catalog_v2.fail('invalid_request'); end if;
  parts:=string_to_array(cursor,'.');
  if cardinality(parts)<>4 or parts[1]<>'1' or parts[2]<>p::text or parts[3]!~'^[0-9a-f]{32}$'
    or parts[4]!~'^[1-9][0-9]{0,18}$' then perform catalog_v2.fail('invalid_request'); end if;
  if parts[3]<>fingerprint then perform catalog_v2.fail('revision_conflict'); end if;
  select r.ordinal into after_ordinal from catalog_v2.public_rows(p) r where r.revision::text=parts[4];
  if after_ordinal is null then perform catalog_v2.fail('invalid_request'); end if;
 end if;
 if as_publication and total=0 then return null; end if;
 if as_publication then
  select * into row from catalog_v2.public_rows(p) r where r.ordinal=1;
  result:=catalog_v2.public_row(p,row.revision,row.content,row.support,row.reviewed,row.missing,row.legacy,true);
  next_cursor:=case when total>1 then catalog_v2.alternatives_cursor(p,fingerprint,row.revision) else null end;
  result:=result||jsonb_build_object('alternatives','[]'::jsonb,'alternatives_total',greatest(0,total-1)::text,'alternatives_cursor',next_cursor);
 else
  result:=jsonb_build_object('product_id',p,'alternatives','[]'::jsonb,'alternatives_total',greatest(0,total-1)::text,'next_cursor',null);
 end if;
 for row in select * from catalog_v2.public_rows(p) r where r.ordinal>after_ordinal order by r.ordinal loop
  if included=lim then exit; end if;
  value:=catalog_v2.public_row(p,row.revision,row.content,row.support,row.reviewed,row.missing,row.legacy,false);
  next_cursor:=case when row.ordinal<total then catalog_v2.alternatives_cursor(p,fingerprint,row.revision) else null end;
  candidate:=result||jsonb_build_object('alternatives',alternatives||jsonb_build_array(value),
    case when as_publication then 'alternatives_cursor' else 'next_cursor' end,next_cursor);
  if octet_length(candidate::text)>byte_limit then exit; end if;
  result:=candidate; alternatives:=alternatives||jsonb_build_array(value); included:=included+1;
 end loop;
 -- A custom candidate's closed scalar/fact bounds are <128 KiB even without the 16 KiB input bound;
 -- legacy's closed nutrient registry is smaller. At least one always fits a 256 KiB page.
 -- 1024 bytes reserved above cover UUIDs, bigint decimal revisions and all receipt/resolver/detail wrappers.
 if octet_length(result::text)>byte_limit or (not as_publication and total>after_ordinal and included=0) then
  raise exception 'bounded publication invariant failed';
 end if;
 return result;
end $$;
create or replace function catalog_v2.build_publication(p uuid) returns jsonb
language sql stable set search_path='' as $$ select catalog_v2.bounded_publication(p,null,20,true) $$;
create function public.get_catalog_product_alternatives_v2(p_product_id uuid,p_cursor text default null,p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path='' as $$ begin
 perform catalog_v2.live_account(); return catalog_v2.bounded_publication(p_product_id,p_cursor,p_limit,false);
end $$;
create or replace function public.search_catalog_products_v2(p_query text,p_kind text default null,p_cursor text default null,p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path='' as $$
declare q text; fingerprint text; parts text[]; source_name text; last_name text; last_id uuid; row record; products jsonb:='[]'; next_cursor text; n integer:=0; candidate jsonb; candidate_cursor text;
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
  candidate_cursor:='2.'||fingerprint||'.'||row.product_id::text||'.'||replace(encode(convert_to(row.source_name,'UTF8'),'base64'),E'\n','');
  candidate:=jsonb_build_object('products',products||jsonb_build_array(row.publication),'next_cursor',candidate_cursor);
  if octet_length(candidate::text)>786432 then
   next_cursor:='2.'||fingerprint||'.'||last_id::text||'.'||replace(encode(convert_to(source_name,'UTF8'),'base64'),E'\n',''); exit;
  end if;
  products:=products||jsonb_build_array(row.publication); last_name:=row.normalized_name; last_id:=row.product_id; source_name:=row.source_name;
 end loop;
 return jsonb_build_object('products',products,'next_cursor',next_cursor);
end $$;
create or replace function public.catalog_capabilities_v2() returns jsonb
language plpgsql security definer set search_path='' as $$ declare a uuid; c catalog_v2.consent%rowtype; begin
 a:=catalog_v2.live_account(); select * into c from catalog_v2.consent where account_id=a;
 return jsonb_build_object('supported_version',2,'publish_resolution_version',1,'bounded_publication_version',1,'enabled',(select enabled from catalog_v2.settings),'limits',jsonb_build_object('max_envelope_bytes',16384,'max_facts',64,'max_search_limit',20),'current_consent_version',2,
 'caller_acknowledgment',case when c.acknowledged_version is not null then jsonb_build_object('version',c.acknowledged_version,'generation',c.acknowledged_generation::text) else null end,
 'consent_generation',coalesce(c.generation,0)::text,'sharing_permission',(select share_labels from public.profiles where id=a));
end $$;
revoke all on function catalog_v2.public_rows(uuid),catalog_v2.public_row(uuid,bigint,jsonb,bigint,boolean,boolean,boolean,boolean),
 catalog_v2.alternatives_cursor(uuid,text,bigint),catalog_v2.bounded_publication(uuid,text,integer,boolean) from public,anon,authenticated;
revoke all on function public.get_catalog_product_alternatives_v2(uuid,text,integer) from public,anon,authenticated;
grant execute on function public.get_catalog_product_alternatives_v2(uuid,text,integer) to authenticated;
commit;
