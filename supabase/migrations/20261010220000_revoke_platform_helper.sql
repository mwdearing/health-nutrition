-- Supabase's own helper that turns on row-level security for new tables is an event-trigger function. It never
-- needs to be callable through the API, so only the owner keeps it.
revoke all on function public.rls_auto_enable() from public, anon, authenticated;
