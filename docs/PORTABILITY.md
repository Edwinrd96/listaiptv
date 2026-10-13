# Portabilidad: de capas gratis a tu VPS sin tocar código

| Pieza | Hoy (gratis) | Mañana (VPS) | Qué cambias |
|---|---|---|---|
| Base de datos + Auth + Realtime | Supabase Free | Supabase self-hosted, o Postgres 16 + PostgREST + GoTrue | `SUPABASE_URL` y las claves |
| API / M3U / webhooks | Cloudflare Workers Free | El mismo código Hono en Node (`@hono/node-server`) o Docker | despliegue + variables |
| Motor | Docker en tu PC / GitHub Actions | Docker en el VPS (`docker compose up -d`) | `VANTAGE` |
| Panel | Cloudflare Pages | Nginx/Caddy sirviendo `dist/` | `VITE_*` |
| Cobros | apagado (`billing_mode=off`) | Merchant of Record (Lemon Squeezy / Paddle) | `BILLING_WEBHOOK_SECRET` + `billing_provider` |

## Reglas que lo hacen posible
1. **Toda la lógica de negocio vive en SQL** (límites, strikes, hospital, catálogo, XP, entitlements): migrar la base = `pg_dump` + `psql`.
2. **Cero SDK propietarios en el motor y el Worker**: solo HTTP/PostgREST estándar.
3. **Sin secretos en el código**: `.env.example` lista todo lo configurable.
4. **El panel habla con la base solo a través de `src/api/*.ts`**: cambiar de backend = reescribir esa capa.

## Migrar a un VPS (checklist)
1. `pg_dump` de Supabase → `psql` en tu Postgres (esquema `public` + `auth.users`).
2. Levanta PostgREST apuntando a esa base (mismos roles: `anon`, `authenticated`, `service_role`).
3. Cambia `SUPABASE_URL` y claves en Worker/motor/panel.
4. Reaplica `supabase/migrations/*.sql` solo si partes de una base vacía.

## Límites de las capas gratis (honestos)
- Supabase Free se **pausa tras 7 días sin actividad** (el cron diario del Worker lo evita) y no incluye copias automáticas: haz `/api/export` periódicamente.
- Workers Free: 100 000 peticiones/día. La entrega inteligente y el proxy de prueba las consumen; con muchos usuarios pasa a Workers Paid (5 USD/mes).
- Proxies BYOP: los usa el **motor/agente** (HTTP/SOCKS5). Un Worker de Cloudflare no puede salir por un proxy SOCKS.

## Guía de programación (EPG)
El motor descarga tus fuentes XMLTV, se queda solo con los canales de tu lista y los próximos `EPG_DAYS` días, y publica `epg/<playlist>.xml.gz`.
- **Almacenamiento**: `EPG_STORAGE=file` (carpeta `EPG_DIR`, para VPS) o `s3` (`S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_REGION`; sirve R2, B2 o MinIO).
- **Worker**: `/p/<token>/epg.xml.gz` lee del binding R2 si existe; si no, de `EPG_PUBLIC_BASE`; si no hay ninguno responde 501.
- Migrar de gratis a VPS = cambiar estas variables; no hay cambios de código.
