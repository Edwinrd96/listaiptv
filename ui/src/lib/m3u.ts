/** Lee una lista M3U en el navegador (sin enviarla a ningún servidor). */
export interface ParsedItem { name: string; url: string; logo: string; group: string; tvg_id: string; referer?: string; ua?: string }
export function parseM3U(text: string): ParsedItem[] {
  const out: ParsedItem[] = []; let cur: Partial<ParsedItem> | null = null;
  for (const raw of text.replace(/\r/g, '').split('\n')) {
    const line = raw.trim();
    if (line.startsWith('#EXTINF')) {
      const at: Record<string, string> = {};
      for (const m of line.matchAll(/([\w-]+)="([^"]*)"/g)) at[m[1]] = m[2];
      cur = { name: line.slice(line.lastIndexOf(',') + 1).trim(), logo: at['tvg-logo'] ?? '', group: at['group-title'] ?? '', tvg_id: at['tvg-id'] ?? '' };
    } else if (cur && line.startsWith('#EXTVLCOPT:http-referrer=')) cur.referer = line.split('=').slice(1).join('=');
    else if (cur && line.startsWith('#EXTVLCOPT:http-user-agent=')) cur.ua = line.split('=').slice(1).join('=');
    else if (cur && line && !line.startsWith('#')) {
      const [url, ...h] = line.split('|');
      for (const kv of h.join('|').split('&')) {
        const [k, ...v] = kv.split('=');
        try {
          if (k.toLowerCase() === 'referer') cur.referer = decodeURIComponent(v.join('='));
          if (k.toLowerCase() === 'user-agent') cur.ua = decodeURIComponent(v.join('='));
        } catch { /* valor mal codificado: se ignora */ }
      }
      out.push({ ...(cur as ParsedItem), url }); cur = null;
    }
  }
  return out;
}
