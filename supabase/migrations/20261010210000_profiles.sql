-- Accounts: one profile per signed-in user, holding the settings that follow them from device to device.
-- Journal data is not stored here. It stays on the device and, for signed-in users, in their own iCloud.

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text check (display_name is null or char_length(display_name) <= 60),
  -- Opt-out: labels are shared with the community unless the person turns this off in Settings.
  share_labels boolean not null default true,
  settings jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object' and pg_column_size(settings) <= 16384),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy profiles_select_own on public.profiles for select to authenticated
  using (id = (select auth.uid()) and not coalesce((select auth.jwt() ->> 'is_anonymous')::boolean, false));
create policy profiles_insert_own on public.profiles for insert to authenticated
  with check (id = (select auth.uid()) and not coalesce((select auth.jwt() ->> 'is_anonymous')::boolean, false));
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid()) and not coalesce((select auth.jwt() ->> 'is_anonymous')::boolean, false))
  with check (id = (select auth.uid()) and not coalesce((select auth.jwt() ->> 'is_anonymous')::boolean, false));

revoke all on public.profiles from public, anon;
grant select, insert, update on public.profiles to authenticated;

create function public.touch_profile() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_profile();

-- A profile is created on first sign-in.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- Anonymous users (off for this project) never get a profile.
  if not coalesce(new.is_anonymous, false) then
    insert into public.profiles (id) values (new.id) on conflict do nothing;
  end if;
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Sharing is checked on the server too: someone who turned it off cannot submit, whatever the app sends.
create or replace function public.submit_label(
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
  -- A deleted account's token stays valid until it expires, so the profile has to exist as well.
  if not exists (select 1 from public.profiles where id = device) then
    raise exception 'account not found' using errcode = '28000';
  end if;
  if exists (select 1 from public.profiles where id = device and not share_labels) then
    raise exception 'sharing is turned off' using errcode = '42501';
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

-- Deletes the account: its submissions (re-checking the labels they supported), its profile and the sign-in
-- itself. The app offers this in Settings; App Review requires it wherever an account can be created.
create function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
declare
  device uuid := auth.uid();
begin
  if device is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'sign in with an account first' using errcode = '28000';
  end if;
  perform public.withdraw_my_submissions();
  delete from catalog.usage where device_id = device;
  delete from public.profiles where id = device;
  delete from auth.users where id = device;
end;
$$;

revoke all on function public.submit_label(text, text, text, text, text, jsonb) from public, anon;
revoke all on function public.delete_my_account() from public, anon;
revoke all on function public.handle_new_user() from public, anon, authenticated;
grant execute on function public.submit_label(text, text, text, text, text, jsonb) to authenticated;
grant execute on function public.delete_my_account() to authenticated;
