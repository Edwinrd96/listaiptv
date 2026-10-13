#!/bin/sh
# Junta las migraciones en UN solo archivo para pegarlo una vez en el SQL Editor de Supabase.
# Uso: sh scripts/build_all_sql.sh      (genera supabase/ALL_IN_ONE.sql)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/supabase/ALL_IN_ONE.sql"
{
  echo "-- IPTV Engine Pro · instalación completa (0001 → 0006) generada por scripts/build_all_sql.sh"
  echo "-- Pégalo ENTERO en Supabase → SQL Editor → Run, UNA sola vez, en un proyecto NUEVO. Luego ejecuta supabase/check_db.sql."
  for f in "$ROOT"/supabase/migrations/*.sql; do
    echo; echo "-- =================================================================== $(basename "$f")"; cat "$f"
  done
} > "$OUT"
echo "Generado: $OUT ($(wc -c < "$OUT") bytes)"
