-- Synthetic behavior checks; each failure aborts the disposable database run.
begin;
update catalog.settings set daily_limit=100;
insert into auth.users(id) values ('20000000-0000-4000-8000-000000000001'), ('20000000-0000-4000-8000-000000000002');
set local role authenticated;
select set_config('request.jwt.claim.sub','20000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"is_anonymous":false}',true);
select public.acknowledge_catalog_consent_v2(2);
do $$
declare body jsonb; first jsonb; replay jsonb; removed jsonb; withdrawal jsonb; fresh jsonb; detail text;
begin
 body := jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),'product_id',null,'expected_server_revision',null,'consent_version',2,'consent_generation','0','product',jsonb_build_object('name','Synthetic percent%_\\ drink','brand',null,'barcode',null,'kind','drink','basis','per_serving','serving',null,'facts','[]'::jsonb));
 first := public.submit_catalog_product_v2(body);
 assert first->>'current_state'='active';
 assert first->'publication'->'verification'->>'status'='shared_unverified';
 assert first->'publication'->>'missing_facts'='true';
 replay := public.submit_catalog_product_v2(body);
 assert replay->>'product_id'=first->>'product_id' and (replay->>'replayed')::boolean;
 begin
  perform public.submit_catalog_product_v2(jsonb_set(body,'{product,name}','"different"'));
  raise exception 'modified replay accepted';
 exception when sqlstate 'P0001' then
  get stacked diagnostics detail = pg_exception_detail;
  assert detail::jsonb->>'code'='operation_conflict';
 end;
 fresh := body || jsonb_build_object('operation_id',gen_random_uuid());
 replay := public.submit_catalog_product_v2(fresh);
 assert replay->>'product_id'<>first->>'product_id', 'name must not merge identities';
 withdrawal := jsonb_build_object('operation_id',gen_random_uuid(),'client_revision_id',gen_random_uuid(),'product_id',first->>'product_id','expected_server_revision',first->>'current_revision');
 update public.profiles set share_labels=false where id=auth.uid();
 removed := public.withdraw_catalog_product_v2(withdrawal);
 assert removed->>'current_state'='withdrawn';
 replay := public.submit_catalog_product_v2(body);
 assert replay->>'current_state'='withdrawn' and replay->'publication'='null'::jsonb;
 assert public.catalog_capabilities_v2()->>'consent_generation'='1';
 update public.profiles set share_labels=true where id=auth.uid();
 perform public.acknowledge_catalog_consent_v2(2);
 fresh := body || jsonb_build_object('operation_id',gen_random_uuid(),'product_id',first->>'product_id','expected_server_revision',removed->>'current_revision','consent_generation','1');
 replay := public.submit_catalog_product_v2(fresh);
 assert replay->>'current_state'='active';
 removed := public.withdraw_catalog_product_v2(withdrawal);
 assert removed->>'current_state'='active' and removed->>'current_revision'=replay->>'current_revision';
 begin
  perform public.submit_catalog_product_v2(fresh || jsonb_build_object('operation_id',gen_random_uuid()));
  raise exception 'stale CAS accepted';
 exception when sqlstate 'P0001' then
  get stacked diagnostics detail=pg_exception_detail;
  assert detail::jsonb->>'code'='revision_conflict';
 end;
 assert jsonb_array_length(public.search_catalog_products_v2('percent%_\\')->'products')=2;
 assert jsonb_array_length(public.search_catalog_products_v2('percentAA')->'products')=0;
end $$;
reset role;
rollback;
select 'SHARED PRODUCTS V2 SQL OK';
