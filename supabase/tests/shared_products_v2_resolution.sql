-- Cancellation is a separate operation outcome, never a fabricated withdrawal receipt.
begin;
do $$ begin
 assert to_regprocedure('public.resolve_catalog_publish_for_withdrawal_v2(jsonb)') is not null,
   'missing atomic publication resolution RPC';
end $$;
rollback;

-- Defense in depth: direct application access and PUBLIC's implicit execute are revoked.
begin;
do $$ declare f regprocedure; r text; begin
 foreach f in array array[
  'catalog_v2.write_operation_before_publish_cancellation(jsonb,boolean)'::regprocedure,
  'catalog_v2.write_operation(jsonb,boolean)'::regprocedure,
  'catalog_v2.publish_operation_id(jsonb)'::regprocedure,
  'catalog_v2.validate_operation_envelope(jsonb,boolean)'::regprocedure,
  'catalog_v2.resolve_publish_for_withdrawal(jsonb)'::regprocedure
 ] loop
  foreach r in array array['anon','authenticated'] loop
   assert not has_function_privilege(r,f,'execute');
  end loop;
  assert not exists(select 1 from pg_proc p, lateral aclexplode(p.proacl) a where p.oid=f and a.grantee=0);
  assert (select not prosecdef and proconfig=array['search_path=""']::text[] from pg_proc where oid=f);
 end loop;
 assert not has_function_privilege('anon','public.resolve_catalog_publish_for_withdrawal_v2(jsonb)','execute');
 assert has_function_privilege('authenticated','public.resolve_catalog_publish_for_withdrawal_v2(jsonb)','execute');
 assert not has_table_privilege('authenticated','catalog_v2.publish_cancellations','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER');
 assert not has_table_privilege('anon','catalog_v2.publish_cancellations','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER');
 assert (select relrowsecurity from pg_class where oid='catalog_v2.publish_cancellations'::regclass);
 assert not has_schema_privilege('authenticated','catalog_v2','USAGE');
 assert (select max_new_publish_cancellations_per_day=256 from catalog_v2.settings);
 begin update catalog_v2.settings set max_new_publish_cancellations_per_day=0;
  raise exception 'invalid cancellation bound accepted'; exception when check_violation then null; end;
 begin update catalog_v2.settings set max_new_publish_cancellations_per_day=10001;
  raise exception 'invalid cancellation bound accepted'; exception when check_violation then null; end;
end $$;
set local role authenticated;
do $$ begin
 begin perform 1 from catalog_v2.publish_cancellations;
  raise exception 'table accessible'; exception when insufficient_privilege then null; end;
 begin perform catalog_v2.write_operation_before_publish_cancellation('{}',false);
  raise exception 'retained writer accessible'; exception when insufficient_privilege then null; end;
 begin perform catalog_v2.write_operation('{}',false);
  raise exception 'wrapper accessible'; exception when insufficient_privilege then null; end;
 begin perform catalog_v2.resolve_publish_for_withdrawal('{}');
  raise exception 'resolver helper accessible'; exception when insufficient_privilege then null; end;
end $$;
rollback;
