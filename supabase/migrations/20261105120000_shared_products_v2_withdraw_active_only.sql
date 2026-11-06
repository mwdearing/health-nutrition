-- A contribution that is already withdrawn cannot be withdrawn again. Before this, the compare-and-set check only
-- compared revisions, so repeating a withdrawal with the latest revision and a fresh operation ID wrote a new
-- revision, receipt and tombstone every time. The retained writer is replaced with its body verbatim except for the
-- added state guard; it reports the existing typed revision_conflict with current_revision and current_state.
-- Receipt replay runs before the check, so an exact replay of the original withdrawal is unaffected.
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
 if c.revision::text is distinct from body->>'expected_server_revision' then
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
