#!/usr/bin/env bash
# Apply every migration to a throwaway local Postgres and run the RLS / business-rule tests.
#
#   supabase/tests/run.sh            # needs initdb, pg_ctl and psql (Homebrew postgresql@17)
#
# Nothing here touches a real Supabase project.
set -euo pipefail
# macOS Postgres refuses to start with an unset locale ("postmaster became multithreaded").
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"
port="${PGTEST_PORT:-54329}"
trap 'pg_ctl -D "$work/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

initdb -D "$work/data" -U supabase_admin --auth=trust >/dev/null
pg_ctl -D "$work/data" -o "-p $port -k $work" -l "$work/log" start >/dev/null
export PGHOST="$work" PGPORT="$port"

psql -q -U supabase_admin -d postgres -c 'create database dhanaos_test'
run() { psql -q -v ON_ERROR_STOP=1 -X "$@"; }

run -U supabase_admin -d dhanaos_test -f "$here/local_stub.sql"
for f in "$root"/migrations/*.sql; do
  echo "migrate  $(basename "$f")"
  run -U postgres -d dhanaos_test -f "$f"
done
echo "seed     seed.sql"
run -U postgres -d dhanaos_test -f "$root/seed.sql"
for f in "$here"/test_*.sql; do
  [ -e "$f" ] || continue
  echo "test     $(basename "$f")"
  run -U supabase_admin -d dhanaos_test -f "$f"
done
echo "all green"
