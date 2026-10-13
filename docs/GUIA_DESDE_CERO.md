# Guía desde cero: de los archivos al lanzamiento

Esta guía asume que **solo tienes el zip** (`iptv-engine-pro-v13.zip`) y que no has tocado nada. Cada paso dice qué hacer, qué deberías ver y qué hacer si no lo ves. No te saltes el orden: cada fase depende de la anterior.

> **Honestidad primero.** Todo el código está probado contra Postgres + PostgREST reales y con pruebas automáticas, pero **nunca se ha ejecutado contra tu cuenta real de Supabase, Cloudflare o GitHub**. Por eso cada fase termina con una **comprobación**. Si una comprobación falla, para ahí y mira la sección «Problemas comunes» (al final) antes de seguir.

---

## 0. Qué vas a tener al final

```
 Tu panel (Cloudflare Pages) ──► Supabase (base de datos + usuarios)  ◄── Motor (Docker en tu PC o VPS gratuito)
          │                              ▲
          └────► Worker (Cloudflare) ────┘
                    │
                    └──► https://play.TUDOMINIO.com/p/<token>.m3u   ← lo que pegas en TiviMate / VLC / OTT Navigator
```

| Pieza | Para qué sirve | Costo inicial |
|---|---|---|
| Supabase | Base de datos, usuarios, tiempo real | Gratis |
| Cloudflare Worker | Entrega las listas M3U, la guía, el proxy de prueba | Gratis (100 000 peticiones/día) |
| Cloudflare Pages | Aloja el panel web | Gratis |
| Motor (Python) | Revisa canales, aplica 3 strikes, repara tokens, arma la guía | Gratis (tu PC en RD o un VPS gratuito) |
| Dominio propio | Enlaces que no cambian nunca | ~10–15 USD/año (muy recomendado) |

**Tiempo estimado:** 3–4 horas la primera vez, sin contar el dominio ni la verificación del correo.

---

## 1. Cuentas y programas que necesitas

### Cuentas (todas gratis)
1. **GitHub** — https://github.com (ya tienes `Edwinrd96`).
2. **Supabase** — https://supabase.com (entra con GitHub).
3. **Cloudflare** — https://dash.cloudflare.com/sign-up
4. *(Opcional pero recomendado)* un **dominio**. Compra uno en Cloudflare Registrar o Namecheap. Si lo compras en Cloudflare, todo es más fácil (DNS ya queda ahí).

### Programas en tu computadora
| Programa | Versión | Cómo comprobar | Descarga |
|---|---|---|---|
| Git | cualquiera | `git --version` | https://git-scm.com |
| Node.js | **20 o 22 LTS** | `node --version` | https://nodejs.org |
| Python | **3.12** | `python --version` (en Mac/Linux `python3 --version`) | https://python.org |
| Docker Desktop | reciente | `docker --version` | https://docker.com/products/docker-desktop (solo si el motor correrá en tu PC) |
| Un editor | — | — | VS Code: https://code.visualstudio.com |

> En Windows usa **PowerShell**. Donde un comando difiera entre sistemas, la guía lo indica.

---

## 2. Preparar el código

1. Crea una carpeta, por ejemplo `C:\proyectos\iptv` (o `~/proyectos/iptv`), y descomprime ahí el zip. Debes ver las carpetas `supabase`, `worker`, `engine`, `ui`, `docs`, `scripts`, `tools`.
2. Abre una terminal **dentro de esa carpeta**.
3. Crea un repositorio **PRIVADO** en GitHub (botón *New* → nombre `listaiptv` → **Private**). 
   > ⚠️ **Privado, no público.** Tu `channels.yaml` y tus URLs de canales pueden contener tokens y datos que no debes publicar.
4. Sube el código:
   ```bash
   git init
   git add .
   git commit -m "IPTV Engine Pro v13"
   git branch -M main
   git remote add origin https://github.com/Edwinrd96/listaiptv.git
   git push -u origin main
   ```
5. **Comprueba que no subiste secretos:** en GitHub abre el repositorio; no debe existir ningún archivo `.env` (el `.gitignore` ya los excluye). Nunca los añadas a mano.

### Comprobar que tienes todo instalado
```bash
python scripts/setup_wizard.py check
```
Te dice, con ✔ / ✘, qué falta (Python, Git, Node, npm, Docker). Instala lo que marque ✘ antes de seguir.

### (Opcional) Probar que todo compila en tu computadora
```bash
cd worker && npm install && npm run typecheck && cd ..
cd ui && npm install && npm run typecheck && cd ..
```
Sin errores = el código llegó íntegro. (Las pruebas completas `scripts/test_all.sh` necesitan PostgreSQL local; no hacen falta para lanzar.)

---

## 3. Supabase (la base de datos)

### 3.1 Crear el proyecto
1. Supabase → **New project**. Nombre `iptv-engine`. Elige una **contraseña de base de datos** fuerte y **guárdala** en un gestor de contraseñas.
2. Región: la más cercana a tus usuarios (para RD: *East US (N. Virginia)* suele ser la mejor).
3. Espera 1–2 minutos a que diga que está listo.

### 3.2 Crear toda la base de datos (UN solo pegado)
Esta es la forma **más segura** y evita errores de orden: un único archivo que contiene las 6 migraciones ya en el orden correcto.

1. En tu computadora ejecuta (genera el archivo único):
   ```bash
   sh scripts/build_all_sql.sh          # en Windows sin sh: usa el archivo supabase/ALL_IN_ONE.sql que ya viene en el zip
   ```
2. Supabase → **SQL Editor** → **New query**.
3. Abre `supabase/ALL_IN_ONE.sql`, copia **TODO** (Ctrl+A, Ctrl+C), pégalo y pulsa **Run**. Puede tardar unos segundos.
   - Si avisa *«Query has destructive operations»*: confirma, es normal.
   - Debe terminar con **Success. No rows returned**. Si sale un error rojo, **no repitas ni sigas**: copia el mensaje completo y consulta «Problemas comunes».
   - ⚠️ Hazlo **una sola vez** y en un proyecto **nuevo**. Repetirlo sobre una base ya instalada da errores de «ya existe».
4. **Comprueba la instalación**: abre `supabase/check_db.sql`, pégalo en una consulta nueva y ejecútalo. Verás una tabla de 15 comprobaciones:
   - Las filas 1–14 deben decir **OK** (extensiones, las 6 migraciones, todas las tablas con seguridad RLS, funciones privadas protegidas, visitantes sin acceso a ninguna tabla, tiempo real activo…).
   - La fila 15 («Existe al menos un administrador») dirá **FALLA** hasta que completes el paso 3.5. Es lo esperado.
   - Cualquier otra **FALLA** = detente y revisa.

*(Alternativa avanzada: ejecutar los 6 archivos de `supabase/migrations/` uno por uno, en orden, `0001` → `0006`. El resultado es idéntico.)*

### 3.3 Claves de la API
**Project Settings → API Keys**. Necesitas tres datos (cópialos a un bloc de notas **temporal**):

| Dato | Dónde | ¿Es secreto? |
|---|---|---|
| **Project URL** (`https://xxxx.supabase.co`) | Project Settings → Data API / General | No |
| **anon key** | pestaña **Legacy API keys** → `anon` `public` | No (va en el navegador) |
| **service_role key** | pestaña **Legacy API keys** → `service_role` | **SÍ. Máxima prioridad.** Jamás en el navegador, ni en GitHub, ni en capturas |

> Supabase ahora muestra también las claves nuevas (`sb_publishable_…` / `sb_secret_…`). Este proyecto está hecho para las claves **Legacy `anon` / `service_role`** (son JWT). Usa la pestaña **Legacy API keys**. Si no la ves, en esa misma página hay un enlace para habilitarlas.

> **Red de seguridad:** el asistente del paso 4.1 decodifica tus claves y se niega a continuar si pegaste la `anon` y la `service_role` intercambiadas, si son de otro proyecto o si son las claves nuevas (`sb_…`).

**¿Necesito `SUPABASE_JWT_SECRET`?** Mira **Project Settings → JWT Keys**:
- Si tu clave activa es **asimétrica (ECC / RS256)** → **no** lo necesitas (el Worker usa JWKS automáticamente).
- Si tu clave activa es el **«Legacy JWT secret»** (HS256) → cópialo; lo necesitarás en el Worker como `SUPABASE_JWT_SECRET`.
- Si dudas: sigue sin él. Si luego el panel dice «Sesión inválida o caducada» al usar el Worker, añádelo (paso 5).

### 3.4 Configurar el registro de usuarios
**Authentication → Sign In / Providers → Email**: déjalo habilitado.
- Mientras pruebas: puedes **desactivar «Confirm email»** para entrar sin esperar correos.
- **Antes de abrir al público** (paso 12): vuelve a activarlo **y configura SMTP propio** (el correo integrado de Supabase solo envía unos pocos mensajes por hora).

**Authentication → URL Configuration** lo completarás en el paso 6.5, cuando tengas la dirección del panel.

### 3.5 Crear tu usuario y hacerte administrador
1. Más adelante (paso 6) crearás tu cuenta desde el panel. Por ahora, si prefieres crearla ya: **Authentication → Users → Add user → Create new user** (tu correo + clave, marca *Auto Confirm User*).
2. Al crearse, la base te genera sola: tu **perfil, tu lista, tu categoría y tu enlace de salida**.
3. Hazte administrador (SQL Editor):
   ```sql
   update public.profiles set role = 'admin'
   where id = (select id from auth.users where email = 'TU@CORREO.COM');
   ```
   **Comprobación:** vuelve a ejecutar `supabase/check_db.sql`: ahora las **15 filas** deben decir OK.

### 3.6 (Opcional) Importar tus 190 canales
Si tienes tu `channels.yaml`:
```bash
pip install pyyaml
python tools/yaml_to_json.py channels.yaml --sql > seed.sql
```
Abre `seed.sql`, pégalo en el SQL Editor y ejecútalo **una sola vez**.
> `seed.sql` ya está en `.gitignore`: no lo subas a GitHub.

**Comprobación:** `select count(*) from public.channels;` → tus canales (190 con el ejemplo).
Si no tienes YAML, importa luego desde el panel (botón **Importar**: pega una URL M3U o un archivo).

---

## 4. Worker de Cloudflare (la API y las listas)

### 4.1 Asistente de configuración (genera todos tus archivos sin errores)
Desde la raíz del proyecto:
```bash
python scripts/setup_wizard.py init
```
Te pregunta, una por una: URL de Supabase, clave `anon`, clave `service_role` (no se ve al escribir), dirección del Worker y del panel (si aún no las tienes, déjalas vacías: puedes repetir el asistente luego), nombre del motor y dónde está.
El asistente:
- **verifica** que las claves sean las correctas (anon ≠ service_role, mismo proyecto);
- **genera** un `SIGNING_SECRET` seguro (y lo conserva si repites el asistente);
- escribe `ui/.env` (**solo** con la anon), `engine/.env`, `worker/.dev.vars` y `ALLOWED_ORIGINS` en `worker/wrangler.toml`;
- protege los archivos con permisos privados; `.gitignore` ya los excluye de git.

### 4.2 Entrar a Cloudflare y cargar los secretos
```bash
cd worker
npm install
npx wrangler login          # abre el navegador; autoriza
cd ..
python scripts/setup_wizard.py init --apply-worker      # repite las mismas respuestas; sube los secretos a Cloudflare
```
(`--apply-worker` carga `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_KEY`, `SIGNING_SECRET` y, si lo diste, `SUPABASE_JWT_SECRET`.)

*Alternativa manual:* `cd worker && npx wrangler secret put SUPABASE_URL` (y los demás). Comprueba con `npx wrangler secret list`.

### 4.3 Desplegar
```bash
npx wrangler deploy
```
Al terminar muestra tu URL: `https://iptv-engine.<tu-subdominio>.workers.dev`.

**Comprobación:** abre `https://iptv-engine.<tu-subdominio>.workers.dev/health` → debe responder algo como `{"ok":true,…}`.
Si responde error, mira los logs en vivo: `npx wrangler tail`.

### 4.4 Tu primer enlace de lista
En Supabase → SQL Editor:
```sql
select token from public.outputs;
```
Abre `https://iptv-engine.<tu-subdominio>.workers.dev/p/<TOKEN>.m3u` → debe **descargar/mostrar la M3U** con tus canales. (Si importaste canales ya hay contenido; si no, saldrá vacía y es normal.)

---

## 5. Si el Worker rechaza tu sesión (solo si pasa)
Síntoma: en el panel, «Probar», «Reproducir» o «Forzar sincronización» dicen *«Sesión inválida o caducada»* aunque estés conectado.
Causa: tu proyecto firma con HS256. Solución:
```bash
cd worker
npx wrangler secret put SUPABASE_JWT_SECRET     # el «Legacy JWT secret» de Supabase
npx wrangler deploy
```

---

## 6. El panel web (Cloudflare Pages)

### 6.1 Probarlo en tu computadora primero
El asistente (paso 4.1) ya escribió `ui/.env`. Solo:
```bash
cd ui
npm install
npm run dev
```
Abre http://localhost:5173 → inicia sesión con tu usuario. Debes ver tu lista, la tira de salud y los canales.

> El Worker solo acepta llamadas de orígenes permitidos. `http://localhost:5173` ya viene permitido.

### 6.2 Publicar en Cloudflare Pages
1. Cloudflare → **Workers & Pages** → **Create** → pestaña **Pages** → **Connect to Git** → elige tu repo `listaiptv`.
2. Configuración de compilación:
   - **Framework preset:** None
   - **Root directory:** `ui`
   - **Build command:** `npm run build`
   - **Build output directory:** `dist`
3. **Environment variables** (Production):
   - `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_WORKER_URL` (los mismos tres que están en `ui/.env`)
   - `VITE_LEGAL_NAME` (tu nombre o empresa), `VITE_CONTACT_EMAIL` (correo de contacto); `VITE_LEGAL_REVIEWED` déjala en `false` por ahora
   - `NODE_VERSION` = `20`
4. **Save and Deploy**. Te da una dirección tipo `https://listaiptv.pages.dev`.

### 6.3 Permitir el panel en el Worker
Edita `worker/wrangler.toml` → en `[vars]`:
```toml
ALLOWED_ORIGINS = "http://localhost:5173,https://listaiptv.pages.dev"
```
(Separadas por coma, sin espacios.) Y vuelve a desplegar:
```bash
cd worker && npx wrangler deploy
```

### 6.4 Decirle a Supabase dónde vive el panel
Supabase → **Authentication → URL Configuration**:
- **Site URL:** `https://listaiptv.pages.dev`
- **Redirect URLs:** añade `https://listaiptv.pages.dev/**` y `http://localhost:5173/**`

### 6.5 Verificación automática
Desde la raíz del proyecto:
```bash
python scripts/verify_deploy.py --worker-url https://iptv-engine.<tu-subdominio>.workers.dev --panel-url https://listaiptv.pages.dev --token <TU_TOKEN>
```
(Lee la URL y la anon de `ui/.env`. `<TU_TOKEN>` es el texto largo de tu enlace `/p/<token>.m3u`.) Comprueba desde fuera, como un visitante: que la API responda, que **nadie sin sesión pueda leer tablas ni ejecutar funciones de administración**, que el Worker acepte solo tu panel (CORS), que tu M3U descargue y que **la clave service_role NO esté publicada en el panel**. Debe terminar en `0 FALLAS`.

### 6.6 Comprobación del panel a mano
Abre `https://listaiptv.pages.dev`, inicia sesión y verifica:
- [ ] Los tres puntos de arriba: **Worker** y **Base** en verde (el **Motor** saldrá gris hasta el paso 7).
- [ ] Ves tus canales.
- [ ] Botón **Obtener lista** muestra tu enlace M3U.
- [ ] Como administrador, aparece el botón **Admin**.
- [ ] Abre **Salud**, **Hospital**, **Multivista**: no deben dar error.

---

## 7. El motor (revisa tus canales)

Elige **una** opción (o combina A y B). Para canales que solo se ven desde República Dominicana necesitas la **opción A** (o el agente en tu PC).

### Opción A — Docker en un PC o mini-servidor en RD (la mejor si tienes canales solo-RD)
Debe estar **en el país donde se ven tus canales** y encendido de forma continua (un PC viejo, un mini-PC o una Raspberry Pi 4 sirven).

```bash
cd engine
cp .env.example .env          # PowerShell: Copy-Item .env.example .env
```
Edita `engine/.env`:
```
SUPABASE_URL=https://xxxx.supabase.co
SUPABASE_SERVICE_KEY=<la service_role>
ENGINE_ID=motor-casa
VANTAGE=local-do
```
Arranca:
```bash
docker compose up -d --build
docker compose run --rm engine python -m iptv_engine doctor
```
**Comprobación:** `doctor` imprime `✔ conectado · motor=motor-casa · vantage=local-do …`. En el panel, el punto **Motor** se pone verde (puede tardar hasta 1 minuto). Ver logs: `docker compose logs -f`.

> `VANTAGE=local-*` significa «cualquier fallo cuenta como strike». Desde GitHub/VPS en otro país solo cuentan los 404/410 (un canal solo-RD parecería caído sin estarlo).

### Opción B — VPS gratuito (Oracle Cloud / Google Cloud) — 24/7, sin límite de minutos
Corre el motor siempre encendido, atiende «Forzar sincronización» en ≤ 15 s y no gasta minutos de GitHub. Sigue **`docs/GUIA_VPS_GRATIS.md`** (elegir proveedor, crear el servidor, `sudo sh deploy/install.sh`, comprobaciones y seguridad).
Importante: está en EE. UU., así que usa `VANTAGE=vps-eeuu` y marca tus canales solo-RD con «Solo desde República Dominicana» en el editor (los valida entonces tu agente en casa).

### Opción C — GitHub Actions (solo plan B)
El workflow `engine.yml` quedó **solo manual** (Actions → Motor IPTV → Run workflow): un repositorio privado tiene solo 2 000 minutos gratis al mes y un motor programado los agotaría. Útil para una revisión de emergencia si el VPS cae.

### Comprobación final del motor (ambas opciones)
1. Panel → **Forzar sincronización**.
2. En la **consola** (barra inferior) deben aparecer mensajes («Auditando N fuentes…», «Sincronización terminada»).
3. La tira de salud pasa de gris a verde/amarillo/rojo con tus canales.
4. En Supabase: `select status from public.sync_jobs order by requested_at desc limit 1;` → `succeeded`.

---

## 8. Guía de programación (EPG)

1. En el panel → **Obtener lista** → sección **Guía de programación (EPG)** → pega la URL de cada fuente XMLTV (por ejemplo `https://epg.pw/xmltv/epg_DO.xml`) → **Agregar fuente**.
2. Cada canal necesita su **ID de guía** (en el editor del canal, campo «ID de guía»; el buscador te sugiere). Sin él no hay programación para ese canal.
3. El motor debe **guardar** el archivo en un lugar que el Worker pueda leer. Elige:

### Opción 1 — Cloudflare R2 (la más directa; requiere tarjeta en Cloudflare, no se cobra dentro del plan gratis de 10 GB)
1. Cloudflare → **R2** → **Create bucket** → `iptv-epg`.
2. R2 → **Manage API Tokens** → crea un token con permiso **Object Read & Write** sobre ese bucket. Copia *Access Key ID*, *Secret Access Key* y el *endpoint* (`https://<ACCOUNT_ID>.r2.cloudflarestorage.com`).
3. En `engine/.env` (o en secretos de GitHub / variables del workflow):
   ```
   EPG_STORAGE=s3
   S3_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
   S3_BUCKET=iptv-epg
   S3_ACCESS_KEY_ID=...
   S3_SECRET_ACCESS_KEY=...
   S3_REGION=auto
   ```
4. En `worker/wrangler.toml`, descomenta:
   ```toml
   [[r2_buckets]]
   binding = "EPG_BUCKET"
   bucket_name = "iptv-epg"
   ```
   y `npx wrangler deploy`.

### Opción 2 — Supabase Storage (sin tarjeta)
1. Supabase → **Storage → New bucket** → `epg`, marcado como **Public**.
2. Storage → **S3 Connection** → genera *Access keys*; copia endpoint y región.
3. Motor: `EPG_STORAGE=s3`, `S3_ENDPOINT=<endpoint S3 de Supabase>`, `S3_BUCKET=epg`, claves y `S3_REGION=<región>`.
4. Worker (variable, no secreto) en `wrangler.toml`:
   ```toml
   EPG_PUBLIC_BASE = "https://xxxx.supabase.co/storage/v1/object/public/epg"
   ```
   y `npx wrangler deploy`.
> Esta ruta usa el protocolo S3 de Supabase, que **no he podido probar contra tu cuenta**. Si falla la subida, usa R2.

> En un VPS el Worker de Cloudflare no puede leer el disco del servidor, así que **usa `s3`** (opción 1 o 2); `file` solo sirve si tú mismo expones esa carpeta por HTTP (`EPG_PUBLIC_BASE`).

### Comprobación de la guía
Panel → **Obtener lista** → **Actualizar guía ahora** → en 1–2 minutos el estado dice *«Lista · N canales con programación»*. Abre `https://…/p/<TOKEN>/epg.xml.gz` → descarga el archivo.
Errores frecuentes y su significado:
- *«No hay fuentes de guía»* → agrega una URL.
- *«Ningún canal de tu lista tiene ID de guía»* → asígnalos.
- *«Ninguna fuente trae los canales de tu lista»* → los IDs no coinciden con los de esa fuente.

---

## 9. Dominio propio (hazlo ANTES de compartir enlaces)

Los enlaces de lista contienen tu dominio. Si cambias de dominio después, **todos los enlaces ya entregados dejan de funcionar**. Por eso conviene fijarlo ya.

1. Agrega tu dominio a Cloudflare (si lo compraste fuera: Cloudflare → **Add a domain** y cambia los *nameservers* donde lo compraste).
2. **Worker:** `worker/wrangler.toml`:
   ```toml
   routes = [{ pattern = "play.TUDOMINIO.com/*", zone_name = "TUDOMINIO.com" }]
   ```
   `npx wrangler deploy`. (O desde el panel de Cloudflare: Worker → Settings → Domains & Routes → Add → Custom domain `play.TUDOMINIO.com`.)
3. **Panel:** Pages → tu proyecto → **Custom domains** → `panel.TUDOMINIO.com`.
4. Actualiza todo lo que apuntaba a las direcciones temporales:
   - `ALLOWED_ORIGINS` en `wrangler.toml` → añade `https://panel.TUDOMINIO.com` → `wrangler deploy`.
   - Variable `VITE_WORKER_URL` en Pages → `https://play.TUDOMINIO.com` → **Retry deployment** (las variables `VITE_` se incorporan al compilar).
   - Supabase **Site URL** y **Redirect URLs** → `https://panel.TUDOMINIO.com`.
   - GitHub secrets/variables que mencionen el Worker, si aplica.
5. **Comprobación:** `https://play.TUDOMINIO.com/health` y `https://panel.TUDOMINIO.com` funcionan; **Obtener lista** muestra enlaces con tu dominio.

---

## 10. Probar la lista en un reproductor real

1. Panel → **Obtener lista** → copia el enlace **M3U** (o *M3U para VLC* si usas VLC).
2. **TiviMate / OTT Navigator / IPTV Smarters:** *Añadir lista* → URL → pega el enlace. Si hay guía, añade el enlace **Guía (EPG)** en el campo de EPG.
3. **VLC:** Medio → Abrir ubicación de red → pega el enlace `.vlc.m3u`.
4. Verifica: aparecen los canales por categoría, reproducen, y se ve la guía.

**Modo de entrega** (en «Obtener lista»):
- **Directo:** la lista trae la URL de cada canal. Es lo más barato (no consume el Worker al reproducir).
- **Inteligente (Pro):** la lista apunta al Worker, que elige la mejor fuente viva al momento y salta caídas. Consume peticiones del Worker (100 000/día gratis).

---

## 11. Probar el flujo completo de un usuario nuevo
1. Ventana de incógnito → `https://panel.TUDOMINIO.com` → **Crear cuenta**.
2. Debe aparecer su lista vacía (la crea la base automáticamente).
3. **Importar** → pega una URL M3U pequeña → **Probar** → revisa el resultado → **Importar los que funcionan**.
4. **Obtener lista** → copia su enlace → ábrelo: solo ve **sus** canales (RLS).
5. Comprueba que **no** ve el botón Admin ni datos de otra cuenta.

Si todo eso pasa, la base de seguridad (RLS) está funcionando en tu proyecto real.

---

## 12. Antes de abrir al público

### 12.1 Correo de verdad (obligatorio para registro abierto)
El correo integrado de Supabase está pensado solo para pruebas (muy pocos correos por hora): el registro público se atascaría.
1. Crea una cuenta en un servicio SMTP gratuito (Resend, Brevo, etc.) y verifica tu dominio.
2. Supabase → **Authentication → Emails → SMTP Settings** → activa *Custom SMTP* con esos datos.
3. Vuelve a activar **Confirm email**.
4. Personaliza las plantillas en español (Authentication → Emails → Templates).
5. Prueba creando una cuenta con un correo real.

### 12.2 Textos legales
El panel ya incluye **Términos de uso** y **Política de privacidad** en `https://panel.TUDOMINIO.com/#/terminos` y `#/privacidad` (enlazados desde el registro y desde «Aceptar términos» de Comunidad). Son una **plantilla base** escrita en `ui/src/legal.ts`:
1. Rellena en Pages las variables `VITE_LEGAL_NAME` y `VITE_CONTACT_EMAIL` (y vuelve a desplegar).
2. **Haz que un abogado de tu país los revise y adapte** (leyes de protección de datos, propiedad intelectual y consumo). Edita `ui/src/legal.ts` con sus cambios.
3. Solo entonces pon `VITE_LEGAL_REVIEWED=true`. Mientras valga `false`, las páginas muestran un aviso visible de «borrador sin revisar» (para que no se publique por descuido).
4. Responde de verdad al correo de contacto y retira rápido los enlaces denunciados.

> Este es el punto de mayor riesgo del proyecto: gestionar listas IPTV puede implicar enlaces a contenido protegido por derechos de autor. Tu diseño (catálogo solo con enlaces públicos y consentimiento, listas personales nunca compartidas) ayuda, pero **no sustituye asesoría legal**. No soy abogado y esto no es asesoría legal.

### 12.3 Seguridad (marca cada casilla)
- [ ] El repositorio es **privado** y no contiene `.env`, `seed.sql` ni claves.
- [ ] La `service_role` solo existe en: secretos del Worker, `engine/.env` (tu PC) y/o secretos de GitHub. **No** en Pages, **no** en `ui/.env`.
- [ ] En Pages solo están `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` y `VITE_WORKER_URL`.
- [ ] `ALLOWED_ORIGINS` contiene solo tus dominios.
- [ ] Solo tu usuario tiene `role = 'admin'`: `select email from auth.users u join public.profiles p using(id) where p.role='admin';`
- [ ] Activaste la **verificación en dos pasos** en GitHub, Supabase y Cloudflare.
- [ ] **Authentication → Attack Protection** (CAPTCHA) y los límites de *Rate Limits* revisados antes del registro público.
- [ ] Si el Worker empieza a recibir abusos: Cloudflare → Security → WAF / Rate limiting (las reglas por instancia del código no frenan un ataque distribuido).

### 12.4 Copias de seguridad
Supabase gratis **no incluye copias automáticas**. Hay un workflow listo: `.github/workflows/backup.yml` (cada domingo, guarda el volcado 30 días como «artefacto»).
1. Supabase → **Project Settings → Database → Connection string → Session pooler** → copia la cadena y sustituye `[YOUR-PASSWORD]` por la contraseña de tu base.
2. GitHub → repo → **Settings → Secrets and variables → Actions** → nuevo secreto `SUPABASE_DB_URL` con esa cadena.
3. Pestaña **Actions** → «Copia de seguridad semanal» → **Run workflow** para probarlo. Debe terminar en verde y mostrar un artefacto `respaldo-N`.
4. ⚠️ Solo en repo **privado** (el volcado incluye usuarios). Descarga una copia a otro lugar de vez en cuando.
5. *Aviso honesto:* este workflow no se ha podido probar contra tu proyecto; la prueba del paso 3 es obligatoria. Probar una **restauración** en un proyecto de prueba, al menos una vez, es lo que de verdad confirma que la copia sirve (`pg_restore -d <cadena> respaldo.dump`).

### 12.5 Monitoreo
- Crea un monitor gratuito (UptimeRobot / Better Stack) que consulte `https://play.TUDOMINIO.com/health` cada 5 minutos y te avise por correo/Telegram.
- Opcional: configura `TELEGRAM_TOKEN` y `TELEGRAM_CHAT_ID` en el motor para recibir avisos de canales caídos/recuperados (crea el bot con @BotFather).
- El cron diario del Worker (04:17 UTC) hace la limpieza y evita que Supabase Free se **pause** por inactividad (7 días).

---

## 13. Lanzamiento por fases (recomendado)

**Fase 0 — Solo tú (1 semana).** Usa tu propia lista a diario. Observa el Hospital, la consola y la tira de salud. Ajusta `WORKERS`, `TIMEOUT` y `SCHEDULE_EVERY_MIN` del motor si hace falta.

**Fase 1 — Beta cerrada (5–20 personas de confianza).** Pídeles que usen el panel desde el móvil y desde TiviMate. Revisa: errores en `npx wrangler tail`, consumo del Worker (Cloudflare → Workers → Analytics) y de la base (Supabase → Reports).

**Fase 2 — Público limitado.** Abre el registro, con SMTP, términos y CAPTCHA listos. Mantén **cobros apagados** (`billing_mode = off`): los límites del plan gratis ya se aplican solos y las funciones sin costo están abiertas a todos.

**Fase 3 — Cobros (solo cuando decidas).** Todo está construido pero apagado:
1. Abre cuenta en un *Merchant of Record* (Lemon Squeezy o Paddle) — ellos cobran y gestionan impuestos.
2. Define secretos del webhook (`BILLING_WEBHOOK_SECRET`) y el proveedor en Admin.
3. Pasa a `preview` (muestra planes sin cobrar) y luego a `live`.
4. `admin_activate_billing()` concede a los usuarios existentes el plan **Fundador** (6 meses de Pro + 20 % de descuento de por vida), una sola vez.
Antes de activarlo, prueba en el modo *test* del proveedor con una compra falsa.

---

## 14. Lista final «todo operativo»

- [ ] `ALL_IN_ONE.sql` ejecutado sin error y `check_db.sql` con las 15 filas OK; eres `admin`.
- [ ] `python scripts/verify_deploy.py …` termina en `0 FALLAS`.
- [ ] `https://play.TUDOMINIO.com/health` → ok.
- [ ] El panel carga en `https://panel.TUDOMINIO.com`; Worker y Base en verde.
- [ ] El motor está en verde y «Forzar sincronización» termina en `succeeded`.
- [ ] La lista M3U descarga y reproduce en TiviMate/VLC.
- [ ] La guía (EPG) muestra programación.
- [ ] Un usuario de incógnito solo ve lo suyo.
- [ ] SMTP propio, confirmación de correo, CAPTCHA activos.
- [ ] Términos y privacidad revisados por un abogado (`VITE_LEGAL_REVIEWED=true`) y correo de contacto activo.
- [ ] Copias de seguridad (`backup.yml`) probadas y monitor externo activo.
- [ ] Ningún secreto en el repositorio, en Pages o en capturas.

---

## 15. Problemas comunes

| Síntoma | Causa probable | Solución |
|---|---|---|
| Error al ejecutar una migración | Se ejecutó fuera de orden o dos veces | Si aún no tienes datos reales, lo más limpio es crear un proyecto nuevo y repetir el paso 3.2 en orden; si ya los tienes, copia el mensaje completo del error y pídeme que lo diagnostique |
| `/health` no responde | Worker no desplegado o secretos faltantes | `npx wrangler tail` y revisa que existan los 4 secretos (`npx wrangler secret list`) |
| Panel: «No se pudo cargar» o pantalla en blanco | Variables `VITE_*` mal escritas o sin recompilar | Corrige en Pages y **Retry deployment** |
| Panel: «Sesión inválida o caducada» al usar Worker | Proyecto con HS256 | Paso 5 |
| Panel funciona pero el Worker da error CORS | Falta tu dominio en `ALLOWED_ORIGINS` | Paso 6.3 y `wrangler deploy` |
| Al registrarte no llega el correo | SMTP integrado limitado | Paso 12.1 (o desactiva «Confirm email» solo en pruebas) |
| «Motor» en gris | Contenedor apagado o `doctor` falla | `docker compose logs -f`; revisa `SUPABASE_URL` y `SUPABASE_SERVICE_KEY` |
| Todos los canales salen «sin medir» | El motor aún no corrió | «Forzar sincronización» |
| Canales solo-RD salen caídos desde GitHub | Estás en EE. UU. | Usa el motor en Docker en RD (opción A) |
| «Forzar sincronización» no responde | El motor no está corriendo | Opción A o B: revisa `docker compose logs` (ya no se usa GitHub para esto) |
| La guía dice «Almacén EPG no configurado» (501) | Falta el binding R2 o `EPG_PUBLIC_BASE` | Paso 8 |
| Enlace de lista da 404 | Token distinto o rotado | Cópialo otra vez desde **Obtener lista** |
| Supabase «pausado» | 7 días sin actividad | Reactívalo desde su panel; el cron del Worker lo evita en adelante |

---

## 16. Mantenimiento y actualizaciones

**Actualizar el código** (cuando recibas una versión nueva):
1. Reemplaza las carpetas del proyecto con las del zip nuevo (conserva tus `.env`).
2. **Migraciones:** ejecuta en Supabase, **en orden**, solo las que no hayas ejecutado antes (por ejemplo `0007_….sql`). No repitas las anteriores.
3. Worker: `cd worker && npx wrangler deploy`
4. Panel: `git add . && git commit -m "actualización" && git push` (Pages recompila solo).
5. Motor en tu PC: `cd engine && docker compose up -d --build` · motor en el VPS: copia `engine/` y ejecuta `sh ~/engine/deploy/redeploy.sh`
6. Repite la **lista final** (paso 14).

**Rutina semanal (10 minutos):** mira el Hospital, el panel **Salud** (puntaje y peores canales), el consumo del Worker y haz la copia de seguridad.

**Cuando crezcas** (señales: >100 000 peticiones/día en el Worker, o la base cerca de 500 MB): pasa el Worker a *Workers Paid* (5 USD/mes) y/o Supabase Pro. Para migrar a tu propio VPS cambia solo las variables de entorno: ver `docs/PORTABILITY.md`.
