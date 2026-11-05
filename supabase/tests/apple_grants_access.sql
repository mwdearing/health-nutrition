-- The Apple refresh token table is reachable only by the service role (the apple-grant Edge Function).
\set ON_ERROR_STOP on
do $$
declare r text; p text;
begin
  foreach r in array array['anon', 'authenticated'] loop
    foreach p in array array['select', 'insert', 'update', 'delete'] loop
      if has_table_privilege(r, 'public.apple_grants', p) then
        raise exception 'FAILED: % can % public.apple_grants', r, p;
      end if;
    end loop;
  end loop;
  foreach p in array array['select', 'insert', 'update', 'delete'] loop
    if not has_table_privilege('service_role', 'public.apple_grants', p) then
      raise exception 'FAILED: service_role cannot % public.apple_grants', p;
    end if;
  end loop;
  if not (select relrowsecurity from pg_class where oid = 'public.apple_grants'::regclass) then
    raise exception 'FAILED: row level security is off on public.apple_grants';
  end if;
end $$;
