import type { Env } from './types';
import { HttpError, SMART_TV_UAS, headersFor, readLimited, safeFetch } from './util';

export interface Variant { height: number | null; bandwidth: number | null; codecs: string | null }
export interface ProbeResult {
  ok: boolean; http: number | null; latency_ms: number; variants: Variant[]; segment_ok: boolean;
  error: string | null; hint: string | null; ua_used: string | null; url_used: string;
}

const dec = new TextDecoder();
const isDead = (e: string | null) => !!e && /HTTP (404|410)\b/.test(e);

export function parseVariants(txt: string): { variants: Variant[]; uris: string[] } {
  const lines = txt.split('\n').map((l) => l.trim()); const variants: Variant[] = []; const uris: string[] = [];
  lines.forEach((l, i) => {
    if (!l.startsWith('#EXT-X-STREAM-INF')) return;
    const res = l.match(/RESOLUTION=(\d+)x(\d+)/); const bw = l.match(/BANDWIDTH=(\d+)/); const cd = l.match(/CODECS="([^"]+)"/);
    variants.push({ height: res ? Number(res[2]) : null, bandwidth: bw ? Number(bw[1]) : null, codecs: cd ? cd[1] : null });
    const next = lines.slice(i + 1).find((x) => x && !x.startsWith('#'));
    if (next) uris.push(next);
  });
  return { variants, uris };
}

export function hintFor(error: string | null, url: string): string | null {
  if (!error) return null;
  if (/HTTP (401|403)/.test(error)) return 'El origen rechaza la petición: revisa el Referer y el User-Agent (o puede estar geobloqueado).';
  if (isDead(error)) return 'URL caducada o inexistente: busca el enlace maestro (playlist/master/index.m3u8) o una URL nueva.';
  if (/timeout|Timeout/i.test(error)) return 'Sin respuesta a tiempo: servidor lento, caído o bloqueado desde esta región.';
  if (/no es m3u8/.test(error)) return 'La URL responde, pero no es una lista HLS (¿página web de bloqueo?).';
  if (url.startsWith('http://')) return 'Es http://; algunos reproductores modernos lo bloquean. Prueba la versión https si existe.';
  return null;
}

async function attempt(env: Env, url: string, headers: Record<string, string>, budgetMs: number) {
  const t0 = Date.now(); const deadline = t0 + budgetMs;
  const left = () => Math.max(300, deadline - Date.now());
  let variants: Variant[] = []; let http: number | null = null;
  const get = async (u: string, h: Record<string, string>, max: number) => {
    const { res, finalUrl, done } = await safeFetch(u, env, { headers: h, timeoutMs: left() });
    try {
      http = res.status;
      if (res.status !== 200 && res.status !== 206) { res.body?.cancel().catch(() => {}); return { status: res.status, body: '', finalUrl }; }
      return { status: res.status, body: dec.decode(await readLimited(res, max)), finalUrl };
    } finally { done(); }
  };
  try {
    let cur = await get(url, headers, 300_000);
    if (cur.status !== 200) return { ok: false, http: cur.status, error: `HTTP ${cur.status}`, variants, segment_ok: false, ms: Date.now() - t0 };
    if (!cur.body.slice(0, 100).includes('#EXTM3U')) return { ok: false, http: 200, error: 'no es m3u8', variants, segment_ok: false, ms: Date.now() - t0 };
    for (let hop = 0; hop < 3; hop++) {
      const { variants: v, uris } = parseVariants(cur.body);
      if (v.length && !variants.length) variants = v;
      const items = cur.body.split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
      if (!items.length) return { ok: false, http: 200, error: 'manifiesto vacío', variants, segment_ok: false, ms: Date.now() - t0 };
      const next = new URL(uris[0] ?? items[0], cur.finalUrl).toString();
      if (new URL(next).pathname.includes('.m3u8')) {
        cur = await get(next, headers, 300_000);
        if (cur.status !== 200) return { ok: false, http: cur.status, error: `sub-manifiesto HTTP ${cur.status}`, variants, segment_ok: false, ms: Date.now() - t0 };
        continue;
      }
      const seg = await get(next, { ...headers, Range: 'bytes=0-1023' }, 1024);
      const ok = seg.status === 200 || seg.status === 206;
      return { ok, http: seg.status, error: ok ? null : `segmento HTTP ${seg.status}`, variants, segment_ok: ok, ms: Date.now() - t0 };
    }
    return { ok: true, http, error: null, variants, segment_ok: false, ms: Date.now() - t0 };
  } catch (e: any) {
    return { ok: false, http, error: e instanceof HttpError ? (e.code === 'timeout' ? 'Timeout' : e.message) : (e?.name ?? 'Error'), variants, segment_ok: false, ms: Date.now() - t0 };
  }
}

/** Sondeo con tiempo máximo por intento (5 s) y rotación de 3 User-Agents de Smart TV si el origen rechaza. */
export async function probeStream(env: Env, input: { url: string; referer?: string | null; ua?: string | null }, o: { timeoutMs?: number; budgetMs?: number; rotate?: boolean } = {}): Promise<ProbeResult> {
  const per = o.timeoutMs ?? 5000; const t0 = Date.now(); const budget = o.budgetMs ?? 15000;
  const base = headersFor(input.referer, input.ua);
  let r = await attempt(env, input.url, base, per); let uaUsed: string | null = null;
  if (!r.ok && o.rotate !== false && !isDead(r.error)) {
    for (const ua of SMART_TV_UAS) {
      if (Date.now() - t0 > budget - 1000) break;
      const r2 = await attempt(env, input.url, { ...base, 'User-Agent': ua }, per);
      if (r2.ok) { r = r2; uaUsed = ua; break; }
    }
  }
  return { ok: r.ok, http: r.http, latency_ms: r.ms, variants: r.variants, segment_ok: r.segment_ok, error: r.error,
           hint: hintFor(r.error, input.url), ua_used: uaUsed, url_used: input.url };
}

export function qualityOf(r: ProbeResult): Record<string, unknown> | null {
  const heights = r.variants.map((v) => v.height).filter((h): h is number => !!h);
  if (!r.variants.length) return null;
  return { height: heights.length ? Math.max(...heights) : null, bandwidth: Math.max(...r.variants.map((v) => v.bandwidth ?? 0)) || null,
           codecs: r.variants.find((v) => v.codecs)?.codecs ?? null, variants: r.variants.length };
}
