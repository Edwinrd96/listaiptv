#!/bin/sh
# Levanta Postgres + PostgREST locales con el esquema aplicado (simula Supabase para pruebas de integración).
# Uso: sh scripts/dev_stack.sh   -> deja PostgREST en http://127.0.0.1:3000
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pkill -f "/opt/pgrst/postgrest" 2>/dev/null || true; pkill -f supabase_gateway 2>/dev/null || true; sleep 1
pg_ctlcluster 16 main start 2>/dev/null || true; sleep 3
su postgres -c "psql -q -c \"drop database if exists iptvtest with (force)\" -c \"create database iptvtest\""
su postgres -c "psql -q -v ON_ERROR_STOP=1 -d iptvtest -f $ROOT/scripts/mock_supabase.sql" 2>/dev/null
for f in $ROOT/supabase/migrations/*.sql; do su postgres -c "psql -q -v ON_ERROR_STOP=1 -d iptvtest -f $f" 2>&1 | grep -v NOTICE || true; done
cat > /tmp/pgrst.conf <<CONF
db-uri = "postgres://authenticator:pw@127.0.0.1:5432/iptvtest"
db-schemas = "public"
db-anon-role = "anon"
jwt-secret = "test-secret-test-secret-test-secret-123456"
server-host = "127.0.0.1"
server-port = 3000
CONF
nohup /opt/pgrst/postgrest /tmp/pgrst.conf >/tmp/pgrst.log 2>&1 &
nohup node $ROOT/scripts/supabase_gateway.mjs >/tmp/gateway.log 2>&1 &
sleep 2; curl -s -o /dev/null -w "Supabase simulado (gateway) HTTP %{http_code}\n" http://127.0.0.1:3100/rest/v1/
