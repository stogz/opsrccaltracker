# Open Source Calorie Tracker
by Sam Stogsdill

A calorie and macro tracker: a shared food database anyone can search, plus a
private diary per user. Static front end on Vercel, Postgres on Supabase, no
build step and no backend code of its own.

**Live:** https://opsrccaltracker.vercel.app/

## How it fits together

```
db/catalog/core.json ──build-seed.mjs──> supabase/seed/0001_foods.sql ──> public.foods
                                                                          public.food_portions
browser (index.html) ──supabase-js──> PostgREST ──> public.entries, public.profiles
                                          │
                                    row level security
```

There is no server of ours in that path. The browser talks to Postgres directly
with the public anon key, and **row level security is the entire authorization
model** — see [`supabase/migrations/0002_rls.sql`](supabase/migrations/0002_rls.sql).
If a rule isn't expressed there, it isn't enforced.

## The data model

| Table | What it holds |
| --- | --- |
| `foods` | The catalog *and* user-created foods in one table. `owner_id IS NULL` means a public catalog row; otherwise it belongs to that user. All nutrients are **per 100 g**. |
| `food_portions` | Household measures for a food — `1 serving = 140 g` — so nobody needs a kitchen scale. |
| `entries` | The diary. Stores `grams` plus a **snapshot** of the nutrition for that quantity. |
| `profiles` | One row per user: daily calorie and macro goals. Created automatically on signup. |
| `daily_totals` | View: one row per user per day, summing the diary. |

Two decisions worth knowing about:

**Entries snapshot their nutrition.** A diary row stores the computed calories,
protein, fat and carbs for the grams eaten, not just a pointer to the food. A
`BEFORE INSERT` trigger fills them in, so the client only ever sends `food_id`
and `grams`. This means fixing a wrong calorie count in the catalog next year
does not silently rewrite what someone ate last year — and a day's totals need
no join.

**One `foods` table, not two.** Splitting the catalog from user foods would mean
every search, every portion lookup and every diary join happening twice and
being stitched back together. A nullable `owner_id` plus one RLS policy does the
same work.

## Setting it up

**1. Run the migrations.** In the Supabase dashboard → SQL Editor, run these in
order:

```
supabase/migrations/0001_core.sql   -- tables, indexes, triggers, the daily_totals view
supabase/migrations/0002_rls.sql    -- row level security and grants
supabase/migrations/0003_api.sql    -- the search_foods and recent_foods functions
```

**2. Load the catalog.** Run `supabase/seed/0001_foods.sql` the same way. It's
329 foods with 389 portions, and it's safe to re-run — catalog rows are matched
on their USDA `fdc_id` and updated in place, and user-created foods are never
touched.

**3. Point the front end at the project.** Open
[`scripts/config.js`](scripts/config.js) and replace the placeholder with your
**anon** key from Project Settings → API Keys. That key is public by design; it
ships in every Supabase web app and grants nothing on its own, because RLS
decides what any caller can see. The `service_role` key is the secret one and
must never go in this file.

**4. Turn on email sign-in.** Authentication → Providers → Email. The app offers
three ways in, all through that one provider:

- **Email + password** — the default, and the only one that sends no email at all.
- **Magic link** — behind "Email me a link instead".
- **Password reset** — behind "Forgot password?", which returns to the site and
  swaps the diary for a "set a new password" form.

**5. Set the redirect URLs.** Authentication → URL Configuration. Set **Site
URL** to your deployed origin and add it to **Redirect URLs** as
`https://your-site.example/**`. Supabase ignores the redirect the app asks for
unless it's on that list, and falls back to the Site URL — which on a new
project is `http://localhost:3000`. Getting this wrong is why an emailed link
lands on a dead localhost page. Add `https://your-project-*.vercel.app/**` too
if you want preview deployments to work.

Push to `main` and Vercel redeploys.

### Signing in without any email

While you're building, or any time the email quota below gets in the way, skip
email entirely: Authentication → Users → **Add user**, with "Auto Confirm User"
ticked. Then sign in with that email and password on the site. No message is
sent, and nothing is rate limited.

### Updating the catalog

Edit `db/catalog/core.json`, then:

```sh
node scripts/build-seed.mjs      # regenerates supabase/seed/0001_foods.sql
```

Run the regenerated file against the project. `build-seed.mjs` validates as it
goes: it rejects duplicate `fdc_id`s and clamps values to the schema's ranges,
warning on each one. (Ten meats currently carry a slightly negative carb value —
that's how USDA's "carbohydrate by difference" behaves on near-zero-carb foods,
and the script floors them at zero.)

## Tests

```sh
scripts/test-db.sh
```

Applies the migrations, the seed and `supabase/tests/rls.sql` to a throwaway
local Postgres, then deletes it. Nothing touches the real project. It needs
Postgres 15+ with `pg_trgm`; pass `DATABASE_URL` to run against a scratch
database instead.

The assertions are the security claims themselves — two users, one catalog:
that Bo cannot see, log, or delete anything of Ana's, that `search_foods`
doesn't leak her custom foods, that anonymous visitors can read the catalog and
nothing else, that nobody but the service role can edit a catalog row, and that
the trigger's arithmetic is right.

`supabase/tests/harness.sql` stubs the `auth` schema and the anon /
authenticated / service_role roles that Supabase provides for real. It exists so
the tests can run on a bare Postgres — **never run it against the project.**

## Staying inside the free tier

The free plan gives you 500 MB of database, 5 GB egress and 50,000 monthly
active users. This schema is nowhere near any of them: the catalog is 1.3 MB
with indexes, and a diary row costs 262 bytes, so a user logging ten foods a day
accumulates about 0.9 MB a year.

The limits that will actually bite:

- **Projects pause after 7 days with no activity.** A paused project returns
  errors until you resume it from the dashboard. Any real traffic prevents this.
- **The built-in email sender is rate-limited** to a couple of messages an hour,
  shared across the whole project and counting every kind of auth mail together
  — so retrying with a different address doesn't help. Password sign-in avoids
  it completely; magic links, signup confirmations and password resets all spend
  from it. The current numbers are on the Authentication → Rate Limits page.
  Supabase treats this sender as development-only and doesn't guarantee
  delivery, so configure custom SMTP (Authentication → Emails → SMTP Settings)
  before inviting anyone. Doing that also makes the rate limit yours to set.
- **No automatic backups on the free plan.** `pg_dump` occasionally if the data
  matters to you.

## Nutrition data

Food data comes from [USDA FoodData Central](https://fdc.nal.usda.gov/), public
domain. `foods.fdc_id` is the join key back to the source release.

Values are per 100 g. Restaurant and branded items are estimates, and USDA's own
figures carry real measurement variance — this is a tracker, not a laboratory.
