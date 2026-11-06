-- An owner-reviewed row outranks unreviewed groups as the publication's representative, whatever the support.
-- Synthetic barcodes and accounts only; everything rolls back.
begin;
insert into auth.users(id) values ('49000000-0000-4000-8000-000000000001'),('49000000-0000-4000-8000-000000000002'),('49000000-0000-4000-8000-000000000003'),('49000000-0000-4000-8000-000000000004'),('49000000-0000-4000-8000-000000000005'),('49000000-0000-4000-8000-000000000006');
-- Case 1: an approved legacy label, then one account publishes a custom product on the same barcode.
select catalog.owner_approve_label('4006381333931','per_100g',null,'Synthetic reviewed oats',null,'{"protein":13,"fat":7,"carbohydrates":60}','reviewed');
set local role authenticated;
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000001';
select public.acknowledge_catalog_consent_v2(2);
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',null,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic single account oats','brand',null,'barcode','4006381333931','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','1','unit','g'))))) #> '{publication}' as pub \gset
select set_config('t.pub',:'pub',false) \g /dev/null
do $test$ declare p uuid; pub jsonb; alts jsonb; begin
 pub:=current_setting('t.pub')::jsonb;
 assert pub#>>'{product,name}'='Synthetic reviewed oats', 'representative must be the owner-reviewed snapshot';
 assert pub#>>'{verification,status}'='verified' and pub#>>'{verification,source}'='owner_reviewed';
 assert pub#>>'{product,legacy_source}'='owner_reviewed';
 p:=(pub->>'product_id')::uuid;
 assert public.get_catalog_product_v2(p)#>>'{product,verification,source}'='owner_reviewed';
 assert (select verification_source from public.lookup_label_v2('4006381333931'))='owner_reviewed';
 -- The single-account custom revision is demoted to the first alternative, unverified.
 alts:=public.get_catalog_product_alternatives_v2(p,null,20);
 assert alts#>>'{alternatives,0,product,name}'='Synthetic single account oats';
 assert alts#>>'{alternatives,0,support,distinct_accounts}'='1';
 assert (pub->>'alternatives_total')='1' and (alts->>'alternatives_total')='1';
 -- The reviewed name is searchable and resolves to the reviewed representative; the demoted name is not indexed.
 assert public.search_catalog_products_v2('reviewed oats')#>>'{products,0,product,name}'='Synthetic reviewed oats';
 assert public.search_catalog_products_v2('reviewed oats')#>>'{products,0,verification,source}'='owner_reviewed';
 assert jsonb_array_length(public.search_catalog_products_v2('single account')->'products')=0;
end $test$;
-- A second and third account agreeing on another custom group (support 2) still cannot outrank the reviewed row.
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000002';
select public.acknowledge_catalog_consent_v2(2);
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',null,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic flood oats','brand',null,'barcode','4006381333931','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','2','unit','g'))))) #> '{publication}' as pub2 \gset
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000003';
select public.acknowledge_catalog_consent_v2(2);
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',null,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic flood oats','brand',null,'barcode','4006381333931','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','2','unit','g'))))) #> '{publication}' as pub3 \gset
select set_config('t.pub3',:'pub3',false) \g /dev/null
do $test$ declare p uuid; pub jsonb; page1 jsonb; page2 jsonb; begin
 pub:=current_setting('t.pub3')::jsonb; p:=(pub->>'product_id')::uuid;
 assert pub#>>'{product,name}'='Synthetic reviewed oats' and pub#>>'{verification,source}'='owner_reviewed';
 assert pub#>>'{alternatives_total}'='2';
 -- Alternatives keep support order among unreviewed groups, and keyset pages stay consistent with the fingerprint.
 page1:=public.get_catalog_product_alternatives_v2(p,null,1);
 assert page1#>>'{alternatives,0,product,name}'='Synthetic flood oats' and page1#>>'{alternatives,0,support,distinct_accounts}'='2';
 page2:=public.get_catalog_product_alternatives_v2(p,page1->>'next_cursor',1);
 assert page2#>>'{alternatives,0,product,name}'='Synthetic single account oats' and page2->>'next_cursor' is null;
end $test$;
reset role;
do $test$ begin
 assert (select normalized_name from catalog_v2.entries e join catalog_v2.barcode_bindings b using(product_id) where b.barcode='4006381333931')
  =catalog_v2.search_name('Synthetic reviewed oats'), 'search entry follows the reviewed representative';
end $test$;
-- Case 2: a reviewed custom revision with support 1 outranks an unreviewed 2-account group.
set local role authenticated;
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000002';
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',null,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic crowd oats','brand',null,'barcode','9780201379624','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','2','unit','g'))))) #> '{publication}' as p2pub \gset
select set_config('t.p2',(:'p2pub'::jsonb->>'product_id'),false) \g /dev/null
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000003';
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',current_setting('t.p2')::uuid,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic crowd oats','brand',null,'barcode','9780201379624','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','2','unit','g'))))) #> '{publication}' as p2pub \gset
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000001';
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',current_setting('t.p2')::uuid,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic reviewed custom oats','brand',null,'barcode','9780201379624','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','5','unit','g'))))) #> '{publication}' as p2pub \gset
reset role;
do $test$ declare p uuid; rev bigint; begin
 p:=current_setting('t.p2')::uuid;
 assert public.get_catalog_product_v2(p)#>>'{product,product,name}'='Synthetic crowd oats', 'unreviewed support still orders unreviewed groups';
 select revision into rev from catalog_v2.revisions where product_id=p and content->>'name'='Synthetic reviewed custom oats';
 -- moderate's third argument records the owner review (inserts catalog_v2.owner_reviews) and refreshes the entry.
 perform catalog_v2.moderate(p,false,rev);
 assert exists(select 1 from catalog_v2.owner_reviews where revision=rev), 'owner review row recorded';
 assert public.get_catalog_product_v2(p)#>>'{product,product,name}'='Synthetic reviewed custom oats';
 assert public.get_catalog_product_v2(p)#>>'{product,verification,source}'='owner_reviewed';
 assert public.get_catalog_product_v2(p)#>>'{product,support,distinct_accounts}'='1';
 assert (select normalized_name from catalog_v2.entries where product_id=p)=catalog_v2.search_name('Synthetic reviewed custom oats');
end $test$;
-- Case 3: the owner reviews the LATER revision of a 2-account equivalence group; the group still outranks a 3-account
-- unreviewed group, because reviewed is a property of the whole group, not of its earliest revision.
reset role;
set local role authenticated;
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000004';
select public.acknowledge_catalog_consent_v2(2) \g /dev/null
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',null,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic crowd bars','brand',null,'barcode','9780132350884','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','3','unit','g'))))) #> '{publication}' as p3pub \gset
select set_config('t.p3',(:'p3pub'::jsonb->>'product_id'),false) \g /dev/null
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000005';
select public.acknowledge_catalog_consent_v2(2) \g /dev/null
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',current_setting('t.p3')::uuid,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic crowd bars','brand',null,'barcode','9780132350884','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','3','unit','g'))))) #> '{publication}' as p3pub \gset
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000006';
select public.acknowledge_catalog_consent_v2(2) \g /dev/null
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',current_setting('t.p3')::uuid,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic crowd bars','brand',null,'barcode','9780132350884','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','3','unit','g'))))) #> '{publication}' as p3pub \gset
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000001';
select public.acknowledge_catalog_consent_v2(2) \g /dev/null
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',current_setting('t.p3')::uuid,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic group bars','brand',null,'barcode','9780132350884','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','4','unit','g'))))) #> '{publication}' as p3pub \gset
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000002';
select public.acknowledge_catalog_consent_v2(2) \g /dev/null
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',current_setting('t.p3')::uuid,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic group bars','brand',null,'barcode','9780132350884','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','4','unit','g'))))) #> '{publication}' as p3pub \gset
reset role;
do $test$ declare p uuid; rev bigint; first_rev bigint; begin
 p:=current_setting('t.p3')::uuid;
 assert public.get_catalog_product_v2(p)#>>'{product,product,name}'='Synthetic crowd bars' and public.get_catalog_product_v2(p)#>>'{product,support,distinct_accounts}'='3';
 select min(revision),max(revision) into first_rev,rev from catalog_v2.revisions where product_id=p and content->>'name'='Synthetic group bars';
 assert first_rev<rev, 'the group has two revisions';
 perform catalog_v2.moderate(p,false,rev);
 assert not exists(select 1 from catalog_v2.owner_reviews where revision=first_rev);
 assert public.get_catalog_product_v2(p)#>>'{product,product,name}'='Synthetic group bars', 'a reviewed later revision makes the group the representative';
 assert public.get_catalog_product_v2(p)#>>'{product,verification,source}'='owner_reviewed';
 assert public.get_catalog_product_v2(p)#>>'{product,support,distinct_accounts}'='2';
end $test$;
-- Case 4: equivalence ignores display fields, so a group can hold two names. When the owner reviews the later
-- revision, the group is shown through that reviewed revision, not the earlier unreviewed one.
set local role authenticated;
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000001';
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',null,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic early name granola','brand',null,'barcode','9780306406157','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','6','unit','g'))))) #> '{publication}' as p4pub \gset
select set_config('t.p4',(:'p4pub'::jsonb->>'product_id'),false) \g /dev/null
set local request.jwt.claim.sub='49000000-0000-4000-8000-000000000002';
select public.submit_catalog_product_v2(jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),
 'product_id',current_setting('t.p4')::uuid,'expected_server_revision',null,'consent_version',2,'consent_generation','0',
 'product',jsonb_build_object('name','Synthetic reviewed name granola','brand',null,'barcode','9780306406157','kind','food',
 'basis','per_100_g','serving',null,'facts',jsonb_build_array(jsonb_build_object('key','protein','display_name','Protein','state','known','amount','6','unit','g'))))) #> '{publication}' as p4pub \gset
reset role;
do $test$ declare p uuid; rev bigint; begin
 p:=current_setting('t.p4')::uuid;
 assert public.get_catalog_product_v2(p)#>>'{product,product,name}'='Synthetic early name granola', 'unreviewed group shows its earliest revision';
 select revision into rev from catalog_v2.revisions where product_id=p and content->>'name'='Synthetic reviewed name granola';
 perform catalog_v2.moderate(p,false,rev);
 assert public.get_catalog_product_v2(p)#>>'{product,product,name}'='Synthetic reviewed name granola', 'the reviewed revision is the one displayed';
 assert public.get_catalog_product_v2(p)#>>'{product,verification,source}'='owner_reviewed';
 assert public.get_catalog_product_v2(p)#>>'{product,support,distinct_accounts}'='2';
 assert (select normalized_name from catalog_v2.entries where product_id=p)=catalog_v2.search_name('Synthetic reviewed name granola');
end $test$;
-- The migration's one-time refresh: an entry whose stored search name predates the reviewed ranking is rebuilt.
-- The block below is the migration's own, run here against seeded data because the migration itself runs on an
-- empty database in this suite and returns at its first guard.
-- Before this migration the stored entry showed an unverified representative; restore that stored shape.
update catalog_v2.entries set normalized_name='stale search name', publication=jsonb_set(publication,'{verification,status}','"unverified"')
 where product_id=current_setting('t.p4')::uuid;
-- Entries already verified keep a reviewed first row (so the migration may leave them alone).
do $verified$ begin
 assert not exists(select 1 from catalog_v2.entries e where e.publication#>>'{verification,status}'='verified'
  and not exists(select 1 from catalog_v2.public_rows(e.product_id) r where r.ordinal=1 and r.reviewed)),
  'every verified entry shows a reviewed first row';
end $verified$;
do $refresh$ declare ids uuid[]; codes text[]; p uuid; begin
 select array_agg(e.product_id order by e.product_id) into ids from catalog_v2.entries e
  where e.publication#>>'{verification,status}' is distinct from 'verified';
 if ids is null then return; end if;
 select array_agg(distinct b.barcode) into codes from catalog_v2.barcode_bindings b where b.product_id=any(ids);
 perform catalog_v2.lock_identities(coalesce(codes,'{}'));
 perform catalog_v2.lock_products(ids);
 foreach p in array ids loop
  if exists(select 1 from catalog_v2.public_rows(p) r where r.reviewed) then perform catalog_v2.refresh(p); end if;
 end loop;
 end $refresh$;
do $after$ begin
 assert (select normalized_name from catalog_v2.entries where product_id=current_setting('t.p4')::uuid)=catalog_v2.search_name('Synthetic reviewed name granola'), 'the refresh rebuilt the stale search name';
end $after$;
rollback;
select 'REVIEWED REPRESENTATIVE OK';
