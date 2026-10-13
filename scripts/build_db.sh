#!/bin/sh
# Reconstruye la base de pruebas "iptvtest" con el mock de Supabase + todas las migraciones.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pg_ctlcluster 16 main start 2>/dev/null || true; sleep 2
su postgres -c "psql -q -c \"drop database if exists iptvtest with (force)\" -c \"create database iptvtest\"" || exit 1
su postgres -c "psql -q -v ON_ERROR_STOP=1 -d iptvtest -f $ROOT/scripts/mock_supabase.sql" >/dev/null 2>&1 || { echo "mock FALLÓ"; exit 1; }
for f in $ROOT/supabase/migrations/*.sql; do
  out=$(su postgres -c "psql -q -v ON_ERROR_STOP=1 -d iptvtest -f $f" 2>&1 | grep -v NOTICE)
  if echo "$out" | grep -qi "error"; then echo "FALLÓ $(basename $f):"; echo "$out" | head -15; exit 1; fi
done
echo "MIGRACIONES OK: $(ls $ROOT/supabase/migrations | tr '\n' ' ')"
