# Panel (React + Vite + Tailwind)

```
cd ui && cp .env.example .env     # URL y clave pública (anon) de Supabase + URL del Worker
npm install && npm run dev        # http://localhost:5173
npm run build                     # genera dist/ (súbelo a Cloudflare Pages, Netlify o tu VPS)
```
- Solo usa la clave **anon**. La `service_role` nunca llega al navegador.
- Toda la comunicación con el backend vive en `src/api/index.ts` (cambiar de backend = reescribir ese archivo).
- Hoy incluye: login, cabecera con los 3 puntos de estado (Worker · Base · Motor), tira de señal que filtra por estado, tabla/tarjetas con búsqueda, categoría y «sin guía», consola en tiempo real y «Forzar sincronización».
- Pendiente (siguiente fase): modal nuevo/editar, reproductor con PiP, centro «Obtener lista», importador con pruebas en vivo, hospital, catálogo/aportes, multivista y panel de admin.

## Prueba visual (opcional)
Con la base de pruebas levantada (`sh scripts/dev_stack.sh`): `python3 scripts/ui_seed.py` siembra 190 canales con estados variados y `python3 scripts/ui_shots.py` toma capturas de escritorio y móvil.

## Editor de canales y reproductor (UI-1)
- **Nuevo canal / Editar / Borrar**: modal con logo validado (carga real de la imagen), EPG con búsqueda, URL principal + alternativa, y opciones avanzadas (Referer, User-Agent, catchup, «no validar»).
- **Probar** y **Reproducir** usan el Worker (`VITE_WORKER_URL`). Sin Worker, el panel lo indica y no falla.
- **Reproductor flotante** (hls.js): directo → proxy de sesión (≤90 s) → informe del servidor.

## Obtener lista e Importar (UI-2)
- **Obtener lista**: enlaces M3U, M3U para VLC, TXT y Enigma2 (los dos últimos son del plan Pro), con «Copiar», cambio de enlace (rota el token), qué incluye (solo los que funcionan / todos) y entrega directa o inteligente.
- **Importar**: pega o sube una M3U; se lee en tu navegador, se prueban los canales (los prueba el motor o tu agente) y se importa solo lo que funciona. Los repetidos con el mismo nombre normalizado o del catálogo se agrupan como respaldo.

## Hospital y Comunidad (UI-3)
- **Hospital**: canales caídos con los días que les quedan (7 por defecto), el último error y la última prueba; «Editar» abre el canal para cambiar la URL; «Revisar todo ahora» pide al motor una revisión. Los declarados muertos aparecen aparte.
- **Comunidad**: *Catálogo* (buscar y copiar canales con sus respaldos sanos, función Pro), *Compartir* (aceptar términos, activar/apagar el aporte automático de enlaces públicos y aportar solo nombre y logo de los personales) y *Mis aportes* (estado de cada sugerencia).
- La moderación de la bandeja (aceptar/rechazar) es del panel de administración, que aún no está.

## Administración (UI-4)
El botón **Admin** solo aparece si `is_admin()` es verdadero; aun así, cada acción se vuelve a comprobar en la base de datos (un usuario normal que llame a las funciones recibe «solo admin»).
- **Resumen** · **Cobro** (apagado / vista previa / activar con confirmación escrita; la primera vez concede el plan Founder) · **Funciones** (valores Gratis/Pro y «abierta para todos»; las que cuestan dinero no se pueden abrir) · **Sugerencias** (aceptar/rechazar) · **Reportes** · **Usuarios** (buscar por correo y regalar Pro) · **Auditoría**.

## Conexiones propias (UI-5): agentes (BYON) y proxies (BYOP)
- **Agentes**: crear uno muestra su token **una sola vez** y el comando para arrancarlo en tu PC; la base guarda solo su huella. El punto verde indica que latió en los últimos 3 minutos.
- **Proxies**: la clave se guarda aparte y el navegador no puede leerla (solo escribirla). «Probar» marca el proxy como sin comprobar y **el motor** lo prueba en su siguiente ciclo (latencia y país de salida; `PROXY_TEST_URL`, por defecto ipinfo.io). El mensaje de error nunca incluye usuario ni clave.
- **Asignaciones**: por país o por canal; se usa el más específico (fuente > canal > país).
- Ambas funciones son de Pro (`max_agents`, `max_proxies`); en Gratis el panel lo explica y bloquea crear.

## Logros y Multivista (UI-6)
- **Logros** (clic en la ficha de plan/nivel): nivel y XP con la barra hacia el siguiente, misiones con su progreso, insignias (las ocultas solo salen al ganarlas), lo que desbloquea cada nivel, los últimos puntos y el ranking. El ranking es opt-in: solo aparece quien elige un alias; se muestra alias, nivel y XP. El XP no tiene valor en dinero.
- **Multivista**: 1, 2 o 4 canales (uno solo, lado a lado, cuadrícula, imagen en imagen, uno grande + tres). El máximo lo da `multiview_slots` de tu plan (se aplica también en la base). Solo un cuadro tiene audio. Cada cuadro intenta reproducir directo y, si el origen no lo permite, usa el proxy de sesión del Worker (≤ 90 s). Se pueden guardar, cargar y borrar distribuciones.

## Guía de programación (UI-7)
En «Obtener lista» hay una sección **Guía de programación (EPG)**: agrega una o varias URL XMLTV, pulsa «Actualizar guía ahora» y el motor arma la guía solo con tus canales (se rearma sola cada 12 h). Muestra el estado (sin leer, generando, lista con canales y programas, o el error con una explicación clara) y el enlace `Guía (EPG)` para pegar en el reproductor.

## Salud de la lista (UI-8)
Botón **Salud**: puntaje 0–100 de la lista (40 % canales que funcionan, 15 % cada uno: logos, guía, respaldos y categorías), los 10 canales que más fallan en 14 días y, al elegir uno, el mapa de calor de sus últimos 90 días (verde casi siempre, amarillo a ratos, rojo caído, gris sin pruebas). Los días de historia los limita `history_days` del plan.

## Paleta ⌘K y PWA (UI-9)
- **Paleta**: `Ctrl/⌘ + K` abre un buscador de acciones (nuevo canal, importar, obtener enlace, sincronizar, Salud, Hospital, Multivista, Conexiones, Comunidad, Logros, filtros, salir) y de canales (Editar / Ver). Funciona con flechas y Enter, y busca sin importar acentos.
- **PWA**: `manifest.webmanifest`, íconos y `sw.js`. El service worker guarda SOLO el cascarón estático del mismo origen (el panel abre rápido y sin conexión); nunca toca Supabase, el Worker ni el video. Sin conexión se ve el panel, pero los datos requieren red. Solo se registra en producción.

## Resolvedor por fuente (UI-10)
En el editor de canal, «Opciones avanzadas» → **Cómo obtener la URL**: *Directa* o *Buscar el .m3u8 dentro de una página web* (la URL es una página y el Worker/motor encuentra el enlace fresco cada vez).

## Dónde se valida un canal (UI-11)
Editor de canal → Opciones avanzadas → **¿Desde dónde se valida este canal?**: «Desde cualquier motor» o «Solo desde República Dominicana» (`vantage_required = local-do`). Los motores de otros países (VPS en EE. UU.) omiten esos canales; los valida el agente de tu PC en RD.
