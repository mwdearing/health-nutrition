-- An owner-reviewed snapshot (an approved legacy label, or a custom revision the owner reviewed) now ranks ahead of
-- unreviewed groups when the representative and the alternatives order are chosen, whatever their support. Support
-- alone only orders rows of the same review state. This matches lookup_label_v2 and the verification design:
-- flooding can change which unverified aggregate is shown but cannot displace an approved canonical.
-- `ordinal`, the alternatives fingerprint (built in ordinal order) and the cursor all derive from this one ordering,
-- so they stay consistent. A custom equivalence group counts as reviewed when any of its active revisions was
-- reviewed (equivalence covers facts, not display fields, so the group is shown through its earliest reviewed revision, the content the owner actually saw, or through its earliest revision when none was reviewed). The previous migrations' bytes are unchanged; only this function is replaced.
begin;
create or replace function catalog_v2.public_rows(p uuid)
returns table(ordinal bigint,revision bigint,support bigint,reviewed boolean,missing boolean,legacy boolean,content jsonb)
language sql stable set search_path='' as $$
with custom as (
   select coalesce(min(r.revision) filter (where exists(select 1 from catalog_v2.owner_reviews o where o.revision=r.revision)),min(r.revision)) revision,
    count(*) support,
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
-- Entries already 'verified' are left alone on purpose: a verified entry shows an owner-reviewed row that, under the
-- old order (support first), had the most support of every row, so it also has the most support among the reviewed
-- rows and stays first under the new order (reviewed first, then support). The seeded test checks that every
-- verified entry's first row is a reviewed one.
-- Lock first, then decide. Every unverified entry's identities and product rows are locked in the global order
-- (identity advisory locks in one ordered call, then product row locks), and only then is the reviewed condition
-- evaluated, so a concurrent review or submission cannot change the answer between the choice and the refresh.
-- Like backfill_legacy, this avoids per-product refreshes taking identity keys in product order, which can deadlock
-- with erase_account_labels. Refresh re-takes held locks.
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
commit;
