import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';
import { DM_API, _resetDm, resolveDm } from '../src/dm';
import { probeStream, qualityOf } from '../src/probe';
import { assertPublicUrl, makeToken, safeFetch, _resetRateLimits, SMART_TV_UAS } from '../src/util';
import { verifyUserJwt } from '../src/auth';
import { HLS, MASTER, baseEnv, call, jwt, startServer, userJwt } from './helpers';

let origin: Awaited<ReturnType<typeof startServer>>; let dmHits = 0;
const PNG = Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex');
beforeAll(async () => {
  origin = await startServer((req, res) => {
    const u = req.url!.split('?')[0]; const ua = String(req.headers['user-agent'] ?? '');
    const send = (code: number, body: string | Buffer = '', type = 'application/octet-stream') => { res.writeHead(code, { 'Content-Type': type }); res.end(body); };
    if (u === '/ok/playlist.m3u8') return send(200, HLS, 'application/vnd.apple.mpegurl');
    if (u === '/ok/seg1.ts') return send(200, Buffer.alloc(3000, 7), 'video/mp2t');
    if (u === '/master/master.m3u8') return send(200, MASTER, 'application/vnd.apple.mpegurl');
    if (u === '/master/media.m3u8') return send(200, HLS, 'application/vnd.apple.mpegurl');
    if (u === '/master/seg1.ts') return send(200, Buffer.alloc(2000), 'video/mp2t');
    if (u.startsWith('/tv/') && !ua.includes('BRAVIA')) return send(403);
    if (u === '/tv/playlist.m3u8') return send(200, HLS, 'application/vnd.apple.mpegurl');
    if (u === '/tv/seg1.ts') return send(200, Buffer.alloc(100));
    if (u === '/slow/playlist.m3u8') { setTimeout(() => send(200, HLS), 12000); return; }
    if (u === '/redir') { res.writeHead(302, { Location: 'http://169.254.169.254/latest/meta-data' }); return res.end(); }
    if (u === '/logo.png') return send(200, PNG, 'image/png');
    if (u === '/notimg') return send(200, 'hola', 'text/html');
    if (u === '/meta/xdm01') { dmHits++; return setTimeout(() => send(200, JSON.stringify({ qualities: { auto: [{ url: `https://cdn.dm/live.m3u8?sec=T${dmHits}` }] } }), 'application/json'), 40); }
    return send(404);
  });
  DM_API.base = `${origin.url}/meta/`;
});
afterAll(() => origin.close());
beforeEach(() => { _resetRateLimits(); _resetDm(); dmHits = 0; });
const env = () => baseEnv();

describe('sondeo contra servidores reales locales', () => {
  it('OK + calidad desde el master', async () => {
    const r = await probeStream(env(), { url: `${origin.url}/master/master.m3u8` });
    expect(r.ok && r.segment_ok).toBe(true);
    expect(qualityOf(r)).toMatchObject({ height: 720, bandwidth: 2500000, variants: 2 });
  });
  it('rota los User-Agents de Smart TV cuando el origen responde 403', async () => {
    const r = await probeStream(env(), { url: `${origin.url}/tv/playlist.m3u8` });
    expect(r.ok).toBe(true); expect(r.ua_used).toBe(SMART_TV_UAS[2]);
  });
  it('404 NO rota (falla rápido, con pista)', async () => {
    const t = Date.now(); const r = await probeStream(env(), { url: `${origin.url}/nada.m3u8` });
    expect(r.ok).toBe(false); expect(r.error).toBe('HTTP 404'); expect(r.hint).toMatch(/caducada/); expect(Date.now() - t).toBeLessThan(1500);
  });
  it('timeout estricto de 5 s por intento', async () => {
    const t = Date.now(); const r = await probeStream(env(), { url: `${origin.url}/slow/playlist.m3u8` }, { rotate: false });
    const el = Date.now() - t;
    expect(r.ok).toBe(false); expect(r.error).toBe('Timeout'); expect(el).toBeGreaterThan(4500); expect(el).toBeLessThan(6500);
  }, 15000);
  it('el SSRF por redirección se bloquea (sin ALLOW_PRIVATE_HOSTS)', async () => {
    await expect(safeFetch(`${origin.url}/redir`, {})).rejects.toMatchObject({ code: 'blocked_host' });
    await expect(safeFetch('http://127.0.0.1:1/x', {})).rejects.toMatchObject({ code: 'blocked_host' });
    await expect(safeFetch(`${origin.url}/redir`, { ALLOW_PRIVATE_HOSTS: '1' })).rejects.toMatchObject({ code: 'blocked_host' });   // aun en modo desarrollo, el hop a la IP de metadatos de la nube sigue bloqueado
  });
});

describe('resolvedor Dailymotion con caché', () => {
  it('50 peticiones simultáneas = 1 sola al origen; luego memoria', async () => {
    const rs = await Promise.all(Array.from({ length: 50 }, () => resolveDm('xdm01', 'https://play.test/dm/xdm01')));
    expect(dmHits).toBe(1); expect(new Set(rs.map((r) => r.url)).size).toBe(1);
    await resolveDm('xdm01', 'https://play.test/dm/xdm01'); expect(dmHits).toBe(1);
  });
  it('ruta /dm/:id.m3u8 → 302, ALLOWED_DM_IDS y límites', async () => {
    const r = await call('/dm/xdm01.m3u8', env()); expect(r.status).toBe(302); expect(r.headers.get('location')).toBe('https://cdn.dm/live.m3u8?sec=T1');
    expect((await call('/dm/xotro99', baseEnv({ ALLOWED_DM_IDS: 'xdm01' }))).status).toBe(403);
  });
});

describe('API autenticada y proxy de reproductor', () => {
  const E = () => baseEnv({ SUPABASE_JWT_SECRET: 'test-secret-test-secret-test-secret-123456' });
  it('sin token / token falso → 401', async () => {
    expect((await call('/api/probe', E(), { method: 'POST', json: { url: 'x' } })).status).toBe(401);
    expect((await call('/api/probe', E(), { method: 'POST', json: { url: 'x' }, token: 'abc.def.ghi' })).status).toBe(401);
    expect((await call('/api/probe', E(), { method: 'POST', json: { url: 'x' }, token: await jwt({ sub: 'u', role: 'anon' }) })).status).toBe(401);
  });
  it('CORS: preflight permitido solo para tu panel', async () => {
    const ok = await call('/api/sync', E(), { method: 'OPTIONS', origin: 'http://localhost:5173' });
    expect(ok.status).toBe(204); expect(ok.headers.get('access-control-allow-origin')).toBe('http://localhost:5173');
    const bad = await call('/api/sync', E(), { method: 'OPTIONS', origin: 'https://evil.com' });
    expect(bad.headers.get('access-control-allow-origin')).toBeNull();
  });
  it('POST /api/probe devuelve calidad, latencia y pista', async () => {
    const t = await userJwt('11111111-1111-1111-1111-111111111111');
    const r = await call('/api/probe', E(), { method: 'POST', token: t, json: { url: `${origin.url}/master/master.m3u8` } });
    const j: any = await r.json(); expect(r.status).toBe(200); expect(j.ok).toBe(true); expect(j.variants[0].height).toBe(720);
    const bad: any = await (await call('/api/probe', E(), { method: 'POST', token: t, json: { url: `${origin.url}/nada` } })).json();
    expect(bad.ok).toBe(false); expect(bad.hint).toBeTruthy();
    expect((await call('/api/probe', baseEnv({ SUPABASE_JWT_SECRET: 'test-secret-test-secret-test-secret-123456', ALLOW_PRIVATE_HOSTS: '0' }), { method: 'POST', token: t, json: { url: `${origin.url}/x` } })).status).toBe(400);
  });
  it('sesión de prueba: reescribe el manifiesto, sirve segmentos y caduca', async () => {
    const t = await userJwt('11111111-1111-1111-1111-111111111111');
    const s: any = await (await call('/api/play-session', E(), { method: 'POST', token: t, json: { url: `${origin.url}/ok/playlist.m3u8` } })).json();
    expect(s.mode).toBe('proxy'); const path = new URL(s.play_url).pathname;
    const m = await call(path, E()); const text = await m.text();
    expect(m.status).toBe(200); expect(text).toContain('#EXTM3U'); expect(text).toMatch(/https:\/\/play\.test\/api\/play\/.+\/r\?u=http%3A%2F%2F127\.0\.0\.1%3A\d+%2Fok%2Fseg1\.ts/);
    const segPath = text.split('\n').find((l) => l.includes('/r?u='))!.replace('https://play.test', '');
    const seg = await call(segPath, E()); expect(seg.status).toBe(200); expect((await seg.arrayBuffer()).byteLength).toBe(3000);
    const expired = await makeToken('signing-secret-for-tests', { u: `${origin.url}/ok/playlist.m3u8`, exp: Date.now() - 1000, sub: 'x' });
    expect((await call(`/api/play/${expired}/index.m3u8`, E())).status).toBe(401);
    expect((await call(`/api/play/${s.play_url.split('/api/play/')[1].replace(/.$/, 'X')}`, E())).status).toBe(401);
    expect((await call(path, baseEnv({ PLAYER_PROXY_ENABLED: 'false' }))).status).toBe(403);
  });
  it('logos: valida imagen, rechaza HTML y la URL firmada solo sirve lo firmado', async () => {
    const t = await userJwt('11111111-1111-1111-1111-111111111111');
    const ok: any = await (await call('/api/validate/logo', E(), { method: 'POST', token: t, json: { url: `${origin.url}/logo.png` } })).json();
    expect(ok.ok).toBe(true); expect(ok.content_type).toBe('image/png'); expect(ok.mixed_content).toBe(true);
    const bad: any = await (await call('/api/validate/logo', E(), { method: 'POST', token: t, json: { url: `${origin.url}/notimg` } })).json();
    expect(bad).toMatchObject({ ok: false, error: 'logo_not_image' });
    const img = await call(new URL(ok.signed_src).pathname + new URL(ok.signed_src).search, E()); expect(img.status).toBe(200); expect(img.headers.get('cache-control')).toMatch(/604800/);
    expect((await call(`/api/logo?u=${encodeURIComponent(`${origin.url}/logo.png`)}&sig=falsa`, E())).status).toBe(403);
  });
});

describe('autenticación por JWKS (claves asimétricas de Supabase)', () => {
  it('acepta un token ES256 firmado por la clave publicada y rechaza otra', async () => {
    const { publicKey, privateKey } = await generateKeyPair('ES256'); const other = await generateKeyPair('ES256');
    const jwk = { ...(await exportJWK(publicKey)), kid: 'k1', alg: 'ES256', use: 'sig' };
    const jwks = await startServer((_q, res) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ keys: [jwk] })); });
    // El JWKS vive en <SUPABASE_URL>/auth/v1/.well-known/jwks.json: lo servimos en cualquier ruta del servidor de prueba
    const e = baseEnv({ SUPABASE_URL: jwks.url });
    const sign = (key: any) => new SignJWT({ role: 'authenticated', sub: 'u1' }).setProtectedHeader({ alg: 'ES256', kid: 'k1' }).setIssuer(`${jwks.url}/auth/v1`).setExpirationTime('1h').sign(key);
    expect((await verifyUserJwt(e, await sign(privateKey))).sub).toBe('u1');
    await expect(verifyUserJwt(e, await sign(other.privateKey))).rejects.toMatchObject({ status: 401 });
    await jwks.close();
  });
});
