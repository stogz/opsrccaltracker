-- 0003_api.sql — the RPCs the web client calls
--
-- Both run SECURITY INVOKER, so row level security from 0002 still applies:
-- a user can never see another user's custom food through these.

-- ---------------------------------------------------------------------------
-- search_foods(q) — ranked lookup across the catalog plus the caller's own foods.
--
-- Three matchers, because each fails where the next one works: full-text
-- handles word order and stemming ("boiled egg" -> "Eggs, boiled"), ILIKE
-- handles mid-word fragments, and trigram word-similarity handles misspellings
-- ("brocoli" -> Broccoli, "avacado" -> Avocado). A row matching any of them is
-- returned; full-text hits rank first, fuzzy hits last.
--
-- The 0.4 threshold was picked against this catalog: it accepts avacado (0.46)
-- and yoghurt (0.50) while rejecting chicken-vs-cheddar noise (0.25).
--
-- At catalog size the planner seq-scans 329 rows in ~2.5 ms, which beats any
-- index. foods_name_trgm_idx and foods_search_idx are there for when a user's
-- own foods pile up on top of the catalog and that stops being true.
-- ---------------------------------------------------------------------------
create or replace function public.search_foods(q text, max_results integer default 25)
returns table (
  id        bigint,
  name      text,
  category  text,
  brand     text,
  kcal      numeric,
  protein_g numeric,
  fat_g     numeric,
  carbs_g   numeric,
  fiber_g   numeric,
  sodium_mg numeric,
  is_custom boolean
)
language sql
stable
security invoker
set search_path = public, extensions
set pg_trgm.word_similarity_threshold = 0.4
as $$
  with query as (
    select nullif(btrim(q), '') as term
  )
  select f.id, f.name, f.category, f.brand,
         f.kcal, f.protein_g, f.fat_g, f.carbs_g, f.fiber_g, f.sodium_mg,
         f.owner_id is not null as is_custom
  from public.foods f, query
  where query.term is null
     or f.search @@ websearch_to_tsquery('english', query.term)
     or f.name ilike '%' || query.term || '%'
     or query.term <% f.name
  order by
    -- the caller's own foods win ties: if they bothered to add it, they eat it
    (f.owner_id is not null) desc,
    case when query.term is null then 0
         else ts_rank(f.search, websearch_to_tsquery('english', query.term)) end desc,
    case when query.term is null then 0
         else word_similarity(query.term, f.name) end desc,
    f.name
  limit least(greatest(coalesce(max_results, 25), 1), 100);
$$;

comment on function public.search_foods(text, integer) is
  'Ranked food search over the public catalog and the caller''s own foods. Pass an empty q to browse.';

-- ---------------------------------------------------------------------------
-- recent_foods() — what this user logs most often, newest-first among ties.
-- Powers the "quick add" list, which is how most days get logged.
-- ---------------------------------------------------------------------------
create or replace function public.recent_foods(max_results integer default 12)
returns table (
  food_id     bigint,
  food_name   text,
  usual_grams numeric,
  times_logged bigint,
  last_logged date
)
language sql
stable
security invoker
set search_path = public
as $$
  select e.food_id,
         max(e.food_name)                       as food_name,
         mode() within group (order by e.grams) as usual_grams,
         count(*)                               as times_logged,
         max(e.logged_on)                       as last_logged
  from public.entries e
  where e.user_id = (select auth.uid())
    and e.food_id is not null
  group by e.food_id
  order by count(*) desc, max(e.logged_on) desc
  limit least(greatest(coalesce(max_results, 12), 1), 50);
$$;

grant execute on function public.search_foods(text, integer) to anon, authenticated;
grant execute on function public.recent_foods(integer)       to authenticated;
