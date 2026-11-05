-- Server-side holder of the Sign in with Apple refresh token, so account deletion can revoke the grant
-- (App Store guideline 5.1.1(v)). Only the apple-grant Edge Function (service role) touches this table.
create table public.apple_grants (
  user_id uuid primary key references auth.users(id) on delete cascade,
  refresh_token text not null,
  created_at timestamptz not null default now()
);
alter table public.apple_grants enable row level security;
revoke all on public.apple_grants from anon, authenticated;
grant select, insert, update, delete on public.apple_grants to service_role;
