// Enrutador de resolvedores: extractor genérico, YouTube solo-motor, resolvedores apagados por el admin.
import { execSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { _resetCandCache, _resetM3uCache } from '../src/index';
import { _resetGeneric, findM3u8, resolverKey } from '../src/resolvers';
import { _resetRateLimits } from '../src/util';
import { baseEnv, call, jwt, startServer, userJwt } from './helpers';

const R = 'dddddddd-0000-0000-0000-000000000007';
const sql = (q: string) => { writeFileSync('/tmp/q_res.sql', q); return execSync('su postgres -c "psql -At -q -v ON_ERROR_STOP=1 -d iptvtest -f /tmp/q_res.sql"').toString().trim(); };
const rest = (path: string, token: string, body: unknown) =>
  fetch(`http://127.0.0.1:3100${path}`, { method: 'POST', body: JSON.stringify(body), headers: { 'Content-Type': 'application/json', apikey: 'x', Authorization: `Bearer ${token}` } });
const fresh = () => { _resetM3uCache(); _resetCandCache(); _resetRateLimits(); _resetGeneric(); };

let env: ReturnType<typeof baseEnv>; let tok = ''; let origin: Awaited<ReturnType<typeof startServer>>; let hits = 0; let mode = 'ok';

beforeAll(async () => {
  origin = await startServer((req, res) => {
    hits++;
    if (req.url === '/page') {
      if (mode === 'empty') { res.end('<html>nada</html>'); return; }
      res.setHeader('Content-Type', 'text/html'); res.end(`<script>var cfg={"src":"https:\\/\\/cdn.example.test\\/live\\/index.m3u8?tk=abc\\u0026e=9"}</script>`); return;
    }
    res.statusCode = 404; res.end();
  });
  env = baseEnv({ SUPABASE_URL: 'http://127.0.0.1:3100', SUPABASE_ANON_KEY: await jwt({ role: 'anon' }), SUPABASE_SERVICE_KEY: await jwt({ role: 'service_role' }),
                  SUPABASE_JWT_SECRET: 'test-secret-test-secret-test-secret-123456' });
  sql(`insert into auth.users(id,email) values ('${R}','r@x.com'); insert into public.manual_grants(user_id, reason, expires_at) values ('${R}','test', now() + interval '1 day');`);
  const pl = sql(`select id from public.playlists where owner_id='${R}'`);
  tok = sql(`select token from public.outputs where playlist_id='${pl}'`);
  const t = await userJwt(R);
  const items = [
    { tvg_id: 'gen', name: 'Genérico', group: 'X', sources: [{ url: `${origin.url}/page`, resolver: 'generic' }] },
    { tvg_id: 'yt', name: 'YouTube', group: 'X', sources: [{ url: 'https://www.youtube.com/watch?v=abc', resolver: 'youtube' }, { url: 'https://backup.test/yt.m3u8' }] },
    { tvg_id: 'yt_only', name: 'YouTube solo', group: 'X', sources: [{ url: 'https://www.youtube.com/watch?v=zzz', resolver: 'youtube' }] },
    { tvg_id: 'gen2', name: 'Genérico con respaldo', group: 'X', sources: [{ url: `${origin.url}/page`, resolver: 'generic' }, { url: 'https://backup.test/g.m3u8' }] },
  ];
  const r = await (await rest('/rest/v1/rpc/bulk_upsert_channels', t, { p_playlist: pl, p_items: items })).json() as any;
  expect(r.inserted).toBe(4);
  sql(`update public.outputs set delivery='smart' where playlist_id='${pl}'`);
});
afterAll(async () => { sql(`update public.resolvers set enabled=true`); await origin.close(); });

describe('findM3u8 / resolverKey', () => {
  it('encuentra .m3u8 en JSON con barras escapadas, en HTML y relativos', () => {
    expect(findM3u8('{"u":"https:\\/\\/a.test\\/x\\/i.m3u8?t=1\\u0026e=2"}', 'https://p.test/')).toBe('https://a.test/x/i.m3u8?t=1&e=2');
    expect(findM3u8('<source src="//cdn.test/a.m3u8">', 'https://p.test/')).toBe('https://cdn.test/a.m3u8');
    expect(findM3u8('<video src="/live/b.m3u8"></video>', 'https://p.test/page')).toBe('https://p.test/live/b.m3u8');
    expect(findM3u8('nada que ver', 'https://p.test/')).toBeNull();
  });
  it('elige el resolvedor por columna o por tipo', () => {
    expect(resolverKey({ resolver: 'generic', kind: 'direct' })).toBe('generic');
    expect(resolverKey({ resolver: null, kind: 'dailymotion' })).toBe('dailymotion');
    expect(resolverKey({ resolver: null, kind: 'youtube' })).toBe('youtube');
    expect(resolverKey({ resolver: 'inventado', kind: 'direct' })).toBe('direct');
  });
});

describe('/p/:token/play con resolvedores', () => {
  it('generic: redirige a la URL fresca encontrada en la página y la cachea', async () => {
    fresh(); hits = 0; mode = 'ok';
    const r = await call(`/p/${tok}/play/gen`, env, { redirect: 'manual' });
    expect(r.status).toBe(302); expect(r.headers.get('Location')).toBe('https://cdn.example.test/live/index.m3u8?tk=abc&e=9');
    _resetCandCache(); _resetRateLimits();
    await call(`/p/${tok}/play/gen`, env, { redirect: 'manual' });
    expect(hits).toBe(1);                                    // segunda vez: caché, no vuelve a la página
  });
  it('generic sin .m3u8 → 502; con respaldo pasa al respaldo', async () => {
    fresh(); mode = 'empty';
    expect((await call(`/p/${tok}/play/gen`, env, { redirect: 'manual' })).status).toBe(502);
    fresh(); mode = 'empty';
    const r = await call(`/p/${tok}/play/gen2`, env, { redirect: 'manual' });
    expect(r.status).toBe(302); expect(r.headers.get('Location')).toBe('https://backup.test/g.m3u8');
  });
  it('youtube es solo-motor: nunca se entrega; usa el respaldo, y sin respaldo da 502', async () => {
    fresh();
    const r = await call(`/p/${tok}/play/yt`, env, { redirect: 'manual' });
    expect(r.status).toBe(302); expect(r.headers.get('Location')).toBe('https://backup.test/yt.m3u8');
    fresh(); expect((await call(`/p/${tok}/play/yt_only`, env, { redirect: 'manual' })).status).toBe(502);
  });
  it('un resolvedor apagado por el admin se salta', async () => {
    mode = 'ok'; sql(`update public.resolvers set enabled=false where key='generic'`);
    fresh(); const r = await call(`/p/${tok}/play/gen2`, env, { redirect: 'manual' });
    expect(r.status).toBe(302); expect(r.headers.get('Location')).toBe('https://backup.test/g.m3u8');
    sql(`update public.resolvers set enabled=true where key='generic'`);
  });
});
