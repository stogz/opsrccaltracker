-- 0002_rls.sql — row level security and role grants
--
-- Every table is deny-by-default. The rules in one sentence:
--   * anybody, signed in or not, can read the public food catalog
--   * a signed-in user can read/write their own foods, portions, entries, profile
--   * nobody but the service role can touch a catalog row
-- Read paths are exercised by supabase/tests/rls.sql.

alter table public.profiles      enable row level security;
alter table public.foods         enable row level security;
alter table public.food_portions enable row level security;
alter table public.entries       enable row level security;

-- ---------------------------------------------------------------------------
-- profiles — strictly your own row
-- ---------------------------------------------------------------------------
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select to authenticated
  using (id = (select auth.uid()));

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
  for insert to authenticated
  with check (id = (select auth.uid()));

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- foods — public catalog is world-readable; custom foods are private
-- ---------------------------------------------------------------------------
drop policy if exists foods_select_catalog on public.foods;
create policy foods_select_catalog on public.foods
  for select to anon
  using (owner_id is null);

drop policy if exists foods_select_visible on public.foods;
create policy foods_select_visible on public.foods
  for select to authenticated
  using (owner_id is null or owner_id = (select auth.uid()));

-- A user may only create foods they own. `owner_id` defaults to auth.uid() but
-- the WITH CHECK is what actually stops them claiming a catalog slot.
drop policy if exists foods_insert_own on public.foods;
create policy foods_insert_own on public.foods
  for insert to authenticated
  with check (owner_id = (select auth.uid()) and fdc_id is null);

drop policy if exists foods_update_own on public.foods;
create policy foods_update_own on public.foods
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()) and fdc_id is null);

drop policy if exists foods_delete_own on public.foods;
create policy foods_delete_own on public.foods
  for delete to authenticated
  using (owner_id = (select auth.uid()));

alter table public.foods alter column owner_id set default auth.uid();

-- ---------------------------------------------------------------------------
-- food_portions — visibility follows the parent food
-- ---------------------------------------------------------------------------
drop policy if exists food_portions_select_catalog on public.food_portions;
create policy food_portions_select_catalog on public.food_portions
  for select to anon
  using (exists (select 1 from public.foods f
                  where f.id = food_id and f.owner_id is null));

drop policy if exists food_portions_select_visible on public.food_portions;
create policy food_portions_select_visible on public.food_portions
  for select to authenticated
  using (exists (select 1 from public.foods f
                  where f.id = food_id
                    and (f.owner_id is null or f.owner_id = (select auth.uid()))));

drop policy if exists food_portions_write_own on public.food_portions;
create policy food_portions_write_own on public.food_portions
  for all to authenticated
  using (exists (select 1 from public.foods f
                  where f.id = food_id and f.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.foods f
                  where f.id = food_id and f.owner_id = (select auth.uid())));

-- ---------------------------------------------------------------------------
-- entries — your diary and nobody else's
-- ---------------------------------------------------------------------------
drop policy if exists entries_select_own on public.entries;
create policy entries_select_own on public.entries
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists entries_insert_own on public.entries;
create policy entries_insert_own on public.entries
  for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists entries_update_own on public.entries;
create policy entries_update_own on public.entries
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists entries_delete_own on public.entries;
create policy entries_delete_own on public.entries
  for delete to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Grants. RLS decides rows; grants decide whether PostgREST exposes the table
-- at all. Note there is no grant of any kind on catalog writes — seeding runs
-- as the service role, which bypasses both.
-- ---------------------------------------------------------------------------
grant usage on schema public to anon, authenticated;

grant select                         on public.foods         to anon, authenticated;
grant insert, update, delete         on public.foods         to authenticated;
grant select                         on public.food_portions to anon, authenticated;
grant insert, update, delete         on public.food_portions to authenticated;
grant select, insert, update, delete on public.entries       to authenticated;
grant select, insert, update         on public.profiles      to authenticated;
grant select                         on public.daily_totals  to authenticated;

-- identity columns need the sequence
grant usage, select on all sequences in schema public to authenticated;
