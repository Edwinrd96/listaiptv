# Cómo funciona (igual que siempre)

1. Tu lista sigue siendo UN archivo: `dist/iptv.m3u`, guardado en GitHub.
2. Su enlace es fijo:
   https://raw.githubusercontent.com/TU_USUARIO/iptv-rd/main/dist/iptv.m3u
3. Ese enlace lo pegas UNA vez en TiviMate / OTT Navigator / Smarters / Kodi.
4. GitHub (gratis) revisa los canales cada 2 horas, repara los enlaces caídos y reescribe
   ese mismo archivo. Tu reproductor actualiza solo; tú no haces nada.
   (VLC: usa `dist/iptv_vlc.m3u`.)

# Instalación (una sola vez)
1. github.com -> crear cuenta -> New repository -> nombre `iptv-rd` -> Public.
2. "uploading an existing file" -> sube TODO el contenido de esta carpeta (incluida `.github`).
   Si el móvil no deja subir carpetas ocultas: crea en GitHub el archivo
   `.github/workflows/iptv.yml` y pega el contenido.
3. Settings -> Actions -> General -> Workflow permissions -> "Read and write" -> Save.
4. Pestaña Actions -> "IPTV auto-mantenimiento" -> Run workflow. Espera 2-5 min.
5. Abre `dist/iptv.m3u` -> botón Raw -> copia ese enlace -> pégalo en tu reproductor.
6. En `channels.yaml` pon en `epg_public_url` la URL raw de `dist/epg.xml.gz`.

# Día a día
- Añadir un canal: edita `channels.yaml` en GitHub (lápiz), añade una línea, guarda. Se regenera solo.
- Ver qué está caído: abre `dist/ESTADO.md`.
- Canal con URL que caduca (Dailymotion/YouTube): añade `"resolve":"https://página-del-canal"`.
  El sistema saca el enlace fresco en cada revisión.

# Enlaces con token (Dailymotion) - solución definitiva, gratis
Problema: Color Visión, Tele Antillas y Telesistema usan enlaces con token que caducan. Aunque
GitHub los renueve cada 2 h, tu app puede tener guardada la lista vieja.
Solución: un "Worker" de Cloudflare que pide el token fresco justo cuando pulsas play.

1. cloudflare.com -> cuenta gratis -> Workers & Pages -> Create -> "Hello World" -> Deploy.
2. Edit code -> borra todo y pega el contenido de `worker/worker.js` -> Deploy.
3. Copia la dirección: https://algo.tu-usuario.workers.dev
   Ábrela en el navegador: debe decir "IPTV resolver OK".
4. En `channels.yaml` pon:  worker_url: "https://algo.tu-usuario.workers.dev"
   (solo DESPUÉS de comprobar el paso 3).
5. Listo: esos canales usan .../dm/ID y nunca caducan. El ID se saca solo de la URL actual.

# Cómo se evitan las caídas (resumen)
- `python iptv.py audit` detecta URLs con token/sesión.
- Dailymotion: token fresco por API en cada revisión (y en cada play con el Worker).
- chunklist_*: se convierte automáticamente a playlist/index/master si existe.
- Cada canal se prueba 2 veces antes de contar un fallo; se marca caído tras 3 fallos seguidos.
- Para respaldo: añade "alt": ["url2","url3"] a cualquier canal; usa la primera que responda.
- YouTube: ver nota en el chat (las URLs de YouTube van atadas a la IP).
