# IPTV Engine Pro

```
 Panel React ──(supabase-js, RLS)──► Supabase (Postgres · Auth · Realtime)  ◄── Motor Python/Docker (verifica, repara)
        │                                   ▲                                         
        └──► Worker Cloudflare (Hono) ──────┘   lista M3U pública · /health · sondeo · proxy de prueba · resolvedor Dailymotion
                         ▲
        TiviMate · OTT Navigator · VLC  (https://play.TUDOMINIO.com/p/<token>.m3u)
```

| Carpeta | Qué es | Estado |
|---|---|---|
| `supabase/migrations` | 0001 núcleo · 0002 Worker · 0003 SaaS (planes, límites, cobros apagados) · 0004 funciones (Hospital, BYON, BYOP, DRM, importación masiva, catálogo, uptime…) · 0005 apoyo al admin · 0006 resolvedores | ✅ 226 comprobaciones en PostgreSQL 16 real |
| `worker/` | API, lista M3U, entrega inteligente, enrutador de resolvedores, guía EPG, proxy de prueba, webhook de cobros (Hono/TypeScript) | ✅ 53 pruebas |
| `engine/` | Motor Python/Docker: sondeo, 3 strikes, Hospital, reparación, EPG, agente BYON, proxies | ✅ 19 pruebas |
| `ui/` | Panel React + Vite + Tailwind: canales, importación masiva, Hospital, Salud, Comunidad, Multivista, Conexiones, Logros, Admin, paleta Ctrl+K, PWA | ✅ compila; probado en navegador contra la base real |
| `tools/` | Convierte tu `channels.yaml` en SQL de importación | ✅ |
| `docs/` | **`GUIA_DESDE_CERO.md` (empieza aquí)**, `API.md`, `PORTABILITY.md`, `UI_MAP.md` | ✅ |

> **¿Primera vez? Sigue `docs/GUIA_DESDE_CERO.md`.** Lo de abajo es un resumen técnico.

> Probado contra Postgres + PostgREST **reales** (la misma capa que usa Supabase). No he podido probarlo contra tu proyecto de Supabase ni contra Cloudflare: eso lo verificas tú en el paso 6.

## Puesta en marcha (en este orden)
### 1. Supabase (gratis)
1. supabase.com → New project (región cercana a tu audiencia). Guarda la contraseña de la base.
2. **SQL Editor** → ejecuta EN ORDEN `0001_init.sql`, `0002_worker_helpers.sql`, `0003_saas_core.sql`, `0004_features.sql`, `0005_admin_ui.sql`, `0006_resolvers.sql`.
   Hazte administrador (una sola vez, en el SQL Editor): `update public.profiles set role='admin' where id = (select id from auth.users where email='TU@CORREO');`
3. **Authentication → Users → Add user** (tu correo y clave). Al crearse, la base te crea sola tu lista, categoría y enlace de salida.
4. **Project Settings → API**: copia `Project URL`, `anon key` y `service_role key` (SECRETA).
5. Importar tus 190 canales: `python tools/yaml_to_json.py channels.yaml --sql > seed.sql` y pega `seed.sql` en el SQL Editor.

### 2. Worker de Cloudflare
```
cd worker && npm install
npx wrangler login
npx wrangler secret put SUPABASE_URL           # Project URL
npx wrangler secret put SUPABASE_ANON_KEY
npx wrangler secret put SUPABASE_SERVICE_KEY
npx wrangler secret put SIGNING_SECRET         # cualquier texto largo y aleatorio
npx wrangler deploy
```
Comprueba `https://<tu-worker>.workers.dev/health` → `{"ok":true,...}`.
Si tu proyecto Supabase usa clave **HS256**, añade también el secreto `SUPABASE_JWT_SECRET`; si usa claves asimétricas (JWKS), no hace falta.
**Dominio propio** (recomendado antes de compartir enlaces): Cloudflare → Workers → tu Worker → Settings → Domains & Routes.
Edita `ALLOWED_ORIGINS` en `wrangler.toml` con la dirección de tu panel.

### 3. Tu enlace de lista
En el SQL Editor: `select token from public.outputs;` → tu lista es `https://<tu-dominio>/p/<token>.m3u` (VLC: `.vlc.m3u`). Compruébala en el navegador: debe descargar la M3U.

### 4. Motor (elige uno)
- **Docker en un PC/servidor del país donde se ven tus canales (recomendado para canales solo-RD):**
  `cd engine && cp .env.example .env` (rellena URL y service key; `VANTAGE=local-do`) → `docker compose up -d`. Comprueba con `docker compose run --rm engine python -m iptv_engine doctor`.
- **VPS gratuito:** sube el repo, añade los secretos `SUPABASE_URL` y `SUPABASE_SERVICE_KEY`; usa `.github/workflows/engine.yml`. Desde EE. UU. solo cuentan los 404/410 como strikes (los demás fallos quedan como "no verificable").

### 5. Botón «Forzar sincronización»
Funciona con el motor en modo `loop` (responde en ≤15 s). Con Actions, define en el Worker `GITHUB_REPO`, `GITHUB_WORKFLOW=engine.yml` y el secreto `GITHUB_DISPATCH_TOKEN` (token con permiso *Actions: write*).

### 6. Verifica de punta a punta
1. `…/health` responde. 2. La lista descarga y tiene tus canales. 3. En SQL: `select * from public.request_sync((select id from playlists limit 1))` crea un trabajo y, en ≤15 s, `select status from sync_jobs order by requested_at desc limit 1` pasa a `succeeded`. 4. `select message from engine_logs order by id desc limit 20` muestra la consola.

## Pruebas automáticas
`sh scripts/test_all.sh` (necesita PostgreSQL 16 local y los binarios de PostgREST; ver `scripts/dev_stack.sh`).

## Límites honestos
- Los límites de uso del Worker (`rateLimit`) son **por instancia**: frenan abusos normales, no un ataque distribuido. Para un SaaS usa el *Rate Limiting binding* de Cloudflare.
- La Cache API del Worker puede ignorarse en `*.workers.dev`; la protección principal ("una sola petición" + memoria) funciona siempre. Con dominio propio, la caché compartida también.
- El proxy de reproductor (sesión de 2 min) consume tu cuota de 100 000 peticiones/día del plan gratis; desactívalo con `PLAYER_PROXY_ENABLED=false`.
- Los tokens de Dailymotion/YouTube pueden estar atados a IP o país; el motor los renueva **desde su propia red**.

## Nuevo en esta versión
- **Cobros APAGADOS**: `billing_mode = off`. Los límites del plan gratis ya se aplican en la base; las funciones sin coste (hospital, enriquecimiento, DRM…) están abiertas a todos durante la fase gratis y se cierran solas al activar el cobro con `admin_activate_billing()` (concede 6 meses Pro + 20 % de por vida a los usuarios existentes).
- **Hospital de canales**: 3 strikes → cuarentena de 7 días con sondeo esporádico (cada 12 h); después se declara «muerto» (no se borra; revisión semanal por si resucita).
- **Entrega inteligente** (Pro): la lista apunta a `/p/<token>/play/<canal>`; el Worker redirige (302) a la mejor fuente viva.
- **BYON**: en el panel crea un agente y ejecuta `python -m iptv_engine agent` en tu PC con `SUPABASE_ANON_KEY` + `AGENT_TOKEN` (nunca la service_role).
- **BYOP**: tus proxies HTTP/SOCKS5 por país, canal o fuente; los usa el motor/agente.
- Configuración 100 % por variables de entorno: ver `.env.example` y `docs/PORTABILITY.md`.
