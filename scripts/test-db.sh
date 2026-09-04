#!/usr/bin/env bash
# Applies the migrations, the seed and supabase/tests/rls.sql to a throwaway
# database, then throws it away. Nothing here touches the Supabase project.
#
#   scripts/test-db.sh                      # spins up a temporary local cluster
#   DATABASE_URL=postgres://... scripts/test-db.sh   # uses a scratch database you point it at
#
# Needs PostgreSQL 15+ with pg_trgm available.
set -euo pipefail

cd "$(dirname "$0")/.."
FILES=(supabase/tests/harness.sql
       supabase/migrations/0001_core.sql
       supabase/migrations/0002_rls.sql
       supabase/migrations/0003_api.sql
       supabase/seed/0001_foods.sql
       supabase/tests/rls.sql)

if [[ -n "${DATABASE_URL:-}" ]]; then
  for f in "${FILES[@]}"; do
    echo "--- $f"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f "$f"
  done
  echo "PASS"
  exit 0
fi

# No connection string: run a cluster in a temp directory on a spare port.
PGBIN="$(pg_config --bindir 2>/dev/null || echo /usr/lib/postgresql/16/bin)"
TMP="$(mktemp -d)"
trap '"$PGBIN/pg_ctl" -D "$TMP/data" -s -m immediate stop >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

"$PGBIN/initdb" -D "$TMP/data" -U postgres --auth=trust >/dev/null
mkdir -p "$TMP/sock"
"$PGBIN/pg_ctl" -D "$TMP/data" -l "$TMP/pg.log" \
  -o "-k $TMP/sock -p 5455 -c listen_addresses=''" -w start >/dev/null

export PGHOST="$TMP/sock" PGPORT=5455 PGUSER=postgres
createdb caltracker_test
for f in "${FILES[@]}"; do
  echo "--- $f"
  psql -d caltracker_test -v ON_ERROR_STOP=1 -q -f "$f"
done
echo "PASS"
