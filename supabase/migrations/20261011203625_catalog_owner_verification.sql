-- Community agreement remains shareable, but only an explicit project-owner review can mark a label verified.
-- Approved payloads are independent, bounded snapshots with no submitter or submission linkage.
begin;

create table catalog.approved_entries (
  barcode text not null,
  basis text not null check (basis in ('per_100g', 'per_100ml', 'per_serving')),
  serving_text text,
  product_name text not null,
  brand text,
  nutrients jsonb not null,
  approved_at timestamptz not null default now(),
  primary key (barcode, basis),
  check (barcode = catalog.canonical_barcode(barcode)),
  check (catalog.valid_barcode(barcode)),
  check (serving_text is null or char_length(serving_text) <= 80),
  check (basis <> 'per_serving' or char_length(btrim(coalesce(serving_text, ''))) > 0),
  check (char_length(btrim(product_name)) between 1 and 120),
  check (brand is null or char_length(brand) <= 80),
  check (catalog.valid_nutrients(nutrients))
);

create table catalog.moderation_audit (
  id bigint generated always as identity primary key,
  barcode text not null,
  basis text not null check (basis in ('per_100g', 'per_100ml', 'per_serving')),
  action text not null check (action in ('approve', 'reject', 'revoke', 'clear_rejection')),
  event_at timestamptz not null default now(),
  reason text not null check (reason in ('reviewed', 'needs_recheck', 'incorrect_label', 'spam', 'policy', 'withdrawn', 'other')),
  payload_digest text check (payload_digest is null or payload_digest ~ '^[0-9a-f]{32}$'),
  authority text not null default 'project_owner' check (authority = 'project_owner'),
  check (barcode = catalog.canonical_barcode(barcode)),
  check (catalog.valid_barcode(barcode))
);
create index moderation_audit_key_idx on catalog.moderation_audit (barcode, basis, id);

alter table catalog.approved_entries enable row level security;
alter table catalog.moderation_audit enable row level security;
revoke all on catalog.approved_entries, catalog.moderation_audit from public, anon, authenticated;

create function catalog.protect_moderation_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'moderation audit is append-only' using errcode = '42501';
end;
$$;
create trigger moderation_audit_immutable
  before update or delete on catalog.moderation_audit
  for each row execute function catalog.protect_moderation_audit();
create trigger moderation_audit_no_truncate
  before truncate on catalog.moderation_audit
  for each statement execute function catalog.protect_moderation_audit();
revoke all on function catalog.protect_moderation_audit() from public, anon, authenticated;

create function catalog.valid_moderation_reason(p_reason text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(p_reason in ('reviewed', 'needs_recheck', 'incorrect_label', 'spam', 'policy', 'withdrawn', 'other'), false);
$$;
revoke all on function catalog.valid_moderation_reason(text) from public, anon, authenticated;

-- The newest-100 candidate bound affects only community aggregation. A community row is never verified.
create or replace function catalog.refresh_entry(p_barcode text, p_basis text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  cfg catalog.settings%rowtype;
  cand bigint[];
  best bigint[] := '{}';
  grp bigint[];
  fin bigint[];
  prev integer;
  med jsonb;
  s record;
  t record;
  chosen record;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_barcode || '|' || p_basis, 0));
  select * into cfg from catalog.settings;

  if exists (select 1 from catalog.rejections where barcode = p_barcode and basis = p_basis) then
    delete from catalog.entries where barcode = p_barcode and basis = p_basis;
    return;
  end if;

  select array_agg(id) into cand from (
    select id from catalog.submissions where barcode = p_barcode and basis = p_basis
    order by updated_at desc, id desc limit 100) c;

  for s in select id, nutrients, coalesce(lower(btrim(serving_text)), '') as serving
           from catalog.submissions where id = any (coalesce(cand, '{}')) order by id loop
    grp := '{}';
    for t in select id, nutrients, coalesce(lower(btrim(serving_text)), '') as serving
             from catalog.submissions where id = any (cand) loop
      if (p_basis <> 'per_serving' or s.serving = t.serving)
         and catalog.agrees(s.nutrients, t.nutrients, cfg.tolerance_percent) then
        grp := grp || t.id;
      end if;
    end loop;
    fin := grp;
    for i in 1 .. 10 loop
      prev := coalesce(array_length(fin, 1), 0);
      exit when prev = 0;
      med := catalog.median_nutrients(fin);
      grp := '{}';
      for t in select id, nutrients from catalog.submissions where id = any (fin) loop
        if catalog.agrees(med, t.nutrients, cfg.tolerance_percent) then
          grp := grp || t.id;
        end if;
      end loop;
      exit when coalesce(array_length(grp, 1), 0) = prev;
      fin := grp;
    end loop;
    if coalesce(array_length(fin, 1), 0) > coalesce(array_length(best, 1), 0) then
      best := fin;
    end if;
  end loop;

  if coalesce(array_length(best, 1), 0) < cfg.min_shown then
    delete from catalog.entries where barcode = p_barcode and basis = p_basis;
    return;
  end if;

  med := catalog.median_nutrients(best);
  select product_name, brand, serving_text into chosen
  from catalog.submissions where id = any (best)
  group by product_name, brand, serving_text
  order by count(*) desc, min(id) limit 1;

  insert into catalog.entries (barcode, basis, serving_text, product_name, brand, nutrients, supporting_devices, verified)
  values (p_barcode, p_basis, chosen.serving_text, chosen.product_name, chosen.brand, med, array_length(best, 1), false)
  on conflict (barcode, basis) do update
    set serving_text = excluded.serving_text, product_name = excluded.product_name, brand = excluded.brand,
        nutrients = excluded.nutrients, supporting_devices = excluded.supporting_devices, verified = false,
        verified_at = case when catalog.entries.verified
                                or catalog.entries.nutrients <> excluded.nutrients
                           then now() else catalog.entries.verified_at end;
end;
$$;

-- Preserve the existing signed-in, sharing, validation and daily-limit contract; consensus never returns verified.
create or replace function public.submit_label(
  p_barcode text, p_basis text, p_serving_text text, p_product_name text, p_brand text, p_nutrients jsonb
) returns text
language plpgsql security definer set search_path = '' as $$
declare
  device uuid := auth.uid();
  cfg catalog.settings%rowtype;
  used integer;
  sharing boolean;
  code text;
begin
  if device is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'sign in with an account first' using errcode = '28000';
  end if;
  select share_labels into sharing from public.profiles where id = device for share;
  if not found then
    raise exception 'account not found' using errcode = '28000';
  end if;
  if not sharing then
    raise exception 'sharing is turned off' using errcode = '42501';
  end if;
  if not catalog.valid_barcode(p_barcode) or (p_basis is null or p_basis not in ('per_100g', 'per_100ml', 'per_serving'))
     or p_product_name is null or char_length(btrim(p_product_name)) not between 1 and 120
     or (p_brand is not null and char_length(p_brand) > 80)
     or (p_serving_text is not null and char_length(p_serving_text) > 80)
     or (p_basis = 'per_serving' and char_length(btrim(coalesce(p_serving_text, ''))) = 0)
     or not catalog.valid_nutrients(p_nutrients) then
    raise exception 'invalid label' using errcode = '22023';
  end if;
  code := catalog.canonical_barcode(p_barcode);

  select * into cfg from catalog.settings;
  insert into catalog.usage as u (device_id, day, submissions) values (device, current_date, 1)
  on conflict (device_id, day) do update set submissions = u.submissions + 1
  returning u.submissions into used;
  if used > cfg.daily_limit then
    raise exception 'too many submissions today' using errcode = '53400';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(code || '|' || p_basis, 0));
  insert into catalog.submissions as s (device_id, barcode, basis, serving_text, product_name, brand, nutrients)
  values (device, code, p_basis, nullif(btrim(p_serving_text), ''), btrim(p_product_name),
          nullif(btrim(p_brand), ''), p_nutrients)
  on conflict (device_id, barcode, basis) do update
    set serving_text = excluded.serving_text, product_name = excluded.product_name, brand = excluded.brand,
        nutrients = excluded.nutrients, updated_at = now();

  perform catalog.refresh_entry(code, p_basis);
  return coalesce((select 'shared' from catalog.entries e where e.barcode = code and e.basis = p_basis), 'received');
end;
$$;

-- Old clients keep their original response shape and see only unverified community aggregates.
create or replace function public.lookup_label(p_barcode text)
returns table (basis text, serving_text text, product_name text, brand text, nutrients jsonb, supporting_devices integer, verified boolean)
language sql stable security definer set search_path = '' as $$
  select e.basis, e.serving_text, e.product_name, e.brand, e.nutrients, e.supporting_devices, false
  from catalog.entries e
  where auth.uid() is not null and not coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
    and exists (select 1 from public.profiles p where p.id = auth.uid())
    and e.barcode = catalog.canonical_barcode(p_barcode)
    and not e.verified
    and not exists (select 1 from catalog.approved_entries a where a.barcode = e.barcode and a.basis = e.basis)
    and not exists (select 1 from catalog.rejections r where r.barcode = e.barcode and r.basis = e.basis);
$$;

-- Source-aware lookup prefers an approved snapshot; neither moderation details nor source identities are exposed.
create function public.lookup_label_v2(p_barcode text)
returns table (
  basis text, serving_text text, product_name text, brand text, nutrients jsonb,
  supporting_devices integer, verified boolean, verification_source text
)
language sql stable security definer set search_path = '' as $$
  select a.basis, a.serving_text, a.product_name, a.brand, a.nutrients, 0, true, 'owner_reviewed'::text
  from catalog.approved_entries a
  where auth.uid() is not null and not coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
    and exists (select 1 from public.profiles p where p.id = auth.uid())
    and a.barcode = catalog.canonical_barcode(p_barcode)
    and not exists (select 1 from catalog.rejections r where r.barcode = a.barcode and r.basis = a.basis)
  union all
  select e.basis, e.serving_text, e.product_name, e.brand, e.nutrients, e.supporting_devices, false, 'community'::text
  from catalog.entries e
  where auth.uid() is not null and not coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
    and exists (select 1 from public.profiles p where p.id = auth.uid())
    and e.barcode = catalog.canonical_barcode(p_barcode)
    and not e.verified
    and not exists (select 1 from catalog.approved_entries a where a.barcode = e.barcode and a.basis = e.basis)
    and not exists (select 1 from catalog.rejections r where r.barcode = e.barcode and r.basis = e.basis);
$$;

create function catalog.owner_approve_label(
  p_barcode text, p_basis text, p_serving_text text, p_product_name text, p_brand text,
  p_nutrients jsonb, p_reason text
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  code text;
  payload_digest text;
begin
  if not catalog.valid_barcode(p_barcode) or (p_basis is null or p_basis not in ('per_100g', 'per_100ml', 'per_serving'))
     or p_product_name is null or char_length(btrim(p_product_name)) not between 1 and 120
     or (p_brand is not null and char_length(p_brand) > 80)
     or (p_serving_text is not null and char_length(p_serving_text) > 80)
     or (p_basis = 'per_serving' and char_length(btrim(coalesce(p_serving_text, ''))) = 0)
     or not catalog.valid_nutrients(p_nutrients)
     or not catalog.valid_moderation_reason(p_reason) then
    raise exception 'invalid approval payload or reason' using errcode = '22023';
  end if;
  code := catalog.canonical_barcode(p_barcode);
  perform pg_advisory_xact_lock(hashtextextended(code || '|' || p_basis, 0));
  insert into catalog.approved_entries (barcode, basis, serving_text, product_name, brand, nutrients, approved_at)
  values (code, p_basis, nullif(btrim(p_serving_text), ''), btrim(p_product_name), nullif(btrim(p_brand), ''), p_nutrients, now())
  on conflict (barcode, basis) do update
    set serving_text = excluded.serving_text, product_name = excluded.product_name, brand = excluded.brand,
        nutrients = excluded.nutrients, approved_at = excluded.approved_at;
  delete from catalog.rejections where barcode = code and basis = p_basis;
  payload_digest := md5(jsonb_build_object('barcode', code, 'basis', p_basis, 'serving_text', nullif(btrim(p_serving_text), ''),
    'product_name', btrim(p_product_name), 'brand', nullif(btrim(p_brand), ''), 'nutrients', p_nutrients)::text);
  insert into catalog.moderation_audit (barcode, basis, action, reason, payload_digest)
  values (code, p_basis, 'approve', btrim(p_reason), payload_digest);
end;
$$;

create function catalog.owner_reject_label(p_barcode text, p_basis text, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  code text;
  payload_digest text;
begin
  if not catalog.valid_barcode(p_barcode) or (p_basis is null or p_basis not in ('per_100g', 'per_100ml', 'per_serving'))
     or not catalog.valid_moderation_reason(p_reason) then
    raise exception 'invalid rejection key or reason' using errcode = '22023';
  end if;
  code := catalog.canonical_barcode(p_barcode);
  perform pg_advisory_xact_lock(hashtextextended(code || '|' || p_basis, 0));
  select md5(to_jsonb(a)::text) into payload_digest from catalog.approved_entries a
    where a.barcode = code and a.basis = p_basis;
  delete from catalog.approved_entries where barcode = code and basis = p_basis;
  insert into catalog.rejections (barcode, basis, reason) values (code, p_basis, btrim(p_reason))
  on conflict (barcode, basis) do update set reason = excluded.reason, created_at = now();
  delete from catalog.entries where barcode = code and basis = p_basis;
  insert into catalog.moderation_audit (barcode, basis, action, reason, payload_digest)
  values (code, p_basis, 'reject', btrim(p_reason), payload_digest);
end;
$$;

create function catalog.owner_clear_rejection(p_barcode text, p_basis text, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  code text;
begin
  if not catalog.valid_barcode(p_barcode) or (p_basis is null or p_basis not in ('per_100g', 'per_100ml', 'per_serving'))
     or not catalog.valid_moderation_reason(p_reason) then
    raise exception 'invalid rejection key or reason' using errcode = '22023';
  end if;
  code := catalog.canonical_barcode(p_barcode);
  perform pg_advisory_xact_lock(hashtextextended(code || '|' || p_basis, 0));
  delete from catalog.rejections where barcode = code and basis = p_basis;
  if not found then
    raise exception 'no active rejection for this label' using errcode = 'P0002';
  end if;
  perform catalog.refresh_entry(code, p_basis);
  insert into catalog.moderation_audit (barcode, basis, action, reason)
  values (code, p_basis, 'clear_rejection', btrim(p_reason));
end;
$$;

create function catalog.owner_revoke_label(p_barcode text, p_basis text, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  code text;
  payload_digest text;
begin
  if not catalog.valid_barcode(p_barcode) or (p_basis is null or p_basis not in ('per_100g', 'per_100ml', 'per_serving'))
     or not catalog.valid_moderation_reason(p_reason) then
    raise exception 'invalid revocation key or reason' using errcode = '22023';
  end if;
  code := catalog.canonical_barcode(p_barcode);
  perform pg_advisory_xact_lock(hashtextextended(code || '|' || p_basis, 0));
  select md5(to_jsonb(a)::text) into payload_digest from catalog.approved_entries a
    where a.barcode = code and a.basis = p_basis;
  delete from catalog.approved_entries where barcode = code and basis = p_basis;
  if not found then
    raise exception 'no active approval for this label' using errcode = 'P0002';
  end if;
  perform catalog.refresh_entry(code, p_basis);
  insert into catalog.moderation_audit (barcode, basis, action, reason, payload_digest)
  values (code, p_basis, 'revoke', btrim(p_reason), payload_digest);
end;
$$;

-- No moderation routine or private row is available to any API role.
revoke all on function catalog.refresh_entry(text, text) from public, anon, authenticated;
revoke all on function public.submit_label(text, text, text, text, text, jsonb) from public, anon;
revoke all on function public.lookup_label(text) from public, anon;
revoke all on function public.lookup_label_v2(text) from public, anon;
revoke all on function catalog.owner_approve_label(text, text, text, text, text, jsonb, text) from public, anon, authenticated;
revoke all on function catalog.owner_reject_label(text, text, text) from public, anon, authenticated;
revoke all on function catalog.owner_clear_rejection(text, text, text) from public, anon, authenticated;
revoke all on function catalog.owner_revoke_label(text, text, text) from public, anon, authenticated;
grant execute on function public.submit_label(text, text, text, text, text, jsonb) to authenticated;
grant execute on function public.lookup_label(text) to authenticated;
grant execute on function public.lookup_label_v2(text) to authenticated;

-- Existing automatic consensus badges are downgraded; nothing is promoted without an explicit owner review.
select catalog.revalidate_all();

commit;
