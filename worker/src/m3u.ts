import type { Payload, PayloadChannel } from './types';

/** Equivalente a Python quote(v, safe=":/.-_~"): lo que esperan TiviMate / Kodi / OTT Navigator en |headers */
export function encHeader(v: string): string {
  return encodeURIComponent(v).replace(/%3A/gi, ':').replace(/%2F/gi, '/').replace(/[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());
}
const esc = (v?: string | null) => (v ?? '').replace(/"/g, "'").replace(/[\r\n]+/g, ' ');

function dmId(ch: PayloadChannel): string | null {
  const s = ch.source;
  if (s.kind !== 'dailymotion') return null;
  const m = (s.resolve_ref ?? '').match(/^dm:(\w+)$/);
  return m ? m[1] : null;
}

export interface RenderOpts { vlc: boolean; origin: string; epgUrl?: string; token?: string }

/** Cabeceras finales de una fuente: UA explícito > perfil > UA de la lista; luego Referer/Origin; luego extra_headers (gana lo más específico). */
export function headersOf(ch: PayloadChannel, defUa: string): Record<string, string> {
  const s = ch.source; const hdr: Record<string, string> = {};
  const ua = s.ua || s.profile?.ua || defUa;
  if (ua) hdr['User-Agent'] = ua;
  for (const [k, v] of Object.entries(s.profile?.headers ?? {})) if (k.toLowerCase() !== 'user-agent') hdr[k] = v;
  if (s.referer) {
    hdr['Referer'] = s.referer;
    try { hdr['Origin'] = new URL(s.referer).origin; } catch { /* referer inválido */ }
  }
  for (const [k, v] of Object.entries(s.extra_headers ?? {})) if (typeof v === 'string' && !/[\r\n]/.test(v)) hdr[k] = v;
  return hdr;
}

/** Líneas #KODIPROP para DRM (Kodi inputstream.adaptive / OTT Navigator). ClearKey, Widevine. */
export function drmLines(ch: PayloadChannel): string[] {
  const d = ch.source.drm; if (!d) return [];
  const out = ['#KODIPROP:inputstream=inputstream.adaptive'];
  const fmt = ch.source.stream_format;
  if (fmt === 'dash' || /\.mpd(\?|$)/i.test(ch.source.url)) out.push('#KODIPROP:inputstream.adaptive.manifest_type=mpd');
  else if (fmt === 'hls') out.push('#KODIPROP:inputstream.adaptive.manifest_type=hls');
  if (d.type === 'clearkey') {
    out.push('#KODIPROP:inputstream.adaptive.license_type=clearkey');
    out.push(`#KODIPROP:inputstream.adaptive.license_key=${d.keys ?? d.license_url ?? ''}`);
  } else if (d.type === 'widevine') {
    out.push('#KODIPROP:inputstream.adaptive.license_type=com.widevine.alpha');
    out.push(`#KODIPROP:inputstream.adaptive.license_key=${d.license_url ?? ''}||R{SSM}|`);
  } else if (d.type === 'playready') {
    out.push('#KODIPROP:inputstream.adaptive.license_type=com.microsoft.playready');
    out.push(`#KODIPROP:inputstream.adaptive.license_key=${d.license_url ?? ''}`);
  }
  return out;
}

/** URL que ve el reproductor: Dailymotion -> /dm; entrega inteligente -> /p/<token>/play/<tvg_id>; si no, la URL directa. */
function urlFor(ch: PayloadChannel, o: RenderOpts, smart: boolean): { url: string; viaWorker: boolean } {
  const id = dmId(ch);
  if (id) return { url: `${o.origin}/dm/${id}.m3u8`, viaWorker: true };
  if (smart && o.token && !ch.source.drm) return { url: `${o.origin}/p/${o.token}/play/${encodeURIComponent(ch.tvg_id)}`, viaWorker: true };
  return { url: ch.source.url, viaWorker: false };
}

export function renderM3U(p: Payload, o: RenderOpts): string {
  const defUa: string = p.playlist.settings?.ua ?? '';
  const encode = p.playlist.settings?.encode_headers !== false;
  const smart = p.output.delivery === 'smart';
  const out: string[] = [o.epgUrl ? `#EXTM3U x-tvg-url="${o.epgUrl}"` : '#EXTM3U', ''];
  for (const ch of p.channels) {
    const at = [`tvg-id="${esc(ch.tvg_id)}"`, `tvg-name="${esc(ch.name)}"`, `tvg-logo="${esc(ch.logo)}"`];
    if (ch.chno) at.push(`tvg-chno="${ch.chno}"`);
    if (ch.lang) at.push(`tvg-language="${esc(ch.lang)}"`);
    at.push(`group-title="${esc(ch.group)}"`);
    if (ch.catchup?.type) {
      at.push(`catchup="${esc(ch.catchup.type)}"`);
      if (ch.catchup.source) at.push(`catchup-source="${esc(ch.catchup.source)}"`);
      if (ch.catchup.days) at.push(`catchup-days="${ch.catchup.days}"`);
    }
    out.push(`#EXTINF:-1 ${at.join(' ')},${esc(ch.name)}`);

    const { url, viaWorker } = urlFor(ch, o, smart);
    // Dailymotion lo resuelve el Worker (sin cabeceras). Con entrega inteligente las cabeceras del principal viajan igual: el reproductor las reutiliza tras el 302.
    const hdr: Record<string, string> = dmId(ch) ? {} : headersOf(ch, defUa);
    if (o.vlc) {
      if (hdr['User-Agent']) out.push(`#EXTVLCOPT:http-user-agent=${hdr['User-Agent']}`);
      if (hdr['Referer']) out.push(`#EXTVLCOPT:http-referrer=${hdr['Referer']}`);
      out.push('#EXTVLCOPT:http-reconnect=true', url);
    } else {
      if (!viaWorker || !dmId(ch)) out.push(...drmLines(ch));
      const parts = Object.entries(hdr).map(([k, v]) => `${k}=${encode ? encHeader(v) : v}`);
      out.push(parts.length ? `${url}|${parts.join('&')}` : url);
    }
    out.push('');
  }
  return out.join('\n');
}

/** TXT estilo "Nombre,URL" agrupado por categoría (formato popular en reproductores chinos / apps simples). */
export function renderTxt(p: Payload, o: RenderOpts): string {
  const smart = p.output.delivery === 'smart'; const lines: string[] = []; let cur: string | null = null;
  for (const ch of p.channels) {
    if (ch.group !== cur) { cur = ch.group; lines.push(`${esc(cur)},#genre#`); }
    lines.push(`${esc(ch.name).replace(/,/g, ' ')},${urlFor(ch, o, smart).url}`);
  }
  return lines.join('\n') + '\n';
}

/** Bouquet Enigma2 (userbouquet): servicio IPTV 4097 con la URL escapada. */
export function renderEnigma2(p: Payload, o: RenderOpts): string {
  const smart = p.output.delivery === 'smart';
  const e = (u: string) => encodeURIComponent(u).replace(/%3A/g, '%3a').replace(/%2F/g, '/');
  const lines = [`#NAME ${esc(p.playlist.name)}`];
  for (const ch of p.channels) {
    lines.push(`#SERVICE 4097:0:1:0:0:0:0:0:0:0:${e(urlFor(ch, o, smart).url)}:${esc(ch.name)}`, `#DESCRIPTION ${esc(ch.name)}`);
  }
  return lines.join('\n') + '\n';
}

export interface ParsedItem { name: string; url: string; logo: string; group: string; epg: string; referer?: string; ua?: string }
export function parseM3U(text: string): ParsedItem[] {
  const out: ParsedItem[] = []; let cur: Partial<ParsedItem> | null = null;
  for (const raw of text.replace(/\r/g, '').split('\n')) {
    const line = raw.trim();
    if (line.startsWith('#EXTINF')) {
      const at: Record<string, string> = {};
      for (const m of line.matchAll(/([\w-]+)="([^"]*)"/g)) at[m[1]] = m[2];
      cur = { name: line.slice(line.lastIndexOf(',') + 1).trim(), logo: at['tvg-logo'] ?? '', group: at['group-title'] ?? '', epg: at['tvg-id'] ?? '' };
    } else if (cur && line.startsWith('#EXTVLCOPT:http-referrer=')) cur.referer = line.split('=').slice(1).join('=');
    else if (cur && line.startsWith('#EXTVLCOPT:http-user-agent=')) cur.ua = line.split('=').slice(1).join('=');
    else if (cur && line && !line.startsWith('#')) {
      const [url, ...h] = line.split('|');
      for (const kv of h.join('|').split('&')) {
        const [k, ...v] = kv.split('=');
        try {
          if (k.toLowerCase() === 'referer') cur.referer = decodeURIComponent(v.join('='));
          if (k.toLowerCase() === 'user-agent') cur.ua = decodeURIComponent(v.join('='));
        } catch { /* valor mal codificado */ }
      }
      out.push({ ...(cur as ParsedItem), url }); cur = null;
    }
  }
  return out;
}
