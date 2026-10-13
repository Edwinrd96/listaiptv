#!/bin/sh
# Uso: sh scripts/run_sql_test.sh supabase/tests_X.sql   -> reconstruye la BD y ejecuta el archivo
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build_db.sh" | tail -4 || exit 1
cp "$1" /tmp/_t.sql; chmod 644 /tmp/_t.sql
su postgres -c "psql -q -v ON_ERROR_STOP=1 -d iptvtest -f /tmp/_t.sql" 2>&1 | sed 's/^psql:[^ ]* //; s/^NOTICE:  //' | grep -v "^CONTEXT\|^PL/pgSQL\|^SQL statement\|^LINE\|^ *\^" | awk '/✔/{n++; print; next} {print} END{print n" comprobaciones ✔"}'
