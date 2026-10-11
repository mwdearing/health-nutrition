-- Review fixes: nutrient payloads are bounded in size and scale, and the profiles table and its trigger helper
-- keep only the privileges the app needs (the platform grants everything on new public objects by default).

-- A payload is at most 4 KB, and no value carries more than three decimals, so a value cannot hold thousands of
-- digits that every later agreement check would have to read.
create or replace function catalog.valid_nutrients(p_nutrients jsonb) returns boolean
language plpgsql immutable set search_path = '' as $$
declare
  k text;
  v jsonb;
  n integer := 0;
  amount numeric;
begin
  if p_nutrients is null or jsonb_typeof(p_nutrients) <> 'object' or pg_column_size(p_nutrients) > 4096 then
    return false;
  end if;
  for k, v in select * from jsonb_each(p_nutrients) loop
    if catalog.nutrient_max(k) is null or jsonb_typeof(v) <> 'number' then
      return false;
    end if;
    amount := (v #>> '{}')::numeric;
    if amount < 0 or amount > catalog.nutrient_max(k) or scale(amount) > 3 then
      return false;
    end if;
    n := n + 1;
  end loop;
  return n >= 3;
end;
$$;

revoke all on public.profiles from public, anon, authenticated;
grant select, insert, update on public.profiles to authenticated;
revoke all on function public.touch_profile() from public, anon, authenticated;

-- Rows stored before this validator existed are checked again: a submission that would not be accepted now is
-- removed, and every entry is rebuilt from what is left. The function is kept so the same step can be run again.
create function catalog.revalidate_all() returns void
language plpgsql security definer set search_path = '' as $$
declare
  l record;
begin
  delete from catalog.submissions where not catalog.valid_nutrients(nutrients);
  delete from catalog.entries;
  for l in select distinct barcode, basis from catalog.submissions order by barcode, basis loop
    perform catalog.refresh_entry(l.barcode, l.basis);
  end loop;
end;
$$;
revoke all on function catalog.revalidate_all() from public, anon, authenticated;
select catalog.revalidate_all();
