// Worker REAL  <->  PostgREST REAL  <->  Postgres REAL (con tu migración). Requiere: sh scripts/dev_stack.sh
import { execSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import app, { _resetM3uCache } from '../src/index';
import { _resetRateLimits } from '../src/util';
import { HLS, baseEnv, call, ctx, jwt, startServer, userJwt } from './helpers';

const A = 'aaaaaaaa-0000-0000-0000-000000000001'; const B = 'bbbbbbbb-0000-0000-0000-000000000002';
const sql = (q: string) => { writeFileSync('/tmp/q.sql', q); return execSync('su postgres -c "psql -At -q -v ON_ERROR_STOP=1 -d iptvtest -f /tmp/q.sql"').toString().trim(); };
const rest = async (path: string, token: string, init: RequestInit = {}) =>
  fetch(`http://127.0.0.1:3100${path}`, { ...init, headers: { 'Content-Type': 'application/json', apikey: 'x', Authorization: `Bearer ${token}`, ...(init.headers as any) } });

let origin: Awaited<ReturnType<typeof startServer>>; let env: ReturnType<typeof baseEnv>;
let tA: string, tB: string, plA: string, plB: string, tokenA: string, srcOk: string, srcDead: string, srcFail: string, chFo: string;

beforeAll(async () => {
  origin = await startServer((req, res) => {
    const u = req.url!.split('?')[0];
    if (u === '/ok/playlist.m3u8') { res.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl' }); return res.end(HLS); }
    if (u === '/ok/seg1.ts') { res.writeHead(200); return res.end(Buffer.alloc(500)); }
    res.writeHead(404); res.end();
  });
  env = baseEnv({ SUPABASE_URL: 'http://127.0.0.1:3100', SUPABASE_ANON_KEY: await jwt({ role: 'anon' }), SUPABASE_SERVICE_KEY: await jwt({ role: 'service_role' }),
                  SUPABASE_JWT_SECRET: 'test-secret-test-secret-test-secret-123456' });
  sql(`insert into auth.users(id,email) values ('${A}','a@x.com'),('${B}','b@x.com');`);
  plA = sql(`select id from public.playlists where owner_id='${A}'`); plB = sql(`select id from public.playlists where owner_id='${B}'`);
  tokenA = sql(`select token from public.outputs where playlist_id='${plA}'`);
  tA = await userJwt(A); tB = await userJwt(B);
  // La UI importa canales con SU sesión, directo a Supabase/PostgREST (RLS)
  const items = [
    { tvg_id: 'tele5', name: 'Telemicro Canal 5', group: 'Dominicana', epg_id: 'g5', chno: 5, sources: [{ url: `${origin.url}/ok/playlist.m3u8`, referer: 'https://telemicro.com.do/players/5tv/' }] },
    { tvg_id: 'muerto', name: 'Canal Muerto', group: 'Dominicana', sources: [{ url: `${origin.url}/no-existe.m3u8` }] },
    { tvg_id: 'caido', name: 'Sin Conexión', group: 'Locales', sources: [{ url: 'http://127.0.0.1:1/x.m3u8' }] },
    { tvg_id: 'colorv', name: 'Color Visión', group: 'Dominicana', sources: [{ url: 'https://old/sec2(t)/dm/3/x7gy059/live.m3u8', kind: 'dailymotion', resolve_ref: 'dm:x7gy059' }] },
    { tvg_id: 'fo', name: 'Con Alterna', group: 'Locales', catchup: { type: 'append', source: '?utc={utc}', days: 2 },
      sources: [{ url: `${origin.url}/no-existe2.m3u8` }, { url: `${origin.url}/ok/playlist.m3u8`, referer: 'https://alt.example/' }] },
  ];
  const r = await rest('/rest/v1/rpc/bulk_upsert_channels', tA, { method: 'POST', body: JSON.stringify({ p_playlist: plA, p_items: items }) });
  expect(await r.json()).toEqual({ inserted: 5, updated: 0 });
  const id = (tv: string, pr = 0) => sql(`select s.id from public.channel_sources s join public.channels c on c.id=s.channel_id where c.playlist_id='${plA}' and c.tvg_id='${tv}' and s.priority=${pr}`);
  srcOk = id('tele5'); srcDead = id('muerto'); srcFail = id('caido'); chFo = sql(`select id from public.channels where playlist_id='${plA}' and tvg_id='fo'`);
});
afterAll(() => origin.close());

describe('lista pública M3U (Worker ← Postgres)', () => {
  it('token desconocido → 404; token real → M3U con todo lo importado', async () => {
    _resetM3uCache(); _resetRateLimits();
    expect((await call(`/p/${'0'.repeat(64)}.m3u`, env)).status).toBe(404);
    const r = await call(`/p/${tokenA}.m3u`, env); const t = await r.text();
    expect(r.status).toBe(200); expect(r.headers.get('content-type')).toMatch(/audio\/mpegurl/);
    expect(t).toContain('x-tvg-url="https://play.test/p/' + tokenA + '/epg.xml.gz"');
    expect(t).toContain('tvg-id="tele5" tvg-name="Telemicro Canal 5" tvg-logo="" tvg-chno="5" group-title="Dominicana"');
    expect(t).toContain(`${origin.url}/ok/playlist.m3u8|Referer=https://telemicro.com.do/players/5tv/&Origin=https://telemicro.com.do`);
    expect(t).toContain('https://play.test/dm/x7gy059.m3u8');                                   // Dailymotion → Worker
    expect(t).toContain('catchup="append" catchup-source="?utc={utc}" catchup-days="2"');
    expect((await call(`/p/${tokenA}.m3u`, env, { headers: { 'If-None-Match': r.headers.get('etag')! } })).status).toBe(304);
    expect(await (await call(`/p/${tokenA}.vlc.m3u`, env)).text()).toContain('#EXTVLCOPT:http-referrer=https://telemicro.com.do/players/5tv/');
  });
});

describe('botón «Forzar sincronización» y barra de estado', () => {
  it('sync crea un trabajo y los clics repetidos se fusionan; otro usuario no puede', async () => {
    _resetRateLimits();
    const r1: any = await (await call('/api/sync', env, { method: 'POST', token: tA, json: { playlist_id: plA } })).json();
    const r2: any = await (await call('/api/sync', env, { method: 'POST', token: tA, json: { playlist_id: plA } })).json();
    expect(r1).toMatchObject({ status: 'queued', deduped: false }); expect(r2).toMatchObject({ deduped: true, job_id: r1.job_id });
    expect((await call('/api/sync', env, { method: 'POST', token: tB, json: { playlist_id: plA } })).status).toBe(403);
    expect((await call('/api/sync', env, { method: 'POST', token: tA, json: { playlist_id: 'no-uuid' } })).status).toBe(400);
  });
  it('/api/status: worker + db + contadores', async () => {
    const j: any = await (await call(`/api/status?playlist_id=${plA}`, env, { token: tA })).json();
    expect(j).toMatchObject({ worker: 'ok', db: 'ok' }); expect(j.counts.unknown).toBe(5); expect(j.last_job.kind).toBe('full');
  });
});

describe('«Probar» desde la tabla: sondeo real → strikes reales', () => {
  it('fuente sana → estado ok y semáforo verde en la vista de la tabla', async () => {
    const r: any = await (await call(`/api/probe/source/${srcOk}`, env, { method: 'POST', token: tA })).json();
    expect(r.ok).toBe(true); expect(r.health).toMatchObject({ state: 'ok', strikes: 0 });
    const v: any[] = await (await rest(`/rest/v1/v_channels_table?id=eq.${sql(`select channel_id from public.channel_sources where id='${srcOk}'`)}&select=health,latency_ms`, tA)).json();
    expect(v[0].health).toBe('ok');
  });
  it('404 desde el Worker = strike firme (amarillo) y deja línea en la consola', async () => {
    const r: any = await (await call(`/api/probe/source/${srcDead}`, env, { method: 'POST', token: tA })).json();
    expect(r.ok).toBe(false); expect(r.hint).toMatch(/caducada/); expect(r.health).toMatchObject({ state: 'suspect', strikes: 1, strike_applied: true });
    const logs: any[] = await (await rest('/rest/v1/engine_logs?select=message&order=id.desc&limit=5', tA)).json();
    expect(logs.map((l) => l.message).join('|')).toContain('Strike 1/3 aplicado a Canal Muerto');
    const again: any = await (await call(`/api/probe/source/${srcDead}`, env, { method: 'POST', token: tA })).json();
    expect(again.health).toMatchObject({ strikes: 1, strike_applied: false });                    // espaciado de 30 min
  });
  it('sin conexión desde el Worker = fallo BLANDO: no suma strike (otra región)', async () => {
    const r: any = await (await call(`/api/probe/source/${srcFail}`, env, { method: 'POST', token: tA })).json();
    expect(r.ok).toBe(false); expect(r.health).toMatchObject({ state: 'unverified', strikes: 0 });
  });
  it('otro usuario no puede sondear fuentes ajenas', async () => {
    expect((await call(`/api/probe/source/${srcOk}`, env, { method: 'POST', token: tB })).status).toBe(404);
  });
  it('failover en la M3U: principal caída + alterna sana → el Worker publica la alterna con SU referer', async () => {
    sql(`insert into public.source_health(source_id,channel_id,playlist_id,owner_id,state,strikes)
           select s.id,s.channel_id,s.playlist_id,s.owner_id,'down',3 from public.channel_sources s where s.channel_id='${chFo}' and s.priority=0
         on conflict (source_id) do update set state='down', strikes=3;`);
    const alt = sql(`select id from public.channel_sources where channel_id='${chFo}' and priority=1`);
    await call(`/api/probe/source/${alt}`, env, { method: 'POST', token: tA });
    _resetM3uCache();
    const t = await (await call(`/p/${tokenA}.m3u`, env)).text();
    expect(t).toContain(`${origin.url}/ok/playlist.m3u8|Referer=https://alt.example/&Origin=https://alt.example`);
    expect(t).not.toContain('no-existe2');
  });
});

describe('exportar y mantenimiento', () => {
  it('export json y csv (solo tus canales)', async () => {
    const j: any = await (await call(`/api/export?playlist_id=${plA}`, env, { token: tA })).json();
    expect(j.items).toHaveLength(5); expect(j.items.find((i: any) => i.tvg_id === 'fo').sources).toHaveLength(2);
    const csv = await (await call(`/api/export?playlist_id=${plA}&format=csv`, env, { token: tA })).text();
    expect(csv.split('\n')[0]).toBe('name,group,epg_id,url,alt_url,referer'); expect(csv.split('\n')).toHaveLength(6);
    expect(((await (await call(`/api/export?playlist_id=${plA}`, env, { token: tB })).json()) as any).items).toHaveLength(0);
  });
  it('tarea programada: purge_old_data funciona con la clave de servicio', async () => {
    await expect(Promise.resolve(app.scheduled({} as any, env, { waitUntil: (p: Promise<unknown>) => p.then(() => {}) } as any))).resolves.not.toThrow();
  });
});
