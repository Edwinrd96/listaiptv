import type { Env } from './types';
import { DEFAULT_UA } from './util';

// Resolvedor Dailymotion con caché anti-ban: memoria + Cache API + UNA sola petición simultánea + modo "stale".
export const TTL_MS = 3 * 60 * 1000;
export const STALE_MS = 15 * 60 * 1000;
export const NEG_MS = 15 * 1000;

const mem = new Map<string, { url: string; at: number }>();
const inflight = new Map<string, Promise<string>>();
const failedAt = new Map<string, number>();
export const DM_API = { base: 'https://www.dailymotion.com/player/metadata/video/' };   // sustituible en pruebas
export function _resetDm() { mem.clear(); inflight.clear(); failedAt.clear(); }

async function fromOrigin(id: string): Promise<string> {
  const res = await fetch(`${DM_API.base}${id}?embedder=${encodeURIComponent('https://www.dailymotion.com/')}`, {
    headers: { 'User-Agent': DEFAULT_UA, Referer: 'https://www.dailymotion.com/' },
    cf: { cacheTtl: 120, cacheEverything: true },
  } as RequestInit);
  if (!res.ok) throw new Error('origen HTTP ' + res.status);
  const j: any = await res.json();
  const url = j?.qualities?.auto?.[0]?.url;
  if (!url) throw new Error('sin stream (canal offline)');
  return url;
}

export async function resolveDm(id: string, requestUrl: string, ctx?: { waitUntil(p: Promise<unknown>): void }): Promise<{ url: string; via: string }> {
  const t = Date.now();
  const m = mem.get(id);
  if (m && t - m.at < TTL_MS) return { url: m.url, via: 'memoria' };
  const cache = typeof caches !== 'undefined' ? (caches as any).default as Cache | undefined : undefined;
  const key = new Request(new URL(`/__cache/dm/${id}`, requestUrl).toString());
  if (cache) {
    try {
      const hit = await cache.match(key);
      if (hit) { const rec: any = await hit.json(); if (t - rec.at < TTL_MS) { mem.set(id, rec); return { url: rec.url, via: 'cache' }; } }
    } catch { /* Cache API no disponible */ }
  }
  const stale = m && t - m.at < STALE_MS ? m : null;
  if (!stale && failedAt.has(id) && t - failedAt.get(id)! < NEG_MS) throw new Error('origen caído (espera 15 s)');
  let p = inflight.get(id);
  if (!p) {
    p = (async () => {
      try {
        const url = await fromOrigin(id);
        const rec = { url, at: Date.now() };
        mem.set(id, rec); failedAt.delete(id);
        if (cache) {
          const put = cache.put(key, new Response(JSON.stringify(rec), { headers: { 'Content-Type': 'application/json', 'Cache-Control': `public, max-age=${TTL_MS / 1000}` } })).catch(() => {});
          ctx?.waitUntil(put);
        }
        return url;
      } catch (e) { failedAt.set(id, Date.now()); throw e; } finally { inflight.delete(id); }
    })();
    inflight.set(id, p);
  }
  try { return { url: await p, via: 'origen' }; } catch (e) { if (stale) return { url: stale.url, via: 'stale' }; throw e; }
}
