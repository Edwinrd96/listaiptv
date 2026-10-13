#!/bin/sh
# Corre TODAS las pruebas: SQL (226) + Worker (53) + motor Python (19). Requiere PostgreSQL 16 local y PostgREST en /opt/pgrst.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "== 1/4 Base de datos (SQL real: RLS, límites, SaaS, hospital, BYON/BYOP, catálogo)"
python3 "$ROOT/tools/yaml_to_json.py" "$ROOT/tools/channels.yaml.example" > /tmp/seed.json
for t in tests_smoke tests_0003_core tests_0004_features tests_0005_admin; do
  sh "$ROOT/scripts/run_sql_test.sh" "$ROOT/supabase/$t.sql" 2>&1 | grep -E "✘|ERROR|comprobaciones" | sed "s/^/  $t: /"
done
echo "== 2/4 Levantando Postgres + PostgREST"; sh "$ROOT/scripts/dev_stack.sh" | tail -1
echo "== 3/4 Worker (unitarias + red + integración + funciones SaaS)"; (cd "$ROOT/worker" && npx vitest run --no-file-parallelism 2>&1 | grep -E "Tests|Test Files|FAIL")
sh "$ROOT/scripts/dev_stack.sh" | tail -1       # base limpia para el motor
echo "== 4/4 Motor Python (perfiles, proxy, pruebas de proxy, agente, importación masiva)"; (cd "$ROOT/engine" && PYTHONPATH=. python3 -m pytest -q tests 2>&1 | tail -3)
echo "== Extra: panel React (tipos + build)"; (cd "$ROOT/ui" && npm run build 2>&1 | grep -E "error|built in")
echo "== Extra: herramientas de instalación"; python3 "$ROOT/scripts/test_tools.py"
