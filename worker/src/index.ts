import { Hono } from 'hono';
import type { Context, MiddlewareHandler } from 'hono';
import type { AppEnv, Env, Payload, PlayCandidates } from './types';
import { requireUser } from './auth';
import { resolveDm } from './dm';
import { resolveForProxy, resolveForRedirect } from './resolvers';
import { parseM3U, renderEnigma2, renderM3U, renderTxt } from './m3u';
import { probeStream, qualityOf } from './probe';
import { rpc, select } from './supa';
import { HttpError, assertPublicUrl, makeToken, rateLimit, readLimited, readToken, safeFetch, sign, verifySig, headersFor } from './util';

const app = new Hono<AppEnv>();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const uuid = (v: unknown, what = 'id'): string => { if (typeof v !== 'string' || !UUID.test(v)) throw new HttpError(400, 'bad_request', `${what} inválido`); return v; };
const ip = (c: Context) => c.req.header('CF-Connecting-IP') ?? 'local';
const originOf = (c: Context) => new URL(c.req.url).origin;
function limit(key: string, n: number, windowSec: number) {
  const r = rateLimit(key, n, windowSec * 1000);
  if (!r.ok) throw new HttpError(429, 'rate_limited', 'Demasiadas peticiones', r.retryAfter);
}
async function body<T = any>(c: Context): Promise<T> {
  try { return (await c.req.json()) as T; } catch { throw new HttpError(400, 'bad_request', 'JSON inválido'); }
}

// ------------------------------------------------------------------ errores y CORS
app.onError((err, c) => {
  if (err instanceof HttpError) {
    if (err.retryAfter) c.header('Retry-After', String(err.retryAfter));
    return c.json({ error: { code: err.code, message: err.message, retry_after: err.retryAfter ?? null } }, err.status as 400);
  }
  console.error('error no controlado', err);
  return c.json({ error: { code: 'internal', message: 'Error interno' } }, 500);
});
app.notFound((c) => c.json({ error: { code: 'not_found', message: 'Ruta no encontrada' } }, 404));

const cors: MiddlewareHandler<AppEnv> = async (c, next) => {
  const origin = c.req.header('Origin');
  const allowed = (c.env.ALLOWED_ORIGINS ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  const ok = !!origin && (allowed.includes(origin) || allowed.includes('*'));
  if (ok) { c.header('Access-Control-Allow-Origin', origin!); c.header('Vary', 'Origin'); }
  if (c.req.method === 'OPTIONS') {
    c.header('Access-Control-Allow-Methods', 'GET,POST,OPTIONS'); c.header('Access-Control-Allow-Headers', 'authorization,content-type');
    c.header('Access-Control-Max-Age', '86400');
    return c.body(null, 204);
  }
  await next();
};
app.use('/api/*', cors);

// ------------------------------------------------------------------ públicas
app.get('/', (c) => c.text('IPTV Engine OK'));
app.get('/health', (c) => {
  c.header('Access-Control-Allow-Origin', '*'); c.header('Cache-Control', 'no-store');
  return c.json({ ok: true, version: '1.0.0', colo: (c.req.raw as any).cf?.colo ?? null, time: new Date().toISOString() });
});

const m3uCache = new Map<string, { text: string; etag: string; at: number }>();
export function _resetM3uCache() { m3uCache.clear(); }
const M3U_TTL = 60_000;

const VARIANT_RE = /^([0-9a-f]{64})(\.vlc\.m3u|\.m3u|\.txt|\.e2)$/;
const CT: Record<string, string> = { m3u: 'audio/mpegurl; charset=utf-8', txt: 'text/plain; charset=utf-8', e2: 'text/plain; charset=utf-8' };

app.get('/p/:file', async (c) => {
  const m = c.req.param('file').match(VARIANT_RE);
  if (!m) throw new HttpError(404, 'not_found', 'Lista no encontrada');
  limit(`m3u:${ip(c)}`, 120, 60);
  const [, token, ext] = m;
  const kind = ext === '.txt' ? 'txt' : ext === '.e2' ? 'e2' : ext === '.vlc.m3u' ? 'vlc' : 'std';
  const key = `${token}|${kind}`;
  let hit = m3uCache.get(key);
  if (!hit || Date.now() - hit.at > M3U_TTL) {
    const payload = await rpc<Payload | null>(c.env, 'get_playlist_payload', { p_token: token }, { service: true });
    if (!payload) throw new HttpError(404, 'not_found', 'Lista no encontrada');
    if ((kind === 'txt' || kind === 'e2') && !payload.output.extra_formats) throw new HttpError(403, 'feature_locked', 'Este formato requiere la función «Formatos extra» de tu plan');
    const origin = originOf(c);
    const o = { vlc: kind === 'vlc' || (kind === 'std' && payload.output.format === 'm3u_vlc'), origin, token, epgUrl: `${origin}/p/${token}/epg.xml.gz` };
    const text = kind === 'txt' ? renderTxt(payload, o) : kind === 'e2' ? renderEnigma2(payload, o) : renderM3U(payload, o);
    hit = { text, etag: `W/"${payload.playlist.version}-${kind}-${payload.output.delivery ?? 'direct'}-${text.length}"`, at: Date.now() };
    m3uCache.set(key, hit);
  }
  if (c.req.header('If-None-Match') === hit.etag) return c.body(null, 304);
  const fname = kind === 'txt' ? 'lista.txt' : kind === 'e2' ? 'userbouquet.iptv.tv' : 'lista.m3u';
  return new Response(hit.text, { headers: { 'Content-Type': CT[kind === 'txt' ? 'txt' : kind === 'e2' ? 'e2' : 'm3u'], ETag: hit.etag, 'Cache-Control': 'public, max-age=60', 'Content-Disposition': `inline; filename="${fname}"` } });
});

// ------------------------------------------------------------------ entrega inteligente: 302 a la mejor fuente viva (fallback automático sin cortar el reproductor)
const candCache = new Map<string, { v: PlayCandidates | null; at: number }>();
export function _resetCandCache() { candCache.clear(); }
const CAND_TTL = 20_000;
const NOT_PLAYABLE = /^https?:\/\/([^/]*\.)?(youtube\.com|youtu\.be)(\/|:|$)/i;       // YouTube es "engine_only": solo sirve la URL fresca que escribe el motor

app.get('/p/:token/play/:tvg', async (c) => {
  const token = c.req.param('token');
  if (!/^[0-9a-f]{64}$/.test(token)) throw new HttpError(404, 'not_found', 'No encontrado');
  let tvg: string; try { tvg = decodeURIComponent(c.req.param('tvg')); } catch { throw new HttpError(400, 'bad_request', 'Canal inválido'); }
  if (!tvg || tvg.length > 120) throw new HttpError(400, 'bad_request', 'Canal inválido');
  limit(`play:${ip(c)}`, 600, 60);
  const key = `${token}|${tvg}`; let hit = candCache.get(key);
  if (!hit || Date.now() - hit.at > CAND_TTL) {
    hit = { v: await rpc<PlayCandidates | null>(c.env, 'get_play_candidates', { p_token: token, p_tvg_id: tvg }, { service: true }), at: Date.now() };
    candCache.set(key, hit);
  }
  const r = hit.v;
  if (!r || r.delivery !== 'smart') throw new HttpError(404, 'not_found', 'Canal no encontrado');
  let idx = 0;
  for (const cand of r.candidates) {
    idx++;
    try {
      const dis = new Set(r.disabled_resolvers ?? []);
      const rs = await resolveForRedirect(cand, { env: c.env, requestUrl: c.req.url, exec: c.executionCtx }, dis);
      if (!rs) continue;
      if (rs.via !== 'directo') return new Response(null, { status: 302, headers: { Location: rs.url, 'Cache-Control': 'no-store', 'X-Source-Rank': String(idx), 'X-Resolver': rs.via } });
      if (NOT_PLAYABLE.test(cand.url)) continue;
      if (cand.state === 'down') continue;       // solo se usa una caída como último recurso (abajo)
      return new Response(null, { status: 302, headers: { Location: cand.url, 'Cache-Control': 'no-store', 'X-Source-Rank': String(idx) } });
    } catch { /* siguiente candidato */ }
  }
  const last = r.candidates.find((x) => x.state === 'down' && !NOT_PLAYABLE.test(x.url) && (x.resolver ?? x.kind ?? 'direct') !== 'youtube');
  if (last) return new Response(null, { status: 302, headers: { Location: last.url, 'Cache-Control': 'no-store', 'X-Source-Rank': 'last-resort' } });
  throw new HttpError(502, 'no_source', 'Ninguna fuente disponible ahora', 30);
});

app.get('/p/:token/epg.xml.gz', async (c) => {
  const token = c.req.param('token');
  if (!/^[0-9a-f]{64}$/.test(token)) throw new HttpError(404, 'not_found', 'No encontrado');
  limit(`epg:${ip(c)}`, 30, 60);
  const art = await rpc<{ storage_key: string } | null>(c.env, 'get_output_artifact', { p_token: token, p_kind: 'epg_gz' }, { service: true });
  if (!art) throw new HttpError(404, 'not_found', 'Aún no hay guía EPG generada');
  const headers = { 'Content-Type': 'application/gzip', 'Cache-Control': 'public, max-age=3600' };
  if (c.env.EPG_BUCKET) {
    const obj = await c.env.EPG_BUCKET.get(art.storage_key);
    if (!obj) throw new HttpError(404, 'not_found', 'Archivo EPG ausente');
    return new Response(obj.body, { headers });
  }
  if (c.env.EPG_PUBLIC_BASE) {                          // la base la fija el operador (variable de entorno), nunca el usuario
    const r = await fetch(`${c.env.EPG_PUBLIC_BASE.replace(/\/$/, '')}/${art.storage_key.split('/').map(encodeURIComponent).join('/')}`);
    if (!r.ok || !r.body) throw new HttpError(404, 'not_found', 'Archivo EPG ausente');
    return new Response(r.body, { headers });
  }
  throw new HttpError(501, 'not_configured', 'Almacén EPG no configurado (define el binding EPG_BUCKET o la variable EPG_PUBLIC_BASE)');
});

app.get('/dm/:file', async (c) => {
  const m = c.req.param('file').match(/^([a-z0-9]{4,12})(?:\.m3u8)?$/i);
  if (!m) throw new HttpError(404, 'not_found', 'No encontrado');
  const id = m[1].toLowerCase();
  const allowed = c.env.ALLOWED_DM_IDS?.split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
  if (allowed?.length && !allowed.includes(id)) throw new HttpError(403, 'forbidden', 'Canal no permitido');
  limit(`dm:${ip(c)}`, 600, 60);
  try {
    const r = await resolveDm(id, c.req.url, c.executionCtx);
    return new Response(null, { status: 302, headers: { Location: r.url, 'Cache-Control': 'no-store', 'X-Cache': r.via } });
  } catch (e: any) { throw new HttpError(502, 'no_stream', 'Sin stream: ' + e.message, 15); }
});

// ------------------------------------------------------------------ proxy de la sesión de prueba (URL firmada, sin Authorization)
interface Session { u: string; r?: string; ua?: string; exp: number; sub: string }
const MANIFEST_RE = /\.m3u8(\?|$)/i;

function rewriteManifest(text: string, base: string, mk: (abs: string) => string): string {
  return text.split('\n').map((line) => {
    const l = line.trim();
    if (!l) return line;
    if (l.startsWith('#')) return l.includes('URI="') ? l.replace(/URI="([^"]+)"/g, (_m, u) => `URI="${mk(new URL(u, base).toString())}"`) : line;
    return mk(new URL(l, base).toString());
  }).join('\n');
}

async function proxy(c: Context<AppEnv>, target?: string) {
  if (c.env.PLAYER_PROXY_ENABLED === 'false') throw new HttpError(403, 'feature_disabled', 'El reproductor por proxy está desactivado');
  const token = c.req.param('token')!;
  const s = await readToken<Session>(c.env.SIGNING_SECRET, token);
  if (!s || s.exp < Date.now()) throw new HttpError(401, 'session_expired', 'La sesión de prueba caducó');
  limit(`play:${token.slice(-24)}`, 90, 120);                    // ~90 recursos por sesión
  const url = target ?? s.u;
  const { res, finalUrl } = await safeFetch(url, c.env, { headers: headersFor(s.r, s.ua), timeoutMs: 15000 });
  if (!res.ok) { res.body?.cancel().catch(() => {}); throw new HttpError(502, 'origin_error', `El origen respondió HTTP ${res.status}`); }
  const ct = res.headers.get('content-type') ?? '';
  if (/mpegurl/i.test(ct) || MANIFEST_RE.test(finalUrl)) {
    const text = new TextDecoder().decode(await readLimited(res, 512_000));
    const origin = originOf(c);
    const out = rewriteManifest(text, finalUrl, (abs) => `${origin}/api/play/${token}/r?u=${encodeURIComponent(abs)}`);
    return new Response(out, { headers: { 'Content-Type': 'application/vnd.apple.mpegurl', 'Cache-Control': 'no-store' } });
  }
  return new Response(res.body, { status: res.status, headers: { 'Content-Type': ct || 'application/octet-stream', 'Cache-Control': 'no-store' } });
}
app.get('/api/play/:token/index.m3u8', (c) => proxy(c));
app.get('/api/play/:token/r', (c) => proxy(c, c.req.query('u') ?? ''));

// ------------------------------------------------------------------ logos
const IMG_OK = /^image\/(png|jpe?g|webp|gif|svg\+xml|avif|x-icon|vnd\.microsoft\.icon)/i;
async function fetchLogo(c: Context<AppEnv>, url: string) {
  const { res, done } = await safeFetch(url, c.env, { timeoutMs: 6000, headers: { 'User-Agent': 'Mozilla/5.0', Accept: 'image/*' } });
  try {
    if (!res.ok) throw new HttpError(422, 'logo_http', `El servidor del logo respondió HTTP ${res.status}`);
    const ct = res.headers.get('content-type') ?? '';
    if (!IMG_OK.test(ct)) throw new HttpError(422, 'logo_not_image', `No es una imagen (${ct || 'sin tipo'})`);
    const bytes = await readLimited(res, 1_000_001);
    if (bytes.length > 1_000_000) throw new HttpError(422, 'logo_too_big', 'La imagen pesa más de 1 MB');
    return { bytes, ct };
  } finally { done(); }
}
app.get('/api/logo', async (c) => {
  const u = c.req.query('u') ?? ''; const sig = c.req.query('sig') ?? '';
  if (!u || !(await verifySig(c.env.SIGNING_SECRET, u, sig))) throw new HttpError(403, 'bad_signature', 'Firma inválida');
  limit(`logo:${ip(c)}`, 300, 60);
  const { bytes, ct } = await fetchLogo(c, u);
  return new Response(bytes, { headers: { 'Content-Type': ct, 'Cache-Control': 'public, max-age=604800, immutable', 'Access-Control-Allow-Origin': '*' } });
});

// ------------------------------------------------------------------ webhook de cobros (Merchant of Record). INACTIVO mientras billing_mode = off
async function hmacHex(secret: string, data: string): Promise<string> {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return [...new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(data)))].map((b) => b.toString(16).padStart(2, '0')).join('');
}
const tsEq = (a: string, b: string) => { if (a.length !== b.length) return false; let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i); return r === 0; };

app.post('/webhooks/billing/:provider', async (c) => {
  const provider = c.req.param('provider');
  if (provider !== 'lemonsqueezy') throw new HttpError(404, 'not_found', 'Proveedor no soportado');
  if (!c.env.BILLING_WEBHOOK_SECRET) throw new HttpError(501, 'not_configured', 'Webhook de cobros no configurado');
  limit(`wh:${ip(c)}`, 120, 60);
  const raw = await c.req.text();
  const sig = (c.req.header('X-Signature') ?? '').toLowerCase();
  if (!sig || !tsEq(sig, await hmacHex(c.env.BILLING_WEBHOOK_SECRET, raw))) throw new HttpError(401, 'bad_signature', 'Firma inválida');   // SIEMPRE se verifica la firma
  const mode = await rpc<string>(c.env, 'billing_mode', {}, { service: true });
  if (mode === 'off') return c.json({ ignored: true, reason: 'billing_mode=off' });                  // se confirma (200) para que el proveedor no reintente
  let ev: any; try { ev = JSON.parse(raw); } catch { throw new HttpError(400, 'bad_request', 'JSON inválido'); }
  const name: string = ev?.meta?.event_name ?? ''; const user = ev?.meta?.custom_data?.user_id; const attrs = ev?.data?.attributes ?? {};
  if (!name.startsWith('subscription_') || !UUID.test(String(user)) || !ev?.data?.id) return c.json({ ignored: true, reason: 'evento no relevante' });
  const status = ({ active: 'active', on_trial: 'trialing', past_due: 'past_due', cancelled: 'canceled', expired: 'expired', unpaid: 'past_due', paused: 'canceled' } as Record<string, string>)[attrs.status] ?? 'expired';
  const eventId = await hmacHex('evt', raw);                                                        // mismo cuerpo reintentado = mismo id (idempotente)
  const res = await rpc(c.env, 'apply_subscription_event', {
    p_provider: provider, p_event_id: eventId, p_type: name, p_user: user, p_sub_id: String(ev.data.id), p_status: status,
    p_period_end: attrs.ends_at ?? attrs.renews_at ?? null, p_interval: attrs.variant_name?.toLowerCase().includes('year') ? 'year' : 'month', p_payload: { event: name, status: attrs.status },
  }, { service: true });
  return c.json(res);
});

// ------------------------------------------------------------------ autenticadas
app.use('/api/*', requireUser);

app.post('/api/sync', async (c) => {
  const u = c.get('user'); const b = await body(c);
  const playlist = uuid(b.playlist_id, 'playlist_id'); const kind = ['full', 'probe', 'repair', 'epg'].includes(b.kind) ? b.kind : 'full';
  limit(`sync:${u.sub}`, 6, 60);
  const rows = await rpc<{ job_id: string; status: string; deduped: boolean }[]>(c.env, 'request_sync', { p_playlist: playlist, p_kind: kind }, { jwt: u.jwt });
  const job = rows[0];
  if (!job.deduped && c.env.GITHUB_DISPATCH_TOKEN && c.env.GITHUB_REPO) {
    c.executionCtx.waitUntil(fetch(`https://api.github.com/repos/${c.env.GITHUB_REPO}/actions/workflows/${c.env.GITHUB_WORKFLOW ?? 'engine.yml'}/dispatches`, {
      method: 'POST', headers: { Authorization: `Bearer ${c.env.GITHUB_DISPATCH_TOKEN}`, Accept: 'application/vnd.github+json', 'User-Agent': 'iptv-engine', 'Content-Type': 'application/json' },
      body: JSON.stringify({ ref: 'main' }),
    }).catch(() => {}));
  }
  return c.json(job, 202);
});

app.get('/api/status', async (c) => {
  const u = c.get('user'); const playlist = uuid(c.req.query('playlist_id'), 'playlist_id');
  let db = 'ok'; let st: any = {};
  try { st = await rpc(c.env, 'playlist_status', { p_playlist: playlist }, { jwt: u.jwt }); } catch { db = 'error'; }
  return c.json({ worker: 'ok', db, colo: (c.req.raw as any).cf?.colo ?? null, ...st });
});

app.post('/api/probe', async (c) => {
  const u = c.get('user'); const b = await body(c);
  if (typeof b.url !== 'string') throw new HttpError(400, 'bad_request', 'Falta url');
  assertPublicUrl(b.url, c.env); limit(`probe:${u.sub}`, 60, 60);
  return c.json(await probeStream(c.env, { url: b.url, referer: b.referer, ua: b.user_agent }));
});

app.post('/api/probe/source/:id', async (c) => {
  const u = c.get('user'); const id = uuid(c.req.param('id'), 'source id'); limit(`probe:${u.sub}`, 60, 60);
  const rows = await select<any[]>(c.env, `channel_sources?id=eq.${id}&select=id,url,referer,user_agent,kind,resolve_ref,resolver`, { jwt: u.jwt });
  if (!rows.length) throw new HttpError(404, 'not_found', 'Fuente no encontrada');
  const s = rows[0]; let url: string = s.url;
  try { const rs = await resolveForProxy({ source_id: id, url: s.url, referer: s.referer, ua: s.user_agent, kind: s.kind, resolve_ref: s.resolve_ref, resolver: s.resolver }, { env: c.env, requestUrl: c.req.url, exec: c.executionCtx }); if (rs) url = rs.url; } catch { /* se prueba la URL guardada */ }
  const r = await probeStream(c.env, { url, referer: s.referer, ua: s.user_agent });
  const hard = !!r.error && /HTTP (404|410)\b/.test(r.error);                 // desde el Worker solo el 404/410 cuenta como strike
  const health = await rpc(c.env, 'record_probe', {
    p_source: id, p_ok: r.ok, p_http: r.http, p_error: r.error, p_latency_ms: r.latency_ms, p_vantage: 'worker', p_hard: hard,
    p_resolved_url: r.ok && url !== s.url ? url : null, p_resolved_ua: r.ua_used, p_quality: qualityOf(r),
  }, { service: true });
  return c.json({ ...r, health });
});

app.post('/api/play-session', async (c) => {
  if (c.env.PLAYER_PROXY_ENABLED === 'false') throw new HttpError(403, 'feature_disabled', 'El reproductor por proxy está desactivado');
  const u = c.get('user'); const b = await body(c); limit(`play-session:${u.sub}`, 10, 3600);
  let url: string = b.url, referer: string | undefined = b.referer, ua: string | undefined = b.user_agent;
  if (b.source_id) {
    const rows = await select<any[]>(c.env, `channel_sources?id=eq.${uuid(b.source_id, 'source_id')}&select=url,referer,user_agent,kind,resolve_ref,resolver`, { jwt: u.jwt });
    if (!rows.length) throw new HttpError(404, 'not_found', 'Fuente no encontrada');
    ({ url, referer, user_agent: ua } = { url: rows[0].url, referer: rows[0].referer, user_agent: rows[0].user_agent });
    const rs = await resolveForProxy({ source_id: b.source_id, url, referer, ua, kind: rows[0].kind, resolve_ref: rows[0].resolve_ref, resolver: rows[0].resolver }, { env: c.env, requestUrl: c.req.url, exec: c.executionCtx });
    if (rs) url = rs.url;
  }
  if (typeof url !== 'string') throw new HttpError(400, 'bad_request', 'Falta url o source_id');
  assertPublicUrl(url, c.env);
  const exp = Date.now() + 120_000;
  const token = await makeToken(c.env.SIGNING_SECRET, { u: url, r: referer, ua, exp, sub: u.sub } satisfies Session);
  return c.json({ play_url: `${originOf(c)}/api/play/${token}/index.m3u8`, expires_at: new Date(exp).toISOString(), mode: 'proxy', max_seconds: 90 });
});

app.post('/api/validate/logo', async (c) => {
  const u = c.get('user'); const b = await body(c); limit(`logo-v:${u.sub}`, 60, 60);
  if (typeof b.url !== 'string') throw new HttpError(400, 'bad_request', 'Falta url');
  assertPublicUrl(b.url, c.env);
  try {
    const { bytes, ct } = await fetchLogo(c, b.url);
    const sig = await sign(c.env.SIGNING_SECRET, b.url);
    return c.json({ ok: true, content_type: ct, bytes: bytes.length, mixed_content: b.url.startsWith('http://'),
                    warning: /avif/i.test(ct) ? 'AVIF no se ve en muchas apps IPTV: conviene PNG/JPG' : null,
                    signed_src: `${originOf(c)}/api/logo?u=${encodeURIComponent(b.url)}&sig=${sig}` });
  } catch (e) {
    if (e instanceof HttpError && e.status === 422) return c.json({ ok: false, error: e.code, message: e.message });
    throw e;
  }
});

app.post('/api/import/preview', async (c) => {
  const u = c.get('user'); const b = await body(c); limit(`import:${u.sub}`, 10, 60);
  if (typeof b.url !== 'string') throw new HttpError(400, 'bad_request', 'Falta url');
  const { res, done } = await safeFetch(b.url, c.env, { timeoutMs: 15000, headers: { 'User-Agent': 'Mozilla/5.0' } });
  try {
    if (!res.ok) throw new HttpError(422, 'origin_error', `La lista respondió HTTP ${res.status}`);
    const items = parseM3U(new TextDecoder().decode(await readLimited(res, 3_000_000)));
    return c.json({ count: items.length, items: items.slice(0, 1000) });
  } finally { done(); }
});

app.get('/api/export', async (c) => {
  const u = c.get('user'); const playlist = uuid(c.req.query('playlist_id'), 'playlist_id'); const fmt = c.req.query('format') ?? 'json';
  const rows = await select<any[]>(c.env, `channels?playlist_id=eq.${playlist}&order=sort_order&select=tvg_id,name,logo_url,epg_id,chno,language,enabled,check_enabled,catchup_enabled,catchup_type,catchup_source,catchup_days,sort_order,groups(name),channel_sources(priority,url,referer,user_agent,kind,resolve_ref)`, { jwt: u.jwt });
  const items = rows.map((r) => ({
    tvg_id: r.tvg_id, name: r.name, logo_url: r.logo_url, group: r.groups?.name ?? null, epg_id: r.epg_id, chno: r.chno, language: r.language,
    enabled: r.enabled, check: r.check_enabled, sort_order: r.sort_order,
    catchup: r.catchup_enabled ? { type: r.catchup_type, source: r.catchup_source, days: r.catchup_days } : null,
    sources: [...(r.channel_sources ?? [])].sort((a: any, b: any) => a.priority - b.priority).map((s: any) => ({ url: s.url, referer: s.referer, ua: s.user_agent, kind: s.kind, resolve_ref: s.resolve_ref })),
  }));
  if (fmt === 'csv') {
    const q = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""')}"`;
    const csv = ['name,group,epg_id,url,alt_url,referer'].concat(items.map((i) => [i.name, i.group, i.epg_id, i.sources[0]?.url, i.sources[1]?.url, i.sources[0]?.referer].map(q).join(','))).join('\n');
    return new Response(csv, { headers: { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': 'attachment; filename="canales.csv"' } });
  }
  return c.json({ items });
});

export default {
  fetch: app.fetch,
  async scheduled(_e: ScheduledEvent, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(rpc(env, 'purge_old_data', {}, { service: true }));      // retención + actividad diaria (evita la pausa de Supabase Free)
  },
};
export { app };
