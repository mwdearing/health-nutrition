-- Deliberately valid historical/raw names with unbounded outer ASCII spaces.
-- Local disposable fixture only; never rewrites stored label or reviewed snapshot bytes.
begin;
do $acl$ begin
 assert has_function_privilege('authenticated','public.get_catalog_product_alternatives_v2(uuid,text,integer)','EXECUTE');
 assert not has_function_privilege('anon','public.get_catalog_product_alternatives_v2(uuid,text,integer)','EXECUTE');
 assert not has_function_privilege('authenticated','catalog_v2.public_rows(uuid)','EXECUTE');
 assert not has_function_privilege('authenticated','catalog_v2.bounded_publication(uuid,text,integer,boolean)','EXECUTE');
end $acl$;
insert into auth.users(id) values ('48000000-0000-4000-8000-000000000001'),('48000000-0000-4000-8000-000000000002');
set local role authenticated;
set local request.jwt.claim.sub='48000000-0000-4000-8000-000000000001';
select public.submit_label('78126404','per_100g',null,repeat(' ',300000)||'Synthetic bounded legacy'||repeat(' ',300000),null,'{"protein":3,"fat":2,"salt":1}');
set local request.jwt.claim.sub='48000000-0000-4000-8000-000000000002';
select public.submit_label('78126404','per_100g',null,repeat(' ',300000)||'Synthetic bounded legacy'||repeat(' ',300000),null,'{"protein":3,"fat":2,"salt":1}');
reset role;
do $test$ begin
 assert (select bool_and(product_name='Synthetic bounded legacy') from catalog.submissions where barcode='78126404');
end $test$;
-- Current RPCs already trim. Seed a historical state permitted by the original table CHECKs.
update catalog.submissions set product_name=repeat(' ',300000)||'Synthetic bounded legacy'||repeat(' ',300000) where barcode='78126404';
select catalog.refresh_entry('78126404','per_100g');
do $test$ declare p uuid; result jsonb; raw_name text:=repeat(' ',300000)||'Synthetic bounded legacy'||repeat(' ',300000); begin
 select product_id into p from catalog_v2.barcode_bindings where barcode='78126404';
 result:=public.get_catalog_product_v2(p);
 assert octet_length(result::text)<=262144;
 assert result#>>'{product,product,name}'='Synthetic bounded legacy';
 assert result#>>'{product,product,name_display_trimmed}'='true';
 assert result#>>'{product,verification,status}'='shared_unverified';
 assert (select bool_and(product_name=raw_name) from catalog.submissions where barcode='78126404');
 assert (select product_name=raw_name from catalog.entries where barcode='78126404' and basis='per_100g');
 assert exists(select 1 from catalog_v2.legacy_revisions where product_id=p and content->>'name'=raw_name);
 -- Existing standalone lookup continues its exact original raw-name contract.
 assert (select product_name=raw_name from public.lookup_label('78126404'));
end $test$;
select catalog.owner_approve_label('78126404','per_100g',null,repeat(' ',350000)||'Synthetic reviewed legacy'||repeat(' ',350000),null,'{"protein":3,"fat":2,"salt":1}','reviewed');
do $test$ begin
 assert (select product_name='Synthetic reviewed legacy' from catalog.approved_entries where barcode='78126404');
end $test$;
update catalog.approved_entries set product_name=repeat(' ',350000)||'Synthetic reviewed legacy'||repeat(' ',350000) where barcode='78126404';
select catalog.refresh_entry('78126404','per_100g');
do $test$ declare p uuid; result jsonb; public_revision text; raw_name text:=repeat(' ',350000)||'Synthetic reviewed legacy'||repeat(' ',350000); begin
 select product_id into p from catalog_v2.barcode_bindings where barcode='78126404';
 result:=public.get_catalog_product_v2(p); public_revision:=result#>>'{product,representative_revision}';
 assert octet_length(result::text)<=262144;
 assert result#>>'{product,product,name}'='Synthetic reviewed legacy';
 assert result#>>'{product,product,name_display_trimmed}'='true';
 assert result#>>'{product,verification,source}'='owner_reviewed';
 assert result#>>'{product,product,legacy_source}'='owner_reviewed';
 assert (select product_name=raw_name from catalog.approved_entries where barcode='78126404' and basis='per_100g');
 assert exists(select 1 from catalog_v2.legacy_revisions where product_id=p and revision::text=public_revision and content->>'name'=raw_name);
 assert (select product_name=raw_name from public.lookup_label_v2('78126404') where verification_source='owner_reviewed');
end $test$;
-- A custom representative must not lend its facts/review to the separately attributed legacy alternative.
set local role authenticated;
set local request.jwt.claim.sub='48000000-0000-4000-8000-000000000001';
select public.acknowledge_catalog_consent_v2(2);
do $test$ declare p uuid; result jsonb; alt jsonb; begin
 p:=(public.search_catalog_products_v2('Synthetic reviewed')#>>'{products,0,product_id}')::uuid;
 result:=public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
  'product_id',p,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
  'product',jsonb_build_object('name','Synthetic custom representative','brand',null,'barcode','78126404','kind','food','basis','per_100_g','serving',null,'facts','[]'::jsonb)));
 assert result#>>'{publication,verification,status}'='shared_unverified';
 alt:=result#>'{publication,alternatives,0}';
 assert alt#>>'{product,name_display_trimmed}'='true' and alt#>>'{product,name}'='Synthetic reviewed legacy';
 assert alt#>>'{verification,source}'='owner_reviewed';
 assert alt#>>'{source,representative_revision}'=alt->>'representative_revision';
 assert (public.get_catalog_product_alternatives_v2(p,null,20)#>'{alternatives,0}')=alt;
 assert octet_length(result::text)<=262144;
end $test$;
reset role;
-- Exercise the scalar upper bound independently of the stricter 16 KiB request limit.
do $test$ declare facts jsonb; content jsonb; publication jsonb; begin
 select jsonb_agg(jsonb_build_object('key','ingredient:'||lpad(i::text,2,'0')||repeat(chr(1),51),
  'display_name','A'||repeat(chr(1),119),'state','known','amount','1000000000.000000','unit','mg'))
 into facts from generate_series(1,64) i;
 content:=jsonb_build_object('name','A'||repeat(chr(1),119),'brand',repeat(chr(1),80),'barcode',null,
  'kind','supplement','basis','per_serving','serving',jsonb_build_object('quantity','1000000000.000000','unit','capsule','text',repeat(chr(1),80)),'facts',facts);
 assert catalog_v2.valid_product(content);
 publication:=catalog_v2.public_row('48000000-0000-4000-8000-000000000001',9223372036854775807,content,9223372036854775807,true,false,false,true);
 assert octet_length(publication::text)<131072;
 -- Nine closed legacy nutrients, largest integer part and PostgreSQL division scale are still tiny.
 assert catalog.valid_nutrients('{"energyKcal":9000.000,"sodium":100000.000,"protein":1000.000,"carbohydrates":1000.000,"sugars":1000.000,"fat":1000.000,"saturatedFat":1000.000,"fiber":1000.000,"salt":1000.000}');
end $test$;
rollback;
select 'BOUNDED LEGACY DISPLAY OK';
