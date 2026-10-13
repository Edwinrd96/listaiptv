# Mapa UI → Datos/API (qué respalda cada pantalla)

## 1. Layout global
| Elemento | Respaldo |
|---|---|
| Dark mode por defecto | solo frontend (`class="dark"` + tokens shadcn). Preferencia opcional en `profiles` |
| Sidebar (PC) / Bottom tabs (móvil) | solo frontend; secciones: Canales · Categorías · EPG · Listas de salida · Ajustes |
| Buscador global (⌘K) | filtro en memoria sobre `v_channels_table`; > 5 000 filas: `search_text` con trigram |
| Punto verde/rojo del Worker | `GET /health` cada 30 s (rojo si falla o tarda > 3 s). Dos puntos más: Base de datos y Motor (`GET /api/status`) |

## 2. Tabla principal (PC) / Tarjetas (móvil)
| Columna | Campo |
|---|---|
| Logo (hover → tarjeta grande) | `logo_url` · `HoverCard` con la imagen a 256 px sobre fondo oscuro. Si `logo_status='mixed_content'`/`broken` usa `/api/logo` |
| Nombre | `name` |
| Categoría | `group_name` |
| EPG ID | `epg_id` (insignia ámbar si vacío) |
| Catchup Sí/No | `catchup_enabled` |
| Semáforo | `health`: **ok** verde · **warn** amarillo (1–2 strikes, o usando la alterna) · **down** rojo (3 strikes / todo caído) · **unverified** gris · **unknown** punto vacío · **unchecked** guion. Tooltip: `strikes/strikes_to_down`, latencia, último chequeo, `quality.height` |

## 3. Modal Nuevo/Editar (campos por renglón)
| Campo | Respaldo |
|---|---|
| Nombre · Categoría (dropdown, crear al vuelo) | `channels.name`, `groups` |
| Logo URL + cuadro reactivo | Primero `new Image()` (instantáneo). Si falla y es `http` o hotlink → `POST /api/validate/logo` para el motivo exacto. Guarda `logo_status` |
| EPG ID (autocompletar) | `rpc('search_epg')` |
| URL principal / URL alternativa | `channel_sources` prioridad 0 / 1, con botón **Probar** (`/api/probe`) y **▶** (reproductor) junto a cada una |
| Toggle Catchup | `catchup_enabled`; al activarlo aparece **Avanzado**: tipo (`append/default/shift/flussonic/xc`), plantilla `catchup_source`, `catchup_days` (la M3U los necesita) |
| **Avanzado (nuevo, necesario)** | Referer y User-Agent por fuente; «No validar este canal» (`check_enabled`); número de canal `chno` |
| Guardado | `insert/update` directo; la base sube `version` y el enlace público se actualiza solo |

## 4. Reproductor flotante (hls.js)
Panel redimensionable/arrastrable (en móvil: hoja inferior). Play/Pause, volumen, estadísticas (nivel, bitrate, buffer, frames perdidos). Fuente: fila de la tabla (`source_id`) **o** los campos aún sin guardar del modal (`url/referer/ua`). Modos y límites: ver `API.md §E`.

## 5. Controles maestros y consola
| Elemento | Respaldo |
|---|---|
| «Forzar sincronización» | `rpc('request_sync')` (dedupe: 50 clics = 1 trabajo). Estados del botón desde `sync_jobs` por Realtime: En cola → En curso (n/N) → Hecho / Falló |
| Consola | `engine_logs` por Realtime. Colores por `level`. Filtros: nivel, canal. «Copiar» y «Descargar» |
| Líneas de ejemplo | `Strike 2/3 aplicado a Telemicro Canal 5 · HTTP 404` · `Telesistema marcado como CAÍDO (strike 3/3)` · `Orbe 21 recuperado` · `Sincronización terminada · archivo M3U republicado` |

## Extras recomendados (ya contemplados en la base)
1. **Acciones masivas**: seleccionar filas → mover de categoría, activar/desactivar, re-probar, borrar.
2. **Detector de duplicados** (misma URL o nombre normalizado) con «fusionar como alterna».
3. **Deshacer / historial** por canal (`channel_revisions`).
4. **Enlaces de salida por dispositivo** (`outputs`): uno para TiviMate, otro «solo Noticias», otro VLC; cada uno revocable.
5. **Cobertura EPG** (% con guía) y filtro «sin guía».
6. **Notificaciones** configurables (`notification_targets`: Telegram, webhook).
7. **Importador/explorador** de listas externas con vista previa y sondeo antes de agregar.
8. **PWA instalable** y paleta de comandos (⌘K) con acciones.
9. **Insignias de calidad** (720p/1080p) tomadas de `source_health.quality`.
