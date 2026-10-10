-- Second round of review fixes: supporters re-checked against the final median, serving definitions kept apart,
-- equivalent barcodes joined, replacements ranked as newest, profiles backfilled, and lookups tied to a live account.

-- One product, one code: a 12-digit UPC-A and its leading-zero EAN-13 are the same barcode.
create function catalog.canonical_barcode(p_barcode text) returns text
language sql immutable set search_path = '' as $$
  select case when char_length(p_barcode) = 12 then '0' || p_barcode else p_barcode end;
$$;

-- Profiles for accounts that existed before the trigger did.
insert into public.profiles (id)
select u.id from auth.users u where not coalesce(u.is_anonymous, false)
on conflict do nothing;

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

  -- The 100 most recently written submissions (a replacement counts as new), which bounds the work per write.
  select array_agg(id) into cand from (
    select id from catalog.submissions where barcode = p_barcode and basis = p_basis
    order by updated_at desc, id desc limit 100) c;

  for s in select id, nutrients, coalesce(lower(btrim(serving_text)), '') as serving
           from catalog.submissions where id = any (coalesce(cand, '{}')) order by id loop
    grp := '{}';
    for t in select id, nutrients, coalesce(lower(btrim(serving_text)), '') as serving
             from catalog.submissions where id = any (cand) loop
      -- A per-serving value only counts with others that define the serving the same way.
      if (p_basis <> 'per_serving' or s.serving = t.serving)
         and catalog.agrees(s.nutrients, t.nutrients, cfg.tolerance_percent) then
        grp := grp || t.id;
      end if;
    end loop;
    -- Narrow to members within tolerance of the group's own median, and repeat until the median of the
    -- members that remain still has every one of them within tolerance.
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
  values (p_barcode, p_basis, chosen.serving_text, chosen.product_name, chosen.brand, med, array_length(best, 1),
          array_length(best, 1) >= cfg.min_devices)
  on conflict (barcode, basis) do update
    set serving_text = excluded.serving_text, product_name = excluded.product_name, brand = excluded.brand,
        nutrients = excluded.nutrients, supporting_devices = excluded.supporting_devices,
        verified = excluded.verified,
        verified_at = case when catalog.entries.verified = excluded.verified
                                and catalog.entries.nutrients = excluded.nutrients
                           then catalog.entries.verified_at else now() end;
end;
$$;

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
  if not catalog.valid_barcode(p_barcode) or p_basis not in ('per_100g', 'per_100ml', 'per_serving')
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

  return coalesce(
    (select case when e.verified then 'verified' else 'shared' end
     from catalog.entries e where e.barcode = code and e.basis = p_basis),
    'received');
end;
$$;

-- A stale token from a deleted account reads nothing.
create or replace function public.lookup_label(p_barcode text)
returns table (basis text, serving_text text, product_name text, brand text, nutrients jsonb, supporting_devices integer, verified boolean)
language sql stable security definer set search_path = '' as $$
  select e.basis, e.serving_text, e.product_name, e.brand, e.nutrients, e.supporting_devices, e.verified
  from catalog.entries e
  where auth.uid() is not null and not coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
    and exists (select 1 from public.profiles p where p.id = auth.uid())
    and e.barcode = catalog.canonical_barcode(p_barcode)
    and not exists (select 1 from catalog.rejections r where r.barcode = e.barcode and r.basis = e.basis);
$$;

revoke all on function catalog.canonical_barcode(text) from public, anon, authenticated;
revoke all on function public.submit_label(text, text, text, text, text, jsonb) from public, anon;
revoke all on function public.lookup_label(text) from public, anon;
grant execute on function public.submit_label(text, text, text, text, text, jsonb) to authenticated;
grant execute on function public.lookup_label(text) to authenticated;
