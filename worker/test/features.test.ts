// Funciones SaaS del Worker contra Postgres/PostgREST reales: entrega inteligente, DRM, formatos extra y webhook de cobros.
import { createHmac } from 'node:crypto';
import { execSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { gzipSync } from 'node:zlib';
import { beforeAll, describe, expect, it } from 'vitest';
import { _resetCandCache, _resetM3uCache } from '../src/index';
import { _resetRateLimits } from '../src/util';
import { baseEnv, call, jwt, userJwt } from './helpers';

const P = 'eeeeeeee-0000-0000-0000-000000000005'; const F = 'ffffffff-0000-0000-0000-000000000006';   // Pro y Free
const sql = (q: string) => { writeFileSync('/tmp/q_feat.sql', q); return execSync('su postgres -c "psql -At -q -v ON_ERROR_STOP=1 -d iptvtest -f /tmp/q_feat.sql"').toString().trim(); };
const rest = (path: string, token: string, body: unknown) =>
  fetch(`http://127.0.0.1:3100${path}`, { method: 'POST', body: JSON.stringify(body), headers: { 'Content-Type': 'application/json', apikey: 'x', Authorization: `Bearer ${token}` } });

let env: ReturnType<typeof baseEnv>; let tokP = ''; let tokF = ''; let plP = ''; let tP = '';
const SECRET = 'whsec_test';

beforeAll(async () => {
  env = baseEnv({ SUPABASE_URL: 'http://127.0.0.1:3100', SUPABASE_ANON_KEY: await jwt({ role: 'anon' }), SUPABASE_SERVICE_KEY: await jwt({ role: 'service_role' }),
                  SUPABASE_JWT_SECRET: 'test-secret-test-secret-test-secret-123456', BILLING_WEBHOOK_SECRET: SECRET });
  sql(`insert into auth.users(id,email) values ('${P}','p@x.com'),('${F}','f@x.com');
       insert into public.manual_grants(user_id, reason, expires_at) values ('${P}','test', now() + interval '1 day');`);
  plP = sql(`select id from public.playlists where owner_id='${P}'`);
  tokP = sql(`select token from public.outputs where playlist_id='${plP}'`);
  tokF = sql(`select o.token from public.outputs o where o.owner_id='${F}'`);
  tP = await userJwt(P); const tF = await userJwt(F);
  const items = [
    { tvg_id: 'espn', name: 'ESPN', group: 'Deportes', sources: [
      { url: 'https://main.test/espn.m3u8', referer: 'https://espn.test/', header_profile: 'smarttv_tizen', extra_headers: { 'X-Custom': 'abc' } },
      { url: 'https://backup.test/espn.m3u8' }] },
    { tvg_id: 'drm', name: 'Canal DRM', group: 'Cine', sources: [{ url: 'https://drm.test/a.mpd', stream_format: 'dash',
      drm: { type: 'clearkey', keys: '00112233445566778899aabbccddeeff:ffeeddccbbaa99887766554433221100' } }] },
  ];
  expect(await (await rest('/rest/v1/rpc/bulk_upsert_channels', tP, { p_playlist: plP, p_items: items })).json()).toEqual({ inserted: 2, updated: 0 });
  await rest('/rest/v1/rpc/bulk_upsert_channels', tF, { p_playlist: sql(`select id from public.playlists where owner_id='${F}'`), p_items: [{ tvg_id: 'x', name: 'X', sources: [{ url: 'https://x.test/a.m3u8' }] }] });
  sql(`update public.outputs set delivery='smart' where playlist_id='${plP}'`);
});
const fresh = () => { _resetM3uCache(); _resetCandCache(); _resetRateLimits(); };

describe('formato y cabeceras', () => {
  it('M3U: perfil Tizen + Referer/Origin + extra_headers + KODIPROP ClearKey + redirección inteligente', async () => {
    fresh(); const t = await (await call(`/p/${tokP}.m3u`, env)).text();
    expect(t).toContain(`https://play.test/p/${tokP}/play/espn|User-Agent=`);
    expect(t).toMatch(/Tizen/); expect(t).toContain('Accept-Language=es-DO'); expect(t).toContain('Origin=https://espn.test'); expect(t).toContain('X-Custom=abc');
    expect(t).toContain('#KODIPROP:inputstream.adaptive.license_type=clearkey');
    expect(t).toContain('#KODIPROP:inputstream.adaptive.license_key=00112233445566778899aabbccddeeff:ffeeddccbbaa99887766554433221100');
    expect(t).toContain('#KODIPROP:inputstream.adaptive.manifest_type=mpd');
    expect(t).toContain('\nhttps://drm.test/a.mpd');                       // DRM nunca pasa por /play (directo)
  });
  it('TXT y Enigma2 con plan Pro; 403 para plan Free', async () => {
    fresh();
    expect((await call(`/p/${tokF}.txt`, env)).status).toBe(200);          // fase gratis (billing off): la función "open" está abierta para todos
    sql(`update public.app_settings set value='"live"' where key='billing_mode'`); fresh();
    expect(await (await call(`/p/${tokP}.txt`, env)).text()).toContain('Deportes,#genre#');
    const e2 = await (await call(`/p/${tokP}.e2`, env)).text();
    expect(e2).toContain('#NAME Mi lista'); expect(e2).toContain('#SERVICE 4097:0:1:0:0:0:0:0:0:0:');
    const r = await call(`/p/${tokF}.txt`, env); expect(r.status).toBe(403);
    expect((await r.json() as any).error.code).toBe('feature_locked');
    expect((await call(`/p/${tokF}.m3u`, env)).status).toBe(200);          // M3U básico siempre disponible
    sql(`update public.app_settings set value='"off"' where key='billing_mode'`);
  });
  it('la entrega inteligente no se aplica a un usuario Free (se degrada a directa)', async () => {
    fresh(); sql(`set session_replication_role = replica; update public.outputs set delivery='smart' where owner_id='${F}'`);   // saltándose el trigger (p. ej. plan vencido)
    const t = await (await call(`/p/${tokF}.m3u`, env)).text();
    expect(t).not.toContain('/play/'); expect(t).toContain('https://x.test/a.m3u8');
  });
});

describe('entrega inteligente: fallback automático', () => {
  it('redirige 302 a la fuente principal si está sana o desconocida', async () => {
    fresh(); const r = await call(`/p/${tokP}/play/espn`, env, { redirect: 'manual' });
    expect(r.status).toBe(302); expect(r.headers.get('Location')).toBe('https://main.test/espn.m3u8'); expect(r.headers.get('X-Source-Rank')).toBe('1');
  });
  it('si el principal cae (3 strikes) redirige al backup SIN tocar la lista del usuario', async () => {
    sql(`update public.playlists set settings = settings || '{"strike_gap_minutes":0}' where id='${plP}';
         select public.record_probe(id,false,404,'HTTP 404',10,'local-do',true) from public.channel_sources where url='https://main.test/espn.m3u8';
         select public.record_probe(id,false,404,'HTTP 404',10,'local-do',true) from public.channel_sources where url='https://main.test/espn.m3u8';
         select public.record_probe(id,false,404,'HTTP 404',10,'local-do',true) from public.channel_sources where url='https://main.test/espn.m3u8';`);
    fresh(); const r = await call(`/p/${tokP}/play/espn`, env, { redirect: 'manual' });
    expect(r.status).toBe(302); expect(r.headers.get('Location')).toBe('https://backup.test/espn.m3u8');
  });
  it('si TODAS caen: último recurso a la caída; si están muertas: 502 no_source', async () => {
    sql(`select public.record_probe(id,false,404,'HTTP 404',10,'local-do',true) from public.channel_sources where url='https://backup.test/espn.m3u8';
         select public.record_probe(id,false,404,'HTTP 404',10,'local-do',true) from public.channel_sources where url='https://backup.test/espn.m3u8';
         select public.record_probe(id,false,404,'HTTP 404',10,'local-do',true) from public.channel_sources where url='https://backup.test/espn.m3u8';`);
    fresh(); const r = await call(`/p/${tokP}/play/espn`, env, { redirect: 'manual' });
    expect(r.status).toBe(302); expect(r.headers.get('X-Source-Rank')).toBe('last-resort');
    sql(`update public.source_health set dead_at = now() where channel_id=(select id from public.channels where tvg_id='espn' and playlist_id='${plP}')`);
    fresh(); const d = await call(`/p/${tokP}/play/espn`, env, { redirect: 'manual' });
    expect(d.status).toBe(502); expect((await d.json() as any).error.code).toBe('no_source');
  });
  it('token o canal inexistente → 404; usuario Free → 404 (no hay entrega inteligente)', async () => {
    fresh();
    expect((await call(`/p/${tokP}/play/nada`, env, { redirect: 'manual' })).status).toBe(404);
    expect((await call(`/p/${'0'.repeat(64)}/play/espn`, env, { redirect: 'manual' })).status).toBe(404);
    expect((await call(`/p/${tokF}/play/x`, env, { redirect: 'manual' })).status).toBe(404);
  });
});

describe('webhook de cobros (Lemon Squeezy)', () => {
  const body = (extra: object = {}) => JSON.stringify({ meta: { event_name: 'subscription_created', custom_data: { user_id: F } },
    data: { id: 'sub_77', attributes: { status: 'active', renews_at: new Date(Date.now() + 30 * 864e5).toISOString(), variant_name: 'Pro Monthly', ...extra } } });
  const post = (raw: string, sig?: string) => call('/webhooks/billing/lemonsqueezy', env, { method: 'POST', body: raw, headers: { 'X-Signature': sig ?? createHmac('sha256', SECRET).update(raw).digest('hex') } });
  it('firma inválida → 401 (aunque el cobro esté apagado)', async () => {
    _resetRateLimits(); expect((await post(body(), 'deadbeef')).status).toBe(401);
  });
  it('con billing_mode=off se acepta y se IGNORA (no concede nada)', async () => {
    _resetRateLimits(); const r = await post(body()); expect(r.status).toBe(200); expect((await r.json() as any).ignored).toBe(true);
    expect(sql(`select count(*) from public.subscriptions where user_id='${F}'`)).toBe('0');
  });
  it('con billing_mode=live concede Pro, y el reintento es idempotente', async () => {
    sql(`update public.app_settings set value='"live"' where key='billing_mode'`);
    _resetRateLimits(); const raw = body();
    const r1 = await (await post(raw)).json() as any; expect(r1.duplicate).toBe(false); expect(r1.plan).toBe('pro');
    const r2 = await (await post(raw)).json() as any; expect(r2.duplicate).toBe(true);
    expect(sql(`select count(*) from public.billing_events`)).toBe('1');
    sql(`update public.app_settings set value='"off"' where key='billing_mode'`);
  });
  it('sin secreto configurado → 501', async () => {
    const r = await call('/webhooks/billing/lemonsqueezy', { ...env, BILLING_WEBHOOK_SECRET: undefined }, { method: 'POST', body: '{}' });
    expect(r.status).toBe(501);
  });
});


describe('guía EPG', () => {
  const gz = gzipSync(Buffer.from('<tv><channel id="a"/></tv>'));
  const key = () => `epg/${plP}.xml.gz`;
  it('404 mientras el motor no haya generado la guía', async () => {
    fresh(); const r = await call(`/p/${tokP}/epg.xml.gz`, env); expect(r.status).toBe(404);
  });
  it('501 si no hay almacén configurado', async () => {
    sql(`select public.register_artifact('${plP}', 'epg_gz', '${key()}', ${gz.length}, '{}'::jsonb)`);
    fresh(); const r = await call(`/p/${tokP}/epg.xml.gz`, env); expect(r.status).toBe(501);
  });
  it('sirve desde R2 (binding)', async () => {
    fresh(); const bucket = { get: async (k: string) => (k === key() ? { body: new Blob([gz]).stream() } : null) } as unknown as R2Bucket;
    const r = await call(`/p/${tokP}/epg.xml.gz`, { ...env, EPG_BUCKET: bucket }); expect(r.status).toBe(200);
    expect(r.headers.get('content-type')).toBe('application/gzip'); expect(Buffer.from(await r.arrayBuffer()).equals(gz)).toBe(true);
    const gone = await call(`/p/${tokP}/epg.xml.gz`, { ...env, EPG_BUCKET: { get: async () => null } as unknown as R2Bucket }); expect(gone.status).toBe(404);
  });
  it('sirve desde EPG_PUBLIC_BASE (VPS / MinIO / CDN) y no filtra errores del origen', async () => {
    const srv = createServer((q, s) => { if (q.url === `/${key()}`) { s.writeHead(200); s.end(gz); } else { s.writeHead(403); s.end('secreto interno'); } });
    await new Promise<void>((ok) => srv.listen(0, '127.0.0.1', ok)); const base = `http://127.0.0.1:${(srv.address() as { port: number }).port}`;
    try {
      fresh(); const r = await call(`/p/${tokP}/epg.xml.gz`, { ...env, EPG_PUBLIC_BASE: base + '/' }); expect(r.status).toBe(200); expect(Buffer.from(await r.arrayBuffer()).equals(gz)).toBe(true);
      sql(`update public.playlist_artifacts set storage_key = 'epg/otro.xml.gz' where playlist_id='${plP}'`);
      fresh(); const bad = await call(`/p/${tokP}/epg.xml.gz`, { ...env, EPG_PUBLIC_BASE: base }); expect(bad.status).toBe(404); expect(await bad.text()).not.toContain('secreto');
    } finally { srv.close(); }
  });
  it('un token que no existe no revela nada', async () => {
    fresh(); expect((await call(`/p/${'0'.repeat(64)}/epg.xml.gz`, env)).status).toBe(404); expect((await call('/p/abc/epg.xml.gz', env)).status).toBe(404);
  });
});
