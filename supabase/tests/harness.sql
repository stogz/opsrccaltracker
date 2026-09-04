-- harness.sql — LOCAL TESTING ONLY. Never run this against the Supabase project.
--
-- Supabase gives every project an `auth` schema, an `extensions` schema, and the
-- anon / authenticated / service_role roles. A bare Postgres has none of them,
-- so this file stubs just enough of that surface for the migrations and
-- supabase/tests/rls.sql to run on a throwaway cluster.

create schema if not exists extensions;
create schema if not exists auth;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

create table if not exists auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text unique,
  raw_user_meta_data jsonb not null default '{}'::jsonb
);

-- Mirrors Supabase's implementation: the current user id comes from the JWT
-- claims that PostgREST sets on the connection.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid;
$$;

grant usage on schema auth, extensions to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
