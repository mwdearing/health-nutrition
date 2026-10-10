-- Hardening after review: agreement across the whole supporting group, bounded recompute cost, barcode and
-- serving checks at the RPC boundary, and a refresh when the tunables change.

-- A barcode the app itself can look up: EAN-8, UPC-A (12) or EAN-13, with a correct check digit.
create function catalog.valid_barcode(p_barcode text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare
  n integer := coalesce(char_length(p_barcode), 0);
  total integer := 0;
  digit integer;
  weight integer;
begin
  if p_barcode is null or p_barcode !~ '^[0-9]+$' or n not in (8, 12, 13) then
    return false;
  end if;
  -- Weights alternate 3, 1 from the digit next to the check digit.
  for i in 1 .. n - 1 loop
    digit := substr(p_barcode, n - i, 1)::integer;
    weight := case when i % 2 = 1 then 3 else 1 end;
    total := total + digit * weight;
  end loop;
  return (10 - total % 10) % 10 = substr(p_barcode, n, 1)::integer;
end;
$$;

-- The median of each nutrient across a group of submissions; a nutrient is kept only when most of the group
-- states it.
create function catalog.median_nutrients(p_ids bigint[]) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  k text;
  vals numeric[];
  med jsonb := '{}'::jsonb;
  total integer := coalesce(array_length(p_ids, 1), 0);
begin
  for k in select distinct jsonb_object_keys(nutrients) from catalog.submissions where id = any (p_ids) loop
    select array_agg((nutrients ->> k)::numeric order by (nutrients ->> k)::numeric) into vals
    from catalog.submissions where id = any (p_ids) and nutrients ? k;
    if array_length(vals, 1) * 2 > total then
      med := med || jsonb_build_object(
        k, (vals[(array_length(vals, 1) + 1) / 2] + vals[(array_length(vals, 1) + 2) / 2]) / 2);
    end if;
  end loop;
  return med;
end;
$$;

-- Recomputes one label's entry. At most the 100 newest submissions are considered, so the work for one write
-- is bounded no matter how popular a barcode becomes. A group is seeded by one submission, then narrowed to the
-- members that agree with the group's own median, so every counted supporter is within tolerance of the value
-- the entry shows.
create or replace function catalog.refresh_entry(p_barcode text, p_basis text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  cfg catalog.settings%rowtype;
  cand bigint[];
  best bigint[] := '{}';
  grp bigint[];
  fin bigint[];
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
    order by id desc limit 100) c;

  for s in select id, nutrients from catalog.submissions where id = any (coalesce(cand, '{}')) order by id loop
    grp := '{}';
    for t in select id, nutrients from catalog.submissions where id = any (cand) loop
      if catalog.agrees(s.nutrients, t.nutrients, cfg.tolerance_percent) then
        grp := grp || t.id;
      end if;
    end loop;
    med := catalog.median_nutrients(grp);
    fin := '{}';
    for t in select id, nutrients from catalog.submissions where id = any (grp) loop
      if catalog.agrees(med, t.nutrients, cfg.tolerance_percent) then
        fin := fin || t.id;
      end if;
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

-- Same account, sharing and race rules as before, plus the barcode and serving checks.
create or replace function public.submit_label(
  p_barcode text, p_basis text, p_serving_text text, p_product_name text, p_brand text, p_nutrients jsonb
) returns text
language plpgsql security definer set search_path = '' as $$
declare
  device uuid := auth.uid();
  cfg catalog.settings%rowtype;
  used integer;
  sharing boolean;
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

  select * into cfg from catalog.settings;
  insert into catalog.usage as u (device_id, day, submissions) values (device, current_date, 1)
  on conflict (device_id, day) do update set submissions = u.submissions + 1
  returning u.submissions into used;
  if used > cfg.daily_limit then
    raise exception 'too many submissions today' using errcode = '53400';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_barcode || '|' || p_basis, 0));
  insert into catalog.submissions as s (device_id, barcode, basis, serving_text, product_name, brand, nutrients)
  values (device, p_barcode, p_basis, nullif(btrim(p_serving_text), ''), btrim(p_product_name),
          nullif(btrim(p_brand), ''), p_nutrients)
  on conflict (device_id, barcode, basis) do update
    set serving_text = excluded.serving_text, product_name = excluded.product_name, brand = excluded.brand,
        nutrients = excluded.nutrients, updated_at = now();

  perform catalog.refresh_entry(p_barcode, p_basis);

  return coalesce(
    (select case when e.verified then 'verified' else 'shared' end
     from catalog.entries e where e.barcode = p_barcode and e.basis = p_basis),
    'received');
end;
$$;

-- Changing a tunable re-checks every label, so no entry keeps the old policy.
create function catalog.refresh_all() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  l record;
begin
  for l in select distinct barcode, basis from catalog.submissions order by barcode, basis loop
    perform catalog.refresh_entry(l.barcode, l.basis);
  end loop;
  return new;
end;
$$;
create trigger settings_refresh_entries after update on catalog.settings
  for each row execute function catalog.refresh_all();

revoke all on function catalog.valid_barcode(text) from public, anon, authenticated;
revoke all on function catalog.median_nutrients(bigint[]) from public, anon, authenticated;
revoke all on function catalog.refresh_all() from public, anon, authenticated;
revoke all on function public.submit_label(text, text, text, text, text, jsonb) from public, anon;
grant execute on function public.submit_label(text, text, text, text, text, jsonb) to authenticated;
