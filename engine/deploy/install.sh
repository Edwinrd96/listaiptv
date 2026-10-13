#!/bin/sh
# Instala y arranca el motor en un VPS Ubuntu/Debian (x86 o ARM). Seguro de repetir.
# Uso (desde la carpeta engine/ ya copiada al servidor):
#     sudo sh deploy/install.sh                # instala Docker si falta, valida .env, arranca el motor
#     sh deploy/install.sh --check-only        # solo valida .env y el archivo compose (no instala nada)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE_DIR="$(cd "$HERE/.." && pwd)"
ENV_FILE="$ENGINE_DIR/.env"
COMPOSE="$HERE/docker-compose.vps.yml"
CHECK_ONLY=0; [ "${1:-}" = "--check-only" ] && CHECK_ONLY=1

say()  { printf '\n== %s\n' "$*"; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. validar .env
say "1/5 Validando engine/.env"
[ -f "$ENV_FILE" ] || fail "Falta $ENV_FILE. Cópialo desde tu PC (generado por 'python scripts/setup_wizard.py init') o crea uno desde .env.example."
val() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//'; }
URL="$(val SUPABASE_URL)"; KEY="$(val SUPABASE_SERVICE_KEY)"; VANT="$(val VANTAGE)"
case "$URL" in https://*.supabase.co|http://*) ;; *) fail "SUPABASE_URL inválida ('$URL'). Debe ser https://TU-PROYECTO.supabase.co";; esac
case "$URL" in *TU-PROYECTO*) fail "SUPABASE_URL sigue con el texto de ejemplo.";; esac
case "$KEY" in eyJ*.*.*) ;; *) fail "SUPABASE_SERVICE_KEY no parece una clave JWT (debe empezar con eyJ…, la «service_role» de las Legacy API keys).";; esac
case "$VANT" in local-*) printf '[AVISO] VANTAGE=%s: en un VPS fuera de tu país usa VANTAGE=vps-eeuu (solo 404/410 cuentan como strike); si no, canales válidos saldrán caídos.\n' "$VANT";; esac
[ -n "$VANT" ] || fail "Falta VANTAGE en .env (usa vps-eeuu en un VPS de EE. UU.)."
chmod 600 "$ENV_FILE" 2>/dev/null || true
echo "  .env correcto (URL, clave service_role y VANTAGE=$VANT)"
[ "$CHECK_ONLY" = 1 ] && { echo "  (--check-only: no se instala nada)"; exit 0; }

[ "$(id -u)" = 0 ] || fail "Ejecuta con sudo:  sudo sh deploy/install.sh"
command -v apt-get >/dev/null 2>&1 || fail "Este instalador es para Ubuntu/Debian (usa apt). En otro sistema instala Docker a mano y ejecuta: docker compose -f deploy/docker-compose.vps.yml up -d --build"

# ---------------------------------------------------------------- 2. memoria de apoyo (swap) en VPS pequeños
say "2/5 Memoria"
MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
SWAP_MB="$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)"
echo "  RAM: ${MEM_MB} MB · swap: ${SWAP_MB} MB"
if [ "$MEM_MB" -lt 2000 ] && [ "$SWAP_MB" -lt 512 ]; then
  echo "  RAM baja: creando 1 GB de swap en /swapfile"
  [ -f /swapfile ] || { fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; chmod 600 /swapfile; mkswap /swapfile >/dev/null; }
  swapon /swapfile 2>/dev/null || true
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ---------------------------------------------------------------- 3. Docker
say "3/5 Docker"
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io >/dev/null || fail "No se pudo instalar docker.io"
fi
if ! docker compose version >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 \
    || fail "No se pudo instalar el plugin «docker compose». Instálalo siguiendo https://docs.docker.com/engine/install/ubuntu/"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker --version; docker compose version

# ---------------------------------------------------------------- 4. arrancar
say "4/5 Construyendo y arrancando el motor (la primera vez tarda unos minutos)"
docker compose -f "$COMPOSE" config -q || fail "El archivo compose no es válido."
docker compose -f "$COMPOSE" up -d --build

# ---------------------------------------------------------------- 5. comprobar
say "5/5 Comprobando conexión con Supabase"
sleep 5
if docker compose -f "$COMPOSE" run --rm --no-deps engine python -m iptv_engine doctor; then
  echo; echo "  ✔ Motor funcionando. Ver registros:  docker compose -f $COMPOSE logs -f"
  echo "  ✔ Se reinicia solo si el servidor se reinicia (restart: unless-stopped)."
else
  fail "El motor no pudo conectar. Revisa SUPABASE_URL y SUPABASE_SERVICE_KEY en .env y vuelve a ejecutar este script."
fi
