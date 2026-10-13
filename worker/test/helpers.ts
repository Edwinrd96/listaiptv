import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { SignJWT } from 'jose';
import { app } from '../src/index';
import type { Env } from '../src/types';

export const SECRET = 'test-secret-test-secret-test-secret-123456';
export async function jwt(claims: Record<string, unknown>, secret = SECRET) {
  return new SignJWT(claims).setProtectedHeader({ alg: 'HS256' }).setIssuedAt().setExpirationTime('2h').sign(new TextEncoder().encode(secret));
}
export const userJwt = (sub: string) => jwt({ sub, role: 'authenticated', aud: 'authenticated' });

export async function startServer(handler: (req: http.IncomingMessage, res: http.ServerResponse) => void) {
  const server = http.createServer(handler);
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  return { url: `http://127.0.0.1:${port}`, port, close: () => new Promise<void>((r) => { server.closeAllConnections?.(); server.close(() => r()); }) };
}

export const ctx = { waitUntil: (_p: Promise<unknown>) => {}, passThroughOnException() {} } as any;
export function baseEnv(over: Partial<Env> = {}): Env {
  return { SUPABASE_URL: 'http://127.0.0.1:3000', SUPABASE_ANON_KEY: 'anon', SUPABASE_SERVICE_KEY: 'service', SIGNING_SECRET: 'signing-secret-for-tests',
           ALLOWED_ORIGINS: 'http://localhost:5173', ALLOW_PRIVATE_HOSTS: '1', ...over } as Env;
}
export function call(path: string, env: Env, init: RequestInit & { json?: unknown; token?: string; origin?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set('Authorization', `Bearer ${init.token}`);
  if (init.json !== undefined) { headers.set('Content-Type', 'application/json'); init.body = JSON.stringify(init.json); }
  if (init.origin) headers.set('Origin', init.origin);
  return app.fetch(new Request(`https://play.test${path}`, { ...init, headers }), env, ctx);
}
export const HLS = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nseg1.ts\n';
export const MASTER = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2"\nmedia.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nlow.m3u8\n';
