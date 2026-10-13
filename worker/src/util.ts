import type { Env } from './types';

export class HttpError extends Error {
  constructor(public status: number, public code: string, message: string, public retryAfter?: number) { super(message); }
}

// ------------------------------------------------------------------ SSRF
const BLOCKED_PORTS = new Set([22, 23, 25, 110, 143, 1433, 1521, 2375, 2376, 3306, 5432, 5984, 6379, 9200, 11211, 27017]);

function ipv4ToParts(h: string): number[] | null {
  const m = h.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  return m ? m.slice(1).map(Number) : null;
}

export function isPrivateHost(host: string): boolean {
  const h = host.toLowerCase().replace(/^\[|\]$/g, '');
  if (h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.local') || h.endsWith('.internal') || h.endsWith('.lan')) return true;
  const p = ipv4ToParts(h);
  if (p) {
    const [a, b] = p;
    return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224;
  }
  if (h.includes(':')) return h === '::1' || h === '::' || h.startsWith('fc') || h.startsWith('fd') || h.startsWith('fe80') || h.startsWith('::ffff:');
  return !h.includes('.');                      // nombres sin punto (intranet)
}

/** Valida que la URL sea http(s) pública y de un puerto razonable. Lanza HttpError 400 si no. */
export function assertPublicUrl(raw: string, env: Pick<Env, 'ALLOW_PRIVATE_HOSTS'>): URL {
  let u: URL;
  try { u = new URL(raw); } catch { throw new HttpError(400, 'bad_url', 'URL inválida'); }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new HttpError(400, 'bad_url', 'Solo http/https');
  if (u.username || u.password) throw new HttpError(400, 'bad_url', 'La URL no puede llevar usuario:clave');
  // La dirección de metadatos de la nube (169.254.x.x) se bloquea SIEMPRE, incluso en modo desarrollo.
  if (/^169\.254\.\d+\.\d+$/.test(u.hostname)) throw new HttpError(400, 'blocked_host', 'Host no permitido');
  if (env.ALLOW_PRIVATE_HOSTS === '1') return u;
  if (isPrivateHost(u.hostname)) throw new HttpError(400, 'blocked_host', 'Host no permitido');
  const port = u.port ? Number(u.port) : (u.protocol === 'https:' ? 443 : 80);
  if (!(port === 80 || port === 443 || (port >= 1024 && port <= 65535)) || BLOCKED_PORTS.has(port)) {
    throw new HttpError(400, 'blocked_port', 'Puerto no permitido');
  }
  return u;
}

export interface SafeFetchOpts { headers?: Record<string, string>; timeoutMs?: number; maxRedirects?: number; method?: string }

/** fetch con tiempo máximo TOTAL, redirecciones manuales (revalidadas) y SSRF. */
export async function safeFetch(raw: string, env: Pick<Env, 'ALLOW_PRIVATE_HOSTS'>, o: SafeFetchOpts = {}): Promise<{ res: Response; finalUrl: string; done: () => void }> {
  const deadline = Date.now() + (o.timeoutMs ?? 5000);
  let url = assertPublicUrl(raw, env).toString();
  for (let hop = 0; hop <= (o.maxRedirects ?? 3); hop++) {
    const left = deadline - Date.now();
    if (left <= 0) throw new HttpError(504, 'timeout', 'Timeout');
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), left);
    try {
      const res = await fetch(url, { method: o.method ?? 'GET', headers: o.headers, redirect: 'manual', signal: ac.signal });
      if (res.status >= 300 && res.status < 400 && res.headers.get('location')) {
        res.body?.cancel().catch(() => {});
        url = assertPublicUrl(new URL(res.headers.get('location')!, url).toString(), env).toString();
        clearTimeout(timer);
        continue;
      }
      return { res, finalUrl: url, done: () => clearTimeout(timer) };   // el llamador limpia el temporizador al terminar de leer
    } catch (e: any) {
      clearTimeout(timer);
      if (e instanceof HttpError) throw e;
      throw new HttpError(504, e?.name === 'AbortError' ? 'timeout' : 'fetch_failed', e?.name === 'AbortError' ? 'Timeout' : (e?.message ?? 'Error de red'));
    }
  }
  throw new HttpError(502, 'too_many_redirects', 'Demasiadas redirecciones');
}

/** Lee como mucho `max` bytes del cuerpo. */
export async function readLimited(res: Response, max: number): Promise<Uint8Array> {
  if (!res.body) return new Uint8Array();
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = []; let total = 0;
  while (total < max) {
    const { done, value } = await reader.read();
    if (done || !value) break;
    chunks.push(value); total += value.length;
  }
  reader.cancel().catch(() => {});
  const out = new Uint8Array(Math.min(total, max)); let off = 0;
  for (const c of chunks) { const take = Math.min(c.length, out.length - off); out.set(c.subarray(0, take), off); off += take; if (off >= out.length) break; }
  return out;
}

// ------------------------------------------------------------------ firmas (HMAC-SHA256, base64url)
const enc = new TextEncoder();
const b64u = (b: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(b as ArrayBuffer))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));

async function hmacKey(secret: string) {
  return crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
}
export async function sign(secret: string, data: string): Promise<string> {
  return b64u(await crypto.subtle.sign('HMAC', await hmacKey(secret), enc.encode(data)));
}
export async function verifySig(secret: string, data: string, sig: string): Promise<boolean> {
  try { return await crypto.subtle.verify('HMAC', await hmacKey(secret), unb64u(sig), enc.encode(data)); } catch { return false; }
}
export async function makeToken(secret: string, payload: object): Promise<string> {
  const body = b64u(enc.encode(JSON.stringify(payload)));
  return `${body}.${await sign(secret, body)}`;
}
export async function readToken<T = any>(secret: string, token: string): Promise<T | null> {
  const [body, sig] = token.split('.');
  if (!body || !sig || !(await verifySig(secret, body, sig))) return null;
  try { return JSON.parse(new TextDecoder().decode(unb64u(body))) as T; } catch { return null; }
}

// ------------------------------------------------------------------ límite de uso (por aislado; ver nota en API.md)
const buckets = new Map<string, number[]>();
export function rateLimit(key: string, limit: number, windowMs: number): { ok: boolean; retryAfter: number } {
  const now = Date.now();
  const arr = (buckets.get(key) ?? []).filter((t) => now - t < windowMs);
  if (arr.length >= limit) { buckets.set(key, arr); return { ok: false, retryAfter: Math.ceil((windowMs - (now - arr[0])) / 1000) }; }
  arr.push(now); buckets.set(key, arr);
  if (buckets.size > 5000) for (const k of buckets.keys()) { if (!(buckets.get(k)?.length)) buckets.delete(k); }
  return { ok: true, retryAfter: 0 };
}
export function _resetRateLimits() { buckets.clear(); }

export const SMART_TV_UAS = [
  'Mozilla/5.0 (SMART-TV; LINUX; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) 85.0.4183.93/6.5 TV Safari/537.36',
  'Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.128 Safari/537.36 WebAppManager',
  'Mozilla/5.0 (Linux; Android 11; BRAVIA 4K GB) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36',
];
export const DEFAULT_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

export function headersFor(referer?: string | null, ua?: string | null): Record<string, string> {
  const h: Record<string, string> = { 'User-Agent': ua || DEFAULT_UA };
  if (referer) { h['Referer'] = referer; try { h['Origin'] = new URL(referer).origin; } catch { /* referer inválido */ } }
  return h;
}
