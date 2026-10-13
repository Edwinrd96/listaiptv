import type { Env, PlayCandidate } from '../types';
import { resolveDm } from '../dm';
import { HttpError, assertPublicUrl, readLimited, safeFetch } from '../util';

/** Enrutador de resolvedores. Cada candidato elige uno (columna `resolver`; si falta, se deduce de `kind`).
 *  Capacidades: redirect = el Worker entrega una URL fresca · proxy_required = solo por proxy de sesión · engine_only = solo el motor (se salta). */
export type Capability = 'redirect' | 'proxy_required' | 'engine_only';
export interface ResolveCtx { env: Env; requestUrl: string; exec?: { waitUntil(p: Promise<unknown>): void } }
export interface Resolved { url: string; via: string }
export interface Resolver { key: string; capability: Capability; resolve(c: PlayCandidate, x: ResolveCtx): Promise<Resolved> }

export const GENERIC_TTL_MS = 3 * 60 * 1000;
export const GENERIC_NEG_MS = 15 * 1000;
const PAGE_MAX = 1_000_000;
const gMem = new Map<string, { url: string; at: number }>();
const gFail = new Map<string, number>();
const gInflight = new Map<string, Promise<string>>();
export function _resetGeneric() { gMem.clear(); gFail.clear(); gInflight.clear(); }

/** Busca el primer .m3u8 de una página (HTML o JSON, incluso con barras escapadas). */
export function findM3u8(text: string, base: string): string | null {
  const t = text.replace(/\\u0026/g, '&').replace(/\\\//g, '/').replace(/&amp;/g, '&');
  const re = /(?:https?:)?\/\/[^\s"'<>\\)]+?\.m3u8(?:\?[^\s"'<>\\)]*)?|["'(]((?:\.{0,2}\/)?[A-Za-z0-9_\-./]+\.m3u8(?:\?[^\s"'<>\\)]*)?)["')]/gi;
  for (const m of t.matchAll(re)) {
    const raw = m[1] ?? m[0];
    try { const u = new URL(raw.startsWith('//') ? 'https:' + raw : raw, base); if (u.protocol === 'https:' || u.protocol === 'http:') return u.toString(); } catch { /* siguiente */ }
  }
  return null;
}

async function genericResolve(c: PlayCandidate, x: ResolveCtx): Promise<Resolved> {
  const page = c.resolve_ref || c.url;
  const key = page; const now = Date.now();
  const m = gMem.get(key);
  if (m && now - m.at < GENERIC_TTL_MS) return { url: m.url, via: 'memoria' };
  const stale = m && now - m.at < 5 * GENERIC_TTL_MS ? m : null;
  if (!stale && gFail.has(key) && now - gFail.get(key)! < GENERIC_NEG_MS) throw new HttpError(502, 'resolver_failed', 'Página sin stream (espera 15 s)');
  let p = gInflight.get(key);
  if (!p) {
    p = (async () => {
      try {
        const headers: Record<string, string> = { 'User-Agent': c.ua ?? 'Mozilla/5.0', Accept: 'text/html,application/json,*/*' };
        if (c.referer) headers.Referer = c.referer;
        const { res, finalUrl, done } = await safeFetch(page, x.env, { headers, timeoutMs: 6000 });
        let body: Uint8Array; try { if (!res.ok) throw new HttpError(502, 'resolver_failed', 'Página HTTP ' + res.status); body = await readLimited(res, PAGE_MAX); } finally { done(); }
        const found = findM3u8(new TextDecoder().decode(body), finalUrl);
        if (!found) throw new HttpError(502, 'resolver_failed', 'No se encontró ningún .m3u8 en la página');
        assertPublicUrl(found, x.env);
        gMem.set(key, { url: found, at: Date.now() }); gFail.delete(key);
        return found;
      } catch (e) { gFail.set(key, Date.now()); throw e; } finally { gInflight.delete(key); }
    })();
    gInflight.set(key, p);
  }
  try { return { url: await p, via: 'origen' }; } catch (e) { if (stale) return { url: stale.url, via: 'stale' }; throw e; }
}

export const RESOLVERS: Record<string, Resolver> = {
  direct: { key: 'direct', capability: 'redirect', resolve: async (c) => ({ url: c.url, via: 'directo' }) },
  dailymotion: {
    key: 'dailymotion', capability: 'redirect',
    async resolve(c, x) {
      const id = (c.resolve_ref ?? '').match(/^dm:(\w+)$/)?.[1];
      if (!id) throw new HttpError(400, 'bad_ref', 'Referencia de Dailymotion inválida');
      return resolveDm(id, x.requestUrl, x.exec);
    },
  },
  generic: { key: 'generic', capability: 'redirect', resolve: genericResolve },
  youtube: { key: 'youtube', capability: 'engine_only', resolve: async () => { throw new HttpError(409, 'engine_only', 'YouTube solo lo resuelve el motor'); } },
  azteca_akamai: { key: 'azteca_akamai', capability: 'proxy_required', resolve: async () => { throw new HttpError(409, 'proxy_required', 'Requiere proxy'); } },
};

/** Qué resolvedor le toca a una fuente. */
export function resolverKey(c: Pick<PlayCandidate, 'resolver' | 'kind'>): string {
  if (c.resolver && RESOLVERS[c.resolver]) return c.resolver;
  if (c.kind === 'dailymotion') return 'dailymotion';
  if (c.kind === 'youtube') return 'youtube';
  return 'direct';
}

/** Redirección para /p/:token/play: devuelve la URL fresca o null si este candidato no se puede entregar por redirección. */
export async function resolveForRedirect(c: PlayCandidate, x: ResolveCtx, disabled: ReadonlySet<string> = new Set()): Promise<Resolved | null> {
  const k = resolverKey(c);
  if (disabled.has(k)) return null;
  const r = RESOLVERS[k];
  if (r.capability !== 'redirect') return null;
  return r.resolve(c, x);
}

/** Para el proxy de sesión y las pruebas: igual que arriba, pero `proxy_required` sí vale (se entrega por proxy). */
export async function resolveForProxy(c: PlayCandidate, x: ResolveCtx): Promise<Resolved | null> {
  const r = RESOLVERS[resolverKey(c)];
  if (r.capability === 'engine_only') return null;
  if (r.key === 'azteca_akamai') return { url: c.url, via: 'directo' };
  return r.resolve(c, x);
}
