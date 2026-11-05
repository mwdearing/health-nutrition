-- An owner-reviewed snapshot (an approved legacy label, or a custom revision the owner reviewed) now ranks ahead of
-- unreviewed groups when the representative and the alternatives order are chosen, whatever their support. Support
-- alone only orders rows of the same review state. This matches lookup_label_v2 and the verification design:
-- flooding can change which unverified aggregate is shown but cannot displace an approved canonical.
-- `ordinal`, the alternatives fingerprint (built in ordinal order) and the cursor all derive from this one ordering,
-- so they stay consistent. A custom equivalence group counts as reviewed when any of its active revisions was
-- reviewed (the group is shown through its earliest revision, whose facts are equivalent). The previous migrations' bytes are unchanged; only this function is replaced.
begin;
create or replace function catalog_v2.public_rows(p uuid)
returns table(ordinal bigint,revision bigint,support bigint,reviewed boolean,missing boolean,legacy boolean,content jsonb)
language sql stable set search_path='' as $$
with custom as (
   select min(r.revision) revision,count(*) support,
    bool_or(exists(select 1 from catalog_v2.owner_reviews o where o.revision=r.revision)) group_reviewed
   from catalog_v2.contributions c join catalog_v2.revisions r on r.revision=c.revision
   join public.profiles pr on pr.id=c.account_id join auth.users u on u.id=pr.id and not u.is_anonymous
   where c.product_id=p and c.state='active' and not catalog_v2.suppressed(p,r.content->>'basis')
   group by r.equivalence
  ), candidates as (
   select r.revision,r.content,g.support,g.group_reviewed
    and exists(select 1 from jsonb_array_elements(r.content->'facts') f where f->>'state'='known') reviewed,
    not exists(select 1 from jsonb_array_elements(r.content->'facts') f where f->>'state'='known') missing,
    false legacy from custom g join catalog_v2.revisions r on r.revision=g.revision
   union all
   select lr.revision,l.content,l.support,l.reviewed,false,true
   from catalog_v2.barcode_bindings b cross join lateral catalog_v2.legacy_rows(b.barcode) l
   join catalog_v2.legacy_revisions lr on lr.product_id=p and lr.content=l.content
   where b.product_id=p and not catalog_v2.suppressed(p,l.content->>'basis')
  ) select row_number() over(order by reviewed desc,support desc,revision),revision,support::bigint,reviewed,missing,legacy,content
 from candidates where not catalog_v2.suppressed(p) order by reviewed desc,support desc,revision;
$$;

-- Stored search entries copy the representative's name. Rebuild those whose displayed representative is not the
-- reviewed row that public_rows now ranks first, so the reviewed name becomes searchable again.
-- Like backfill_legacy, freeze the affected set first, take the complete identity advisory-lock set in one
-- globally ordered call, then the product row locks, and only then refresh. Per-product refreshes would take
-- identity keys in product order, which can deadlock with erase_account_labels. Refresh re-takes held locks.
do $refresh$ declare ids uuid[]; codes text[]; p uuid; begin
 select array_agg(e.product_id order by e.product_id) into ids from catalog_v2.entries e
  where e.publication#>>'{verification,status}' is distinct from 'verified'
   and exists(select 1 from catalog_v2.public_rows(e.product_id) r where r.reviewed);
 if ids is null then return; end if;
 select array_agg(distinct b.barcode) into codes from catalog_v2.barcode_bindings b where b.product_id=any(ids);
 perform catalog_v2.lock_identities(coalesce(codes,'{}'));
 perform catalog_v2.lock_products(ids);
 foreach p in array ids loop perform catalog_v2.refresh(p); end loop;
end $refresh$;
commit;
