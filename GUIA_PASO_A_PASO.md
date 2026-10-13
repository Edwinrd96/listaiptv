# GUÍA PASO A PASO · IPTV Edwin RD (v3 Enterprise)

## 0. Cómo funciona (1 minuto)
- Tu repositorio `listaiptv` trabaja solo, gratis, **cada 3 horas**: lee `agregar.txt`, revisa los canales,
  repara los caídos buscando la URL nueva en tus listas externas, genera la lista y la guía EPG.
- Tu enlace NO cambia (es el que pegas en la app):
  `https://raw.githubusercontent.com/Edwinrd96/listaiptv/main/dist/iptv.m3u`
- Para agregar, cambiar o quitar canales **no tocas código**: escribes una línea en `agregar.txt`.
- Límite real: GitHub está en EE.UU. y no puede confirmar canales que solo se ven en RD. Esos quedan como
  🌎 "no verificable" y **se conservan** (solo un 404 sostenido retira un canal). Para comprobarlos de verdad,
  usa el modo opcional del paso 11 (tu PC en RD).

## 1. Subir los archivos nuevos (10 min, solo navegador)
1. Descarga `iptv-edwin-v3.zip` y descomprímelo.
2. En GitHub abre tu repo `listaiptv` -> **Add file -> Upload files**.
3. Arrastra estos archivos y carpetas (reemplazan a los anteriores):
   `iptv.py`, `channels.yaml`, `requirements.txt`, `agregar.txt`, `GUIA_PASO_A_PASO.md`, carpeta `worker`, carpeta `dist`.
4. Abajo pulsa **Commit changes**.
   (No arrastres `.github` ni `.gitignore`: son ocultos; se hacen en el paso 2.)

## 2. Cambiar el workflow y crear .gitignore (5 min)
1. En el repo abre `.github/workflows/iptv.yml` -> icono del lápiz (Edit).
2. Ctrl+A, borra todo y pega EXACTAMENTE esto:

```yaml
name: IPTV Enterprise
# Cada 3 horas (y cuando editas channels.yaml o agregar.txt): procesa agregar.txt, verifica canales,
# repara URLs caídas desde tus listas externas, genera la lista M3U y la guía EPG.
on:
  schedule:
    - cron: "17 */3 * * *"
  workflow_dispatch:
  push:
    paths: ["channels.yaml", "agregar.txt"]
permissions:
  contents: write
concurrency:
  group: iptv
  cancel-in-progress: false
jobs:
  run:
    runs-on: ubuntu-24.04
    timeout-minutes: 25
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12", cache: pip }
      - run: pip install -r requirements.txt
      - name: Agregar, verificar, reparar, generar lista y EPG
        run: python iptv.py run
        env:
          TELEGRAM_TOKEN: ${{ secrets.TELEGRAM_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
      - name: Publicar cambios
        run: |
          git config user.name "iptv-bot"; git config user.email "bot@users.noreply.github.com"
          git add channels.yaml agregar.txt state.json dist
          git diff --cached --quiet && exit 0
          git commit -m "auto: lista, reparaciones y EPG"
          for i in 1 2 3; do git pull --rebase -X theirs && git push && break; sleep 5; done
```
3. **Commit changes**.
4. Add file -> Create new file -> nombre: `.gitignore` -> contenido: `.env` -> Commit.
5. Crea otro archivo `.github/workflows/probar-telegram.yml` (lo usarás en el paso 5) con el contenido del ZIP.

## 3. Primera ejecución (5-10 min)
1. Pestaña **Actions** -> **IPTV Enterprise** -> **Run workflow** -> Run workflow.
2. Espera el check verde ✅. Si sale ❌ roja, ábrela y mándame una captura del paso que falló.
3. Entra a `dist/ESTADO.md` (se ve como tabla) y a `dist/CAMBIOS.md` (qué reparó o agregó el sistema).

## 4. Usar la lista
Pega en tu app el enlace del paso 0. VLC: usa `.../dist/iptv_vlc.m3u`.

## 5. Telegram (avisos de caídos, reparaciones y agregados)
1. En Telegram busca **@BotFather** -> `/newbot` -> nombre -> usuario que termine en `bot` -> copia el **token**.
2. Abre TU bot, pulsa **Start** y escribe "hola".
3. En el navegador abre `https://api.telegram.org/botTU_TOKEN/getUpdates` (cambia TU_TOKEN) y busca
   `"chat":{"id":123456789` -> ese número es tu CHAT_ID.
4. GitHub -> **Settings -> Secrets and variables -> Actions -> New repository secret**. Crea dos:
   `TELEGRAM_TOKEN` (el token) y `TELEGRAM_CHAT_ID` (el número).
5. Actions -> **Probar Telegram** -> Run workflow -> te llega un mensaje.
- NUNCA pegues el token en `channels.yaml`, en un issue ni en un chat. Si se filtra: @BotFather -> `/revoke`.

## 6. Worker de Cloudflare con caché (Color Visión y demás canales Dailymotion)
1. cloudflare.com -> cuenta gratis -> **Workers & Pages -> Create -> Hello World -> Deploy**.
2. **Edit code** -> borra todo -> pega `worker/worker.js` -> **Deploy**.
3. Abre tu dirección `https://algo.tu-usuario.workers.dev`: debe decir **IPTV resolver OK**.
4. Prueba `https://algo.tu-usuario.workers.dev/dm/x7gy059.m3u8` (Color Visión): debe redirigir a un m3u8.
5. SOLO si funcionó: en `channels.yaml` pon `worker_url: "https://algo.tu-usuario.workers.dev"` y Commit.
6. Opcional (anti-abuso): en el Worker -> Settings -> Variables -> `ALLOWED_IDS` = `x7gy059,x8mwmvs,x80ac48`.
- Qué hace: 50 dispositivos a la vez = 1 sola petición a Dailymotion; la URL se guarda 3 min; si Dailymotion
  falla, sirve la última buena hasta 15 min.
- Honestidad: la Cache API de Cloudflare funciona seguro en dominios propios; en `*.workers.dev` puede ignorarse.
  La protección principal (memoria + "una sola petición") sí funciona siempre.

## 7. Agregar / cambiar / quitar canales: `agregar.txt`
Abre `agregar.txt` en GitHub -> lápiz -> escribe UNA línea por acción debajo del bloque de ayuda -> Commit.
En ~2-5 minutos el sistema la procesa, aplica el cambio y borra la línea (si falla, la deja comentada con el motivo).

| Qué quieres | Línea |
|---|---|
| Añadir un canal | `Nombre | URL | grupo | referer | logo` (referer y logo opcionales) |
| Añadir sin validar | `!Nombre | URL | grupo` |
| Cambiar la URL | `CAMBIAR | nombre del canal | nueva URL` |
| Quitar | `QUITAR | nombre del canal` |
| Mover de grupo | `GRUPO | nombre del canal | nuevo grupo` |
| Añadir lista externa | `LISTA | https://.../lista.m3u` |
| Importar canales de otra lista | `IMPORTAR | URL | palabra a buscar | grupo` |

Grupos: escribe parte del nombre (religion, dominicana, locales, noticias, documentales, infantil, mexico...).
Ejemplo: `Mi Canal | https://sitio.com/live/playlist.m3u8 | dominicana | https://sitio.com/`
Nota: en GitHub un canal que no responde se agrega igual marcado "sin verificar" (no ve canales solo-RD).

## 8. Listas externas = reparación automática
- Con `LISTA | url` añades listas M3U que el sistema usa como "almacén de URLs nuevas".
  Por defecto ya consulta las listas por país de iptv-org (`iptv_org_fallback: true` en channels.yaml).
- Si un canal tuyo da 404, el sistema busca su nombre en esas listas (coincidencia por nombre y número),
  prueba cada candidata (timeout 5 s, rotando 3 User-Agents de Smart TV) y, si una funciona, **la pone como URL
  principal en `channels.yaml`** y guarda la vieja como respaldo (`alt`). Todo queda anotado en `dist/CAMBIOS.md`.
- `repair_mode: alt` (en channels.yaml) solo añade respaldos sin cambiar la URL principal.

## 9. EPG automático
- No mapeas nada: el sistema descarga las fuentes de `epg_sources` (channels.yaml), toma SOLO tus canales,
  asigna el `tvg-id` correcto, recorta a 3 días y publica `dist/epg.xml.gz` (se regenera si cambias canales o cada 20 h).
- Para añadir fuentes: agrega cualquier URL XMLTV (.xml o .xml.gz) a `epg_sources`.
  (iptv-org/epg es una herramienta que genera guías, no un archivo único listo.)
- `dist/epg_sin_guia.txt` lista los canales sin guía; `dist/epg_mapping.json` muestra qué guía se usó.
- Si un canal no empareja por nombre, pon en su línea `"epg":"id-en-la-guia"`.

## 10. Extras de la lista M3U
- `tvg-logo`: campo `logo`. Con `logo_base` + carpeta `logos/<id>.png` usas logos propios.
- `group-title`: `group` (y `group_aliases` en settings para renombrar categorías sin tocar canales).
- `tvg-chno`: campo `chno` (número de canal; ordena dentro del grupo).
- Catchup: campos `catchup` (append/default/shift/flussonic), `catchup_source`, `catchup_days`; o una regla para
  todos los de un servidor: `catchup_defaults: [{match: "host.com", catchup: "append", catchup_source: "?utc={utc}&lutc={lutc}", catchup_days: 3}]`.
  Solo funciona si el servidor del canal soporta diferido (la mayoría de canales gratis NO).

## 11. OPCIONAL: verificar desde tu PC en RD (la única forma de saber si un canal SÍ se ve allá)
1. Instala Python (marca "Add to PATH") y Git. En `cmd`: `git clone https://github.com/Edwinrd96/listaiptv.git`,
   luego `pip install pyyaml requests yt-dlp`.
2. Copia estos archivos del ZIP dentro de la carpeta clonada: `actualizar.bat`, `instalar_tarea.bat`, `telegram_setup.bat`.
3. Doble clic en `actualizar.bat` (la primera vez inicia sesión en GitHub). Abre `dist/REPORTE.html`.
4. `instalar_tarea.bat` lo repite cada 2 h. Lo verificado desde RD tiene prioridad sobre lo de GitHub.

## 12. Si algo falla
- Workflow en rojo: abre la ejecución, mira el paso en rojo y mándame captura.
- "Solo X de Y canales respondieron": se cayó internet o hay bloqueo; el sistema NO modifica nada y te avisa.
- Cambié algo y no pasa nada: espera 2-5 min; mira Actions.
- Lista vacía en la app: confirma que usas el enlace `raw.githubusercontent.com/.../dist/iptv.m3u`.
