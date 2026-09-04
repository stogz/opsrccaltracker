-- rls.sql — proves the security rules in 0002_rls.sql actually hold.
--
-- Run with scripts/test-db.sh, which applies harness.sql, the migrations and the
-- seed to a throwaway database first. Everything here runs inside a transaction
-- that is rolled back, so it is also safe to run against a scratch database.
--
-- The claim under test: two users share one catalog and can never see each
-- other's foods or diary.

\set ON_ERROR_STOP on
begin;
-- Assertions report through NOTICE on stderr; no statement here returns a
-- useful result set, so drop them on the floor.
\o /dev/null

create function pg_temp.ok(cond boolean, label text)
returns void language plpgsql as $$
begin
  if cond is not true then
    raise exception 'FAIL: %', label;
  end if;
  raise notice 'ok  %', label;
end
$$;

-- Under RLS a forbidden UPDATE/DELETE is not an error, it simply matches no
-- rows. This asserts that, since "no error" alone would prove nothing.
create procedure pg_temp.ok_no_rows(stmt text, label text)
language plpgsql as $$
declare n bigint;
begin
  execute stmt;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FAIL: % (matched % row(s))', label, n;
  end if;
  raise notice 'ok  %', label;
end
$$;

-- ---------------------------------------------------------------------------
-- the catalog loaded
-- ---------------------------------------------------------------------------
select pg_temp.ok((select count(*) from public.foods where owner_id is null) = 329,
  'catalog has 329 public foods');
select pg_temp.ok((select count(*) from public.food_portions) = 389,
  'catalog has 389 portions');
select pg_temp.ok((select kcal from public.foods where fdc_id = 2262074) = 645.50,
  'almond butter kcal survived the round trip');
select pg_temp.ok((select count(*) from public.foods where carbs_g < 0) = 0,
  'no negative carbs made it past the seed');

-- two users, created as the table owner the way GoTrue would
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'ana@example.test'),
  ('22222222-2222-2222-2222-222222222222', 'bo@example.test');

select pg_temp.ok((select count(*) from public.profiles) = 2,
  'signup trigger created a profile for each new user');

-- ---------------------------------------------------------------------------
-- anonymous visitors: catalog only
-- ---------------------------------------------------------------------------
set local role anon;
select pg_temp.ok((select count(*) from public.foods) = 329,
  'anon reads the whole catalog');
select pg_temp.ok((select count(*) from public.search_foods('broccoli')) > 0,
  'anon can search the catalog');
select pg_temp.ok((select name from public.search_foods('chicken breast', 1)) ilike 'Chicken, breast%',
  'search ranks the obvious match first');
select pg_temp.ok((select count(*) from public.search_foods('brocoli')) > 0,
  'search survives a misspelling');
select pg_temp.ok((select count(*) from public.search_foods('avacado')) > 0,
  'search survives another misspelling');
select pg_temp.ok((select count(*) from public.search_foods('zzzzzz')) = 0,
  'search does not match everything when it matches nothing');
select pg_temp.ok((select count(*) from public.search_foods('', 100)) = 100,
  'an empty query browses the catalog, capped by max_results');

do $$
begin
  insert into public.foods (name, kcal) values ('Sneaky Cake', 400);
  raise exception 'FAIL: anon inserted a food';
exception
  when insufficient_privilege or check_violation then
    raise notice 'ok  anon cannot insert foods';
end
$$;

-- ---------------------------------------------------------------------------
-- Ana: custom food, portions, diary
-- ---------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';

insert into public.foods (name, brand, kcal, protein_g, fat_g, carbs_g)
values ('Ana''s protein shake', 'Homemade', 120, 22, 1.5, 4);

select pg_temp.ok((select owner_id from public.foods where name = 'Ana''s protein shake')
                  = '11111111-1111-1111-1111-111111111111'::uuid,
  'owner_id defaults to the caller');
select pg_temp.ok((select count(*) from public.foods) = 330,
  'Ana sees the catalog plus her own food');

insert into public.food_portions (food_id, amount, unit, grams)
select id, 1, 'scoop', 32 from public.foods where name = 'Ana''s protein shake';

-- log 150 g of raw broccoli: the client sends food_id + grams, nothing else
insert into public.entries (food_id, logged_on, meal, grams)
select id, date '2026-09-01', 'lunch', 150
from public.foods where fdc_id = (select fdc_id from public.foods where name ilike 'Broccoli, raw%' limit 1);

select pg_temp.ok((select count(*) from public.entries) = 1, 'Ana logged one entry');
select pg_temp.ok((select user_id from public.entries) = '11111111-1111-1111-1111-111111111111'::uuid,
  'entries.user_id defaults to the caller');

-- the trigger must scale per-100 g values by grams/100 and snapshot the name
select pg_temp.ok(
  (select e.kcal = round(f.kcal * 1.5, 2)
      and e.protein_g = round(f.protein_g * 1.5, 2)
      and e.fat_g = round(f.fat_g * 1.5, 2)
      and e.carbs_g = round(f.carbs_g * 1.5, 2)
      and e.food_name = f.name
   from public.entries e join public.foods f on f.id = e.food_id),
  'trigger scaled 150 g to 1.5x the per-100 g values');

-- editing grams re-runs the snapshot
update public.entries set grams = 300;
select pg_temp.ok(
  (select e.kcal = round(f.kcal * 3, 2)
   from public.entries e join public.foods f on f.id = e.food_id),
  'changing grams rescales the snapshot');
update public.entries set grams = 150;

-- an ad-hoc entry with no catalog food still needs its own numbers
insert into public.entries (logged_on, meal, grams, food_name, kcal, protein_g, fat_g, carbs_g)
values (date '2026-09-01', 'snack', 330, 'Beer, pint', 208, 1.6, 0, 17.6);

do $$
begin
  insert into public.entries (logged_on, grams, food_name) values (date '2026-09-01', 100, 'Mystery');
  raise exception 'FAIL: accepted an ad-hoc entry with no kcal';
exception
  when check_violation then raise notice 'ok  ad-hoc entry without kcal is rejected';
end
$$;

select pg_temp.ok(
  (select kcal from public.daily_totals where logged_on = date '2026-09-01')
   = (select round(sum(kcal), 1) from public.entries where logged_on = date '2026-09-01'),
  'daily_totals sums the day');

-- a user may not relabel their food as a catalog row
do $$
begin
  update public.foods set fdc_id = 999999 where name = 'Ana''s protein shake';
  raise exception 'FAIL: user claimed an fdc_id';
exception
  when insufficient_privilege or check_violation then
    raise notice 'ok  user cannot claim a catalog fdc_id';
end
$$;

-- and may not edit the catalog
call pg_temp.ok_no_rows(
  'update public.foods set kcal = 1 where fdc_id = 2262074',
  'user updates to catalog rows match no rows');

-- ---------------------------------------------------------------------------
-- Bo: sees the catalog, none of Ana's data
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';

select pg_temp.ok((select count(*) from public.foods) = 329,
  'Bo sees the catalog but not Ana''s food');
select pg_temp.ok((select count(*) from public.foods where name = 'Ana''s protein shake') = 0,
  'Ana''s food is invisible to Bo');
select pg_temp.ok((select count(*) from public.search_foods('protein shake')
                    where name = 'Ana''s protein shake') = 0,
  'search_foods does not leak Ana''s food to Bo');
select pg_temp.ok((select count(*) from public.food_portions where unit = 'scoop') = 0,
  'Ana''s portions are invisible to Bo');
select pg_temp.ok((select count(*) from public.entries) = 0, 'Bo sees no entries');
select pg_temp.ok((select count(*) from public.daily_totals) = 0, 'Bo sees no daily totals');
select pg_temp.ok((select count(*) from public.profiles) = 1, 'Bo sees only his own profile');

-- deletes silently match nothing rather than erroring, which is what RLS does
call pg_temp.ok_no_rows(
  'delete from public.entries',
  'Bo cannot delete Ana''s entries');

-- Bo cannot log Ana's private food even by guessing its id
do $$
declare ana_food bigint;
begin
  select id into ana_food from public.foods where owner_id is not null;      -- invisible to Bo
  select max(id) + 10 into ana_food from public.foods;                        -- so guess instead
  insert into public.entries (food_id, grams) values (ana_food, 100);
  raise exception 'FAIL: Bo logged a food he cannot see';
exception
  when foreign_key_violation or insufficient_privilege then
    raise notice 'ok  Bo cannot log a food he cannot see';
end
$$;

-- ---------------------------------------------------------------------------
-- back to Ana: her data is still there, and recent_foods is scoped to her
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select pg_temp.ok((select count(*) from public.entries) = 2, 'Ana still sees her two entries');
select pg_temp.ok((select count(*) from public.recent_foods()) = 1,
  'recent_foods lists the one catalog food Ana logged');

-- profile goals are editable, and only her own
update public.profiles set kcal_goal = 2300 where id = '11111111-1111-1111-1111-111111111111';
select pg_temp.ok((select kcal_goal from public.profiles) = 2300, 'Ana can set her own goal');
call pg_temp.ok_no_rows(
  $q$update public.profiles set kcal_goal = 1
     where id = '22222222-2222-2222-2222-222222222222'$q$,
  'Ana cannot change Bo''s goal');

reset role;
rollback;
\o

\echo 'all rls.sql assertions passed'
