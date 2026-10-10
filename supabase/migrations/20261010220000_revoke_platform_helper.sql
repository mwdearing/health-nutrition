-- Supabase's own helper that turns on row-level security for new tables is an event-trigger function. It never
-- needs to be callable through the API, so only the owner keeps it. A plain Postgres (the test database) has no
-- such helper, so the revoke is conditional.
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke all on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end $$;
