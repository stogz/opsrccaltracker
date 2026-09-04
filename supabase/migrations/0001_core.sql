-- 0001_core.sql — tables, indexes, triggers, views
--
-- Sizing note: this schema is built for the Supabase free tier (nano). Measured
-- on a loaded copy: the catalog is 1.3 MB (329 foods + 389 portions, indexes
-- included) and public.entries costs 262 bytes per logged food, again including
-- indexes. That is ~0.9 MB per user-year at ten foods a day, so the 500 MB
-- free-tier ceiling is roughly 500 user-years away. It is not the constraint —
-- but every index below is still one the app actually issues a query for.

create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------
-- profiles: one row per auth user, holding their daily targets
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text check (char_length(display_name) <= 80),
  kcal_goal     integer      not null default 2000 check (kcal_goal between 0 and 20000),
  protein_goal_g numeric(6,1) not null default 150  check (protein_goal_g between 0 and 2000),
  fat_goal_g     numeric(6,1) not null default 65   check (fat_goal_g between 0 and 2000),
  carbs_goal_g   numeric(6,1) not null default 250  check (carbs_goal_g between 0 and 2000),
  created_at    timestamptz not null default now()
);

comment on table public.profiles is 'Per-user settings and daily macro targets. Created automatically on signup.';

-- Create the profile row when a user signs up, so the app never has to.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, nullif(new.raw_user_meta_data ->> 'display_name', ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- foods: the shared catalog and each user's own foods, in one table.
--   owner_id IS NULL  -> public catalog row, readable by everyone, writable
--                        only by the service role (i.e. by the seed script)
--   owner_id = a user -> that user's private food, readable/writable by them
-- Every nutrient value is PER 100 GRAMS, matching db/catalog/core.json.
-- ---------------------------------------------------------------------------
create table if not exists public.foods (
  id         bigint generated always as identity primary key,
  owner_id   uuid references auth.users (id) on delete cascade,
  fdc_id     integer unique,
  name       text not null check (char_length(trim(name)) between 1 and 200),
  category   text check (char_length(category) <= 80),
  brand      text check (char_length(brand) <= 80),

  kcal       numeric(6,2) not null check (kcal between 0 and 900),
  protein_g  numeric(6,2) check (protein_g between 0 and 100),
  fat_g      numeric(6,2) check (fat_g     between 0 and 100),
  carbs_g    numeric(6,2) check (carbs_g   between 0 and 100),
  fiber_g    numeric(6,2) check (fiber_g   between 0 and 100),
  sodium_mg  numeric(8,2) check (sodium_mg between 0 and 100000),

  created_at timestamptz not null default now(),

  -- USDA rows carry an fdc_id and no owner; user rows carry an owner and no fdc_id.
  constraint foods_owner_xor_fdc check (owner_id is null or fdc_id is null)
);

comment on column public.foods.fdc_id is 'USDA FoodData Central id — the join key back to the source release. NULL for user-created foods.';
comment on column public.foods.kcal is 'Energy per 100 g. 900 is pure fat; anything higher is a data error.';

-- Full-text search over name/category/brand. Immutable expression, so it can be
-- a stored generated column and indexed directly.
alter table public.foods
  drop column if exists search;
alter table public.foods
  add column search tsvector
  generated always as (
    to_tsvector('english',
      name || ' ' || coalesce(category, '') || ' ' || coalesce(brand, ''))
  ) stored;

create index if not exists foods_search_idx  on public.foods using gin (search);
create index if not exists foods_name_trgm_idx on public.foods using gin (name extensions.gin_trgm_ops);
create index if not exists foods_owner_idx   on public.foods (owner_id) where owner_id is not null;

-- ---------------------------------------------------------------------------
-- food_portions: household measures ("1 serving = 140 g") so users can log
-- without owning a kitchen scale.
-- ---------------------------------------------------------------------------
create table if not exists public.food_portions (
  id      bigint generated always as identity primary key,
  food_id bigint not null references public.foods (id) on delete cascade,
  amount  numeric(8,3) not null check (amount > 0),
  unit    text not null check (char_length(trim(unit)) between 1 and 40),
  grams   numeric(8,2) not null check (grams > 0 and grams <= 2000)
);

create index if not exists food_portions_food_idx on public.food_portions (food_id);

-- ---------------------------------------------------------------------------
-- entries: the diary. Each row stores the grams eaten AND a snapshot of the
-- nutrition at the time of logging, so correcting a catalog entry later never
-- silently rewrites someone's history. The snapshot is filled by a trigger —
-- clients only send food_id + grams.
-- ---------------------------------------------------------------------------
create table if not exists public.entries (
  id        bigint generated always as identity primary key,
  user_id   uuid not null default auth.uid() references auth.users (id) on delete cascade,
  food_id   bigint references public.foods (id) on delete set null,
  logged_on date not null default (now() at time zone 'utc')::date,
  meal      text not null default 'other'
              check (meal in ('breakfast', 'lunch', 'dinner', 'snack', 'other')),
  grams     numeric(8,2) not null check (grams > 0 and grams <= 10000),

  -- snapshot for the logged quantity (NOT per 100 g)
  food_name text         not null check (char_length(trim(food_name)) between 1 and 200),
  kcal      numeric(8,2) not null check (kcal >= 0),
  protein_g numeric(8,2) check (protein_g >= 0),
  fat_g     numeric(8,2) check (fat_g     >= 0),
  carbs_g   numeric(8,2) check (carbs_g   >= 0),

  created_at timestamptz not null default now()
);

comment on table public.entries is 'Food diary. Nutrition columns are the totals for `grams`, snapshotted at insert time.';

-- The one index the app leans on: "everything I ate on this day".
create index if not exists entries_user_day_idx on public.entries (user_id, logged_on desc, id);

-- Fill the snapshot from the catalog. SECURITY DEFINER so it can read foods
-- regardless of RLS, which means it must check ownership itself.
create or replace function public.entries_fill_nutrition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.foods;
  factor numeric;
begin
  if new.food_id is null then
    -- Ad-hoc entry ("a beer, ~150 kcal"): the client supplies its own numbers.
    if new.food_name is null or new.kcal is null then
      raise exception 'an entry with no food_id must supply food_name and kcal'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  select * into f from public.foods where id = new.food_id;
  if not found then
    raise exception 'food % does not exist', new.food_id using errcode = 'foreign_key_violation';
  end if;
  if f.owner_id is not null and f.owner_id is distinct from new.user_id then
    raise exception 'food % is not available to this user', new.food_id using errcode = 'insufficient_privilege';
  end if;

  factor := new.grams / 100.0;

  new.food_name := f.name;
  new.kcal      := round(f.kcal      * factor, 2);
  new.protein_g := round(f.protein_g * factor, 2);
  new.fat_g     := round(f.fat_g     * factor, 2);
  new.carbs_g   := round(f.carbs_g   * factor, 2);

  return new;
end;
$$;

drop trigger if exists entries_fill_nutrition_trg on public.entries;
create trigger entries_fill_nutrition_trg
  before insert or update of food_id, grams on public.entries
  for each row execute function public.entries_fill_nutrition();

-- ---------------------------------------------------------------------------
-- daily_totals: one row per user per day. security_invoker keeps the caller's
-- RLS on public.entries in force, so the view needs no policies of its own.
-- ---------------------------------------------------------------------------
create or replace view public.daily_totals
with (security_invoker = on) as
select
  user_id,
  logged_on,
  round(sum(kcal),      1) as kcal,
  round(sum(protein_g), 1) as protein_g,
  round(sum(fat_g),     1) as fat_g,
  round(sum(carbs_g),   1) as carbs_g,
  count(*)                 as entry_count
from public.entries
group by user_id, logged_on;
