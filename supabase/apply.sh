#!/usr/bin/env bash
# Bring a Supabase project up to date: pending migrations, then seed (first run only), then the
# demo sign-ins, profiles and jobs.
#
#   DATABASE_URL='postgresql://postgres.<ref>@<pooler-host>:5432/postgres' PGPASSWORD='…' supabase/apply.sh
#
# or put both in env/db.env (gitignored). The URL is under Project Settings → Database →
# Connection string → Session pooler; the direct db.<ref>.supabase.co host is IPv6-only.
# Pass --no-demo to skip the demo data. The demo sign-ins get DEMO_PASSWORD, which has no default:
# the repo is public, and a default here would be the live super admin's password.
#
# Applied versions are recorded in supabase_migrations.schema_migrations, the table the Supabase
# CLI uses, so switching to `supabase db push` later does not re-run anything.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

if [ -z "${DATABASE_URL:-}" ] && [ -f "$root/env/db.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$root/env/db.env"; set +a
fi
: "${DATABASE_URL:?Set DATABASE_URL or create env/db.env — see the top of this script}"
if [ "${PGPASSWORD:-}" = "PASTE-YOUR-DATABASE-PASSWORD-HERE" ]; then
  echo "env/db.env still has the placeholder password — paste the database password first." >&2
  exit 1
fi
demo_password="${DEMO_PASSWORD:-}"

demo=1
[ "${1:-}" = "--no-demo" ] && demo=0

if [ "$demo" = 1 ] && [ -z "$demo_password" ]; then
  echo "Set DEMO_PASSWORD (the password every demo sign-in gets), or pass --no-demo." >&2
  exit 1
fi

sql() { psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 "$@"; }

sql -c "set client_min_messages = warning;" -c "create schema if not exists supabase_migrations;
        create table if not exists supabase_migrations.schema_migrations (
          version text primary key, statements text[], name text);"

for f in "$here"/migrations/*.sql; do
  file="$(basename "$f" .sql)"
  version="${file%%_*}"
  if [ "$(sql -At -c "select 1 from supabase_migrations.schema_migrations where version = '$version'")" = "1" ]; then
    echo "skip     $file"
    continue
  fi
  echo "migrate  $file"
  # One transaction per migration, recorded in the same transaction.
  { cat "$f"; echo; echo "insert into supabase_migrations.schema_migrations (version, name) values ('$version', '${file#*_}');"; } \
    | sql -1 -f - 2> >(grep -v 'no privileges could be revoked' >&2)
done

if [ "$(sql -At -c "select 1 from orgs where id = '00000000-0000-0000-0000-000000000001'")" = "1" ]; then
  echo "skip     seed.sql (org already present)"
else
  echo "seed     seed.sql"
  sql -1 -f "$here/seed.sql"
fi

if [ "$demo" = 1 ]; then
  echo "demo     demo_users.sql"
  sql -v demo_password="$demo_password" -f "$here/demo_users.sql"
  echo "demo     demo.sql"
  sql -f "$here/demo.sql"
  sql -At -c "select 'profiles: ' || count(*) from app_users where org_id = '00000000-0000-0000-0000-000000000001'"
fi
echo "done"
