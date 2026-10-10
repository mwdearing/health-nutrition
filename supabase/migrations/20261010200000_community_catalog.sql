-- Community label catalog.
--
-- People opt out in Settings; otherwise the app sends the nutrient values of a scanned label (values only,
-- never a photo, a logged amount, a time or anything from the journal). A label becomes verified when enough
-- distinct devices submit values that agree. Only verified labels are readable by other people.
--
-- Everything lives in the private `catalog` schema, which the API does not expose. The app reaches it only
-- through three functions in `public`, and only as a signed-in account (anonymous sign-ins are refused).

create schema if not exists catalog;
revoke all on schema catalog from public, anon, authenticated;

-- Tunables: one row.
create table catalog.settings (
  singleton boolean primary key default true check (singleton),
  min_devices integer not null default 5 check (min_devices >= 2),
  -- Agreeing devices needed before a label is shown to other people at all (unverified, no badge).
  min_shown integer not null default 2 check (min_shown >= 2),
  tolerance_percent numeric not null default 2 check (tolerance_percent >= 0),
  daily_limit integer not null default 60 check (daily_limit > 0)
);
insert into catalog.settings default values;

create table catalog.submissions (
  id bigint generated always as identity primary key,
  device_id uuid not null,
  barcode text not null check (barcode ~ '^[0-9]{8,14}$'),
  basis text not null check (basis in ('per_100g', 'per_100ml', 'per_serving')),
  serving_text text check (serving_text is null or char_length(serving_text) <= 80),
  product_name text not null check (char_length(btrim(product_name)) between 1 and 120),
  brand text check (brand is null or char_length(brand) <= 80),
  nutrients jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (device_id, barcode, basis)
);
create index submissions_label_idx on catalog.submissions (barcode, basis);

-- Moderation: a rejected label is never verified. Written by the project owner only.
create table catalog.rejections (
  barcode text not null,
  basis text not null,
  reason text,
  created_at timestamptz not null default now(),
  primary key (barcode, basis)
);

-- The verified catalog.
create table catalog.entries (
  barcode text not null,
  basis text not null,
  serving_text text,
  product_name text not null,
  brand text,
  nutrients jsonb not null,
  supporting_devices integer not null,
  verified boolean not null,
  verified_at timestamptz not null default now(),
  primary key (barcode, basis)
);

create table catalog.usage (
  device_id uuid not null,
  day date not null,
  submissions integer not null default 0,
  primary key (device_id, day)
);

-- Rejecting a label takes it out of the catalog immediately.
create function catalog.drop_rejected_entry() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from catalog.entries where barcode = new.barcode and basis = new.basis;
  return new;
end;
$$;
create trigger rejections_drop_entry after insert on catalog.rejections
  for each row execute function catalog.drop_rejected_entry();

alter table catalog.settings enable row level security;
alter table catalog.submissions enable row level security;
alter table catalog.rejections enable row level security;
alter table catalog.entries enable row level security;
alter table catalog.usage enable row level security;
-- No policies on purpose: nothing reads or writes these tables except the functions below.

-- The nutrient keys the app sends, with the unit each is fixed to (the app converts before sending).
create function catalog.nutrient_max(p_key text) returns numeric
language sql immutable set search_path = '' as $$
  select case p_key
    when 'energyKcal' then 9000
    when 'sodium' then 100000      -- milligrams
    when 'protein' then 1000       -- grams
    when 'carbohydrates' then 1000
    when 'sugars' then 1000
    when 'fat' then 1000
    when 'saturatedFat' then 1000
    when 'fiber' then 1000
    when 'salt' then 1000
    else null
  end;
$$;

create function catalog.nutrient_floor(p_key text) returns numeric
language sql immutable set search_path = '' as $$
  select case p_key when 'energyKcal' then 5 when 'sodium' then 10 else 0.5 end;
$$;

-- True when the object holds only known keys with plain numbers inside their bounds, and at least three of them.
create function catalog.valid_nutrients(p_nutrients jsonb) returns boolean
language plpgsql immutable set search_path = '' as $$
declare
  k text;
  v jsonb;
  n integer := 0;
begin
  if p_nutrients is null or jsonb_typeof(p_nutrients) <> 'object' then
    return false;
  end if;
  for k, v in select * from jsonb_each(p_nutrients) loop
    if catalog.nutrient_max(k) is null or jsonb_typeof(v) <> 'number' then
      return false;
    end if;
    if (v #>> '{}')::numeric < 0 or (v #>> '{}')::numeric > catalog.nutrient_max(k) then
      return false;
    end if;
    n := n + 1;
  end loop;
  return n >= 3;
end;
$$;

-- Two submissions agree when they share at least three nutrients and every shared one is within tolerance.
create function catalog.agrees(a jsonb, b jsonb, p_percent numeric) returns boolean
language plpgsql immutable set search_path = '' as $$
declare
  k text;
  x numeric;
  y numeric;
  shared integer := 0;
begin
  for k in select jsonb_object_keys(a) loop
    if b ? k then
      x := (a ->> k)::numeric;
      y := (b ->> k)::numeric;
      shared := shared + 1;
      if abs(x - y) > greatest(p_percent / 100 * greatest(x, y), catalog.nutrient_floor(k)) then
        return false;
      end if;
    end if;
  end loop;
  return shared >= 3;
end;
$$;

-- Recomputes one label's catalog entry from the live submissions. The largest agreeing group wins (the
-- earliest submission breaks a tie). It is shown once `min_shown` distinct devices agree and carries the
-- verified badge once `min_devices` do; a rejected label has no entry. The entry carries the median of each
-- nutrient across the group.
create function catalog.refresh_entry(p_barcode text, p_basis text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  cfg catalog.settings%rowtype;
  best bigint[] := '{}';
  grp bigint[];
  s record;
  t record;
  k text;
  med jsonb := '{}'::jsonb;
  vals numeric[];
  chosen record;
begin
  -- One recompute per label at a time, so two simultaneous submissions cannot each miss the other's row.
  perform pg_advisory_xact_lock(hashtextextended(p_barcode || '|' || p_basis, 0));
  select * into cfg from catalog.settings;

  if exists (select 1 from catalog.rejections where barcode = p_barcode and basis = p_basis) then
    delete from catalog.entries where barcode = p_barcode and basis = p_basis;
    return;
  end if;

  for s in select id, nutrients from catalog.submissions
           where barcode = p_barcode and basis = p_basis order by created_at, id loop
    grp := '{}';
    for t in select id, nutrients from catalog.submissions
             where barcode = p_barcode and basis = p_basis loop
      if catalog.agrees(s.nutrients, t.nutrients, cfg.tolerance_percent) then
        grp := grp || t.id;
      end if;
    end loop;
    if coalesce(array_length(grp, 1), 0) > coalesce(array_length(best, 1), 0) then
      best := grp;
    end if;
  end loop;

  if coalesce(array_length(best, 1), 0) < cfg.min_shown then
    delete from catalog.entries where barcode = p_barcode and basis = p_basis;
    return;
  end if;

  for k in select distinct jsonb_object_keys(nutrients)
           from catalog.submissions where id = any (best) loop
    select array_agg((nutrients ->> k)::numeric order by (nutrients ->> k)::numeric) into vals
    from catalog.submissions where id = any (best) and nutrients ? k;
    -- Keep a nutrient only when most of the group states it.
    if array_length(vals, 1) * 2 > array_length(best, 1) then
      med := med || jsonb_build_object(
        k, (vals[(array_length(vals, 1) + 1) / 2] + vals[(array_length(vals, 1) + 2) / 2]) / 2);
    end if;
  end loop;

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

-- Sends one label's values. Returns 'verified' when the label carries the badge afterwards, 'shared' when
-- it is shown without one, and 'received' otherwise. A second submission by the same device for the same label replaces the first.
create function public.submit_label(
  p_barcode text, p_basis text, p_serving_text text, p_product_name text, p_brand text, p_nutrients jsonb
) returns text
language plpgsql security definer set search_path = '' as $$
declare
  device uuid := auth.uid();
  cfg catalog.settings%rowtype;
  used integer;
begin
  if device is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'sign in with an account first' using errcode = '28000';
  end if;
  if p_barcode is null or p_barcode !~ '^[0-9]{8,14}$' or p_basis not in ('per_100g', 'per_100ml', 'per_serving')
     or p_product_name is null or char_length(btrim(p_product_name)) not between 1 and 120
     or (p_brand is not null and char_length(p_brand) > 80)
     or (p_serving_text is not null and char_length(p_serving_text) > 80)
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

  -- Take the label's lock before writing, so the recompute below sees every row committed before it.
  perform pg_advisory_xact_lock(hashtextextended(p_barcode || '|' || p_basis, 0));
  insert into catalog.submissions as s (device_id, barcode, basis, serving_text, product_name, brand, nutrients)
  values (device, p_barcode, p_basis, p_serving_text, btrim(p_product_name), nullif(btrim(p_brand), ''), p_nutrients)
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

-- Labels the community agrees on for a barcode, with the verified flag. A single unconfirmed submission is
-- never returned, and neither is who sent anything.
create function public.lookup_label(p_barcode text)
returns table (basis text, serving_text text, product_name text, brand text, nutrients jsonb, supporting_devices integer, verified boolean)
language sql stable security definer set search_path = '' as $$
  select e.basis, e.serving_text, e.product_name, e.brand, e.nutrients, e.supporting_devices, e.verified
  from catalog.entries e
  where auth.uid() is not null and not coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
    and e.barcode = p_barcode
    and not exists (select 1 from catalog.rejections r where r.barcode = e.barcode and r.basis = e.basis);
$$;

-- Deletes everything this device ever sent and re-checks the labels it touched.
create function public.withdraw_my_submissions() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  device uuid := auth.uid();
  labels text[][];
  touched text[];
  removed integer := 0;
begin
  if device is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'sign in with an account first' using errcode = '28000';
  end if;
  with gone as (
    delete from catalog.submissions where device_id = device returning barcode, basis
  )
  select array_agg(array[barcode, basis]) into labels from (select distinct barcode, basis from gone) d;
  if labels is not null then
    foreach touched slice 1 in array labels loop
      perform catalog.refresh_entry(touched[1], touched[2]);
      removed := removed + 1;
    end loop;
  end if;
  -- The daily usage count is kept on purpose: withdrawing must not reset the submission limit.
  return removed;
end;
$$;

revoke all on all functions in schema catalog from public, anon, authenticated;
revoke all on function public.submit_label(text, text, text, text, text, jsonb) from public, anon;
revoke all on function public.lookup_label(text) from public, anon;
revoke all on function public.withdraw_my_submissions() from public, anon;
grant execute on function public.submit_label(text, text, text, text, text, jsonb) to authenticated;
grant execute on function public.lookup_label(text) to authenticated;
grant execute on function public.withdraw_my_submissions() to authenticated;
