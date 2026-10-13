# IPTV Engine Pro · Contrato de API (v1)

Tres canales de comunicación, cada uno con un propósito:

| Canal | Quién | Para qué |
|---|---|---|
| **A. Supabase directo** (`supabase-js`, RLS) | Interfaz React | CRUD de canales, categorías, fuentes, lectura de salud y logs |
| **B. Worker API** (`https://play.TUDOMINIO.com/...`, Hono) | Interfaz + reproductores IPTV | Lo que necesita secretos, CPU o salir a internet: sondeo, reproducción de prueba, lista M3U pública, resolvedor |
| **C. Motor** (Python/Docker, `service_role`) | Proceso en segundo plano | Verifica canales, renueva tokens, repara URLs, escribe salud y logs |

Regla de portabilidad: la interfaz habla con la base de datos SOLO a través de una capa `src/api/*.ts`. Si algún día cambias de backend, solo se reescribe esa capa.

---------------------------------------------------------------------------------------------

## A. Supabase directo (con la sesión del usuario; RLS aísla a cada usuario)

| Función de la UI | Llamada |
|---|---|
| Tabla principal (logo, nombre, categoría, EPG, catchup, semáforo) | `from('v_channels_table').select('*').eq('playlist_id', pl).order('sort_order')` |
| Buscador global instantáneo | Se filtra en memoria (hasta ~5 000 canales). Más grande: `.ilike('search_text', '%'+q+'%')` (índice trigram) |
| Categorías (dropdown) | `from('groups').select('id,name').eq('playlist_id', pl).order('sort_order')` · crear al vuelo: `insert` |
| Crear canal | `insert` en `channels` (+ `channel_sources` con `priority` 0 y 1). El `owner_id` NO se envía: lo hereda la base |
| Editar canal | `update` en `channels` / `channel_sources` |
| Borrar | `delete` en `channels` (cascada a fuentes y salud) |
| Reordenar filas | `rpc('reorder_channels', {p_playlist, p_ids})` |
| Intercambiar principal ↔ alterna | `rpc('set_source_priorities', {p_channel, p_ids})` |
| Importar / pegar muchos | `rpc('bulk_upsert_channels', {p_playlist, p_items})` (formato = `tools/yaml_to_json.py`) |
| Autocompletar EPG ID | `rpc('search_epg', {p_playlist, p_q, p_limit})` |
| Botón «Forzar sincronización» | `rpc('request_sync', {p_playlist, p_kind:'full'})` → `{job_id, status, deduped}` |
| Punto de estado del motor / contadores | `rpc('playlist_status', {p_playlist})` |
| Rotar enlace público | `rpc('rotate_output_token', {p_output})` |
| Historial / deshacer | `from('channel_revisions').select('*').eq('row_id', id)` |
| Sparkline de salud | `from('health_events').select('at,ok,latency_ms').eq('source_id', s).gte('at', ...)` |

### Tiempo real (Supabase Realtime, respeta RLS)
```ts
supabase.channel('console')
  .on('postgres_changes', { event:'INSERT', schema:'public', table:'engine_logs', filter:`playlist_id=eq.${pl}` }, addLogLine)
  .on('postgres_changes', { event:'*', schema:'public', table:'source_health', filter:`playlist_id=eq.${pl}` }, updateTrafficLight)
  .on('postgres_changes', { event:'*', schema:'public', table:'sync_jobs',   filter:`playlist_id=eq.${pl}` }, updateSyncButton)
  .subscribe()
```
Carga inicial de la consola: últimas 200 líneas (`order('id', {ascending:false}).limit(200)`).

---------------------------------------------------------------------------------------------

## B. Worker API

Autenticación: `Authorization: Bearer <JWT de Supabase>` (el Worker lo valida contra las claves públicas JWKS de tu proyecto). Errores: `{ "error": { "code": "rate_limited", "message": "…", "retry_after": 30 } }`.

### Públicas
| Método y ruta | Respuesta | Notas |
|---|---|---|
| `GET /health` | `{ ok:true, version, colo, time }` | Alimenta el **punto verde/rojo** de la barra superior. La UI lo consulta cada 30 s con timeout de 3 s; si no responde = rojo |
| `GET /p/:token.m3u` | `text/plain` M3U | Lista del reproductor IPTV. Llama a `get_playlist_payload`, arma el M3U, `ETag` = versión, `Cache-Control: public, max-age=60`, soporta `If-None-Match` → 304 |
| `GET /p/:token.vlc.m3u` | M3U formato VLC | `#EXTVLCOPT` en lugar de headers en la URL |
| `GET /p/:token/epg.xml.gz` | gzip | Guía EPG generada por el motor (guardada en R2/Storage) |
| `GET /dm/:id.m3u8` | 302 | Resolvedor Dailymotion con caché de 3 min (ya construido y probado) |

### Autenticadas (la interfaz)
| Método y ruta | Cuerpo | Respuesta |
|---|---|---|
| `POST /api/sync` | `{ playlist_id, kind? }` | `202 { job_id, status, deduped }`. Llama a `request_sync` y despierta al motor (ver §D) |
| `GET /api/status?playlist_id=` | | `{ worker:'ok', db:'ok', engine:{online,last_seen_at,vantage}, counts:{ok,warn,down,unverified,unknown}, last_job }` (tres puntos: Worker · Base de datos · Motor) |
| `POST /api/probe` | `{ url, referer?, user_agent?, kind? }` | `{ ok, http, latency_ms, variants:[{height,bandwidth,codecs}], segment_ok, error?, hint? }` — sondeo en servidor (manifiesto + sub-manifiesto + 1.er segmento). **No guarda nada** |
| `POST /api/probe/source/:id` | | Igual, y registra el resultado con `record_probe(p_vantage:'worker', p_hard:false)` salvo 404/410 |
| `POST /api/play-session` | `{ source_id }` **o** `{ url, referer?, user_agent? }` | `{ play_url, expires_at, mode:'proxy' }` — token firmado de 2 min para el reproductor (ver §E) |
| `GET /api/play/:session/index.m3u8` y `/seg?u=` | | Proxy mínimo de la sesión de prueba (reescribe URLs del manifiesto) |
| `POST /api/validate/logo` | `{ url }` | `{ ok, content_type, bytes, error? }` — fallback cuando el navegador no puede cargar la imagen (http, hotlink, AVIF…) |
| `GET /api/logo?u=&sig=` | | Imagen cacheada 7 días. Solo URLs firmadas por la API (no es un proxy abierto) |
| `POST /api/import/preview` | `{ url }` o archivo M3U/YAML | Parsea y devuelve candidatos sin guardar; el guardado final usa `bulk_upsert_channels` |
| `GET /api/export?playlist_id=&format=json\|csv` | | Copia de seguridad en el mismo formato que `bulk_upsert_channels` (ida y vuelta) |

### Reglas de seguridad del Worker (obligatorias)
1. **Anti-SSRF** en `/api/probe`, `/api/play-*`, `/api/validate/logo`: solo `http/https`, puertos 80/443/8080/8443/1935/3xxx habituales, nunca IP privadas/loopback/metadata, máx. 3 redirecciones, tope de 1 MB (logo) / 300 KB (manifiesto).
2. **Límites por usuario** (Cache API o contador en la base): sondeos 60/min, sesiones de prueba 10/h, sync 1/min. Respuesta `429` + `Retry-After`.
3. **Sesión de prueba**: máximo 90 s o 25 segmentos; el reproductor se detiene solo. Desactivable con `player_proxy_enabled=false` (protege la cuota gratis de 100 000 peticiones/día).
4. **Secretos** solo en variables del Worker: `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `SIGNING_SECRET`, `GITHUB_DISPATCH_TOKEN` (opcional). Nunca en el navegador.
5. El M3U público usa token de 256 bits; si se filtra, se rota con `rotate_output_token`.

---------------------------------------------------------------------------------------------

## C. Motor (Python/Docker) → base de datos (`service_role`, solo funciones)

| Función SQL | Para qué |
|---|---|
| `claim_job(engine_id, vantage)` | Toma el siguiente trabajo (`FOR UPDATE SKIP LOCKED`) y emite latido |
| `due_sources(limit, playlist, force)` | Qué fuentes toca verificar (ok: 3 h · sospechoso: 30 min · caído: 6 h · desconocido: 1 h; `force` para «Forzar») |
| `record_probe(...)` | **Aquí viven los 3 strikes**: espaciados (por defecto 30 min), fallos «blandos» no cuentan, recuperación resetea, escribe el log de consola y sube la versión de la lista |
| `engine_log(playlist, level, message, job, channel, data)` | Líneas de la consola |
| `engine_heartbeat(engine_id, vantage, version, info)` | Latido (punto verde del motor) |
| `finish_job(job, status, summary, error)` | Cierra el trabajo y republica |
| `purge_old_data()` | Retención: logs 7 d · eventos 14 d · revisiones 90 d |

Bucle del motor: `heartbeat → claim_job → due_sources → probar (timeout 5 s, rotando 3 User-Agents de Smart TV) → record_probe → (reparar desde listas externas) → finish_job`. Los parámetros `p_hard=false` se usan cuando el origen de medición no es fiable para ese canal (GitHub/EE. UU. sin 404).

## D. ¿Cómo «despierta» el botón al motor?
El motor es **pull** (consulta la cola), así que funciona en cualquier sitio:
1. **Docker siempre encendido** (PC en RD o VPS): consulta `claim_job` cada 10–15 s → respuesta casi inmediata.
2. **GitHub Actions** (gratis): el Worker llama a `workflow_dispatch` si existe `GITHUB_DISPATCH_TOKEN`; tarda 30–90 s en arrancar. Además un cron cada 15 min recoge trabajos pendientes.
3. **Ambos a la vez**: el primero que haga `claim_job` gana; el otro no recibe nada.

## E. Reproductor (hls.js): 3 modos, sin engaños
1. **Directo**: hls.js carga la URL tal cual. Solo funciona si el origen tiene CORS, es `https` y no exige Referer/User-Agent.
2. **Vía proxy de sesión** (`/api/play-session`): para casi todos tus canales (Referer/UA/http). Corta a los 90 s.
3. **Informe del servidor** (`/api/probe`): sin reproducir; muestra latencia, resoluciones, bitrate y si el segmento descarga. Siempre disponible y no gasta ancho de banda.
La UI intenta 1 → ante `manifestLoadError`/CORS ofrece 2 automáticamente, y siempre muestra 3.


---------------------------------------------------------------------------------------------

## Adenda v2 (migraciones 0003 y 0004)

### Supabase directo (sesión del usuario)
| Función de la UI | Llamada |
|---|---|
| Plan, nivel, XP y qué funciones tiene | `rpc('my_entitlements')` → `{plan, billing_mode, level, xp, next_level, features:{...}, founder}` |
| Canjear promo / aceptar ToS | `rpc('redeem_promo',{p_code})` · `rpc('accept_tos')` |
| Importación masiva (con auto-clasificación) | `rpc('create_import_batch',{p_playlist,p_items,p_label,p_test})` → ver progreso por Realtime en `import_items` → `rpc('commit_import_batch',{p_batch,p_only_ok,p_apply_enrichment})` |
| Hospital | `from('v_hospital').select('*')` |
| Reportar fallo | `rpc('report_channel',{p_channel,p_kind,p_note})` |
| Uptime 90 días / puntaje | `rpc('channel_uptime',{p_channel,p_days})` · `rpc('playlist_score',{p_playlist})` |
| Proxies (BYOP) | CRUD en `proxies`, `proxy_secrets` (solo escritura), `proxy_assignments` |
| Agentes (BYON) | `rpc('create_agent',{p_name,p_country})` (el token se muestra UNA vez) · `from('agents')` |
| Catálogo | `rpc('match_catalog')` · `rpc('import_from_catalog',{p_playlist,p_catalog_ids})` · `rpc('contribution_preview')` · `rpc('suggest_channel_meta')` |
| Multivista / preferencias | `multiview_layouts`, `user_prefs` |
| Ranking / insignias / misiones | `v_leaderboard`, `user_badges`, `user_missions`, `missions` |
| Admin | `admin_accept_suggestion`, `admin_reject_suggestion`, `admin_seed_catalog_from_playlist`, `admin_report_hotspots`, `admin_set_flag`, `admin_set_setting`, `admin_grant_plan`, `admin_activate_billing` |

Los errores de plan llegan como `53400` con mensaje `limit_reached:<función> (...)`: la UI los traduce a «mejora tu plan».

### Worker
| Ruta | Para qué |
|---|---|
| `GET /p/:token.txt` · `.e2` | TXT y bouquet Enigma2 (requieren «Formatos extra»; 403 `feature_locked` si no) |
| `GET /p/:token/play/:tvg_id` | Entrega inteligente: 302 a la mejor fuente viva; 404 si la salida no es «smart»; 502 `no_source` si todo está muerto |
| `POST /webhooks/billing/lemonsqueezy` | Verifica la firma HMAC SIEMPRE; con `billing_mode=off` responde `ignored`; idempotente |

### Motor / agente
`due_sources(p_limit,p_playlist,p_force,p_vantage,p_owner)` devuelve además `header_profile, extra_headers, proxy_url, in_hospital, vantage_required`. Nuevos: `claim_import_tests`, `record_import_test`, `hospital_sweep` (la llama `purge_old_data`), y para agentes (token propio, rol anon): `agent_heartbeat`, `agent_due_sources`, `agent_record_probe`, `agent_claim_import_tests`, `agent_record_import_test`.

## Guía (EPG)
- `GET /p/:token/epg.xml.gz` — guía XMLTV comprimida de la lista (404 si aún no se generó, 501 si no hay almacenamiento configurado).
- RPC `register_artifact(p_playlist, p_kind='epg_gz', p_key, p_bytes, p_meta)` — la usa el motor al terminar.
- Trabajo de sincronización `kind='epg'` (uno activo por lista).

## Resolvedores (enrutador del Worker)
Cada fuente elige cómo se obtiene su URL con `channel_sources.resolver` (si falta se deduce de `kind`). El catálogo vive en la tabla `resolvers` (el admin puede apagar uno con `enabled=false`).
| clave | capacidad | qué hace |
|---|---|---|
| `direct` | redirect | entrega la URL tal cual |
| `dailymotion` | redirect | token fresco (caché 3 min, una petición a la vez, modo stale) |
| `generic` | redirect | abre la página (`resolve_ref` o `url`), busca el primer `.m3u8` (HTML/JSON, barras escapadas, relativos), caché 3 min, caché negativa 15 s, SSRF validado |
| `youtube` | engine_only | el Worker nunca lo entrega; solo sirve la URL fresca que escribe el motor |
| `azteca_akamai` | proxy_required | solo por proxy de sesión (reservado, apagado) |
`/p/:token/play/:canal` prueba los candidatos en orden y salta los que no se pueden entregar por redirección (el encabezado `X-Resolver` indica `origen`, `memoria` o `stale`). El motor y los agentes aplican el mismo extractor genérico al sondear (`due_sources` ahora devuelve `resolver`).
