import { createRemoteJWKSet, jwtVerify } from 'jose';
import type { MiddlewareHandler } from 'hono';
import type { AppEnv, Env } from './types';
import { HttpError } from './util';

const jwksCache = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

export async function verifyUserJwt(env: Env, token: string): Promise<{ sub: string }> {
  try {
    let payload;
    if (env.SUPABASE_JWT_SECRET) {
      ({ payload } = await jwtVerify(token, new TextEncoder().encode(env.SUPABASE_JWT_SECRET), { algorithms: ['HS256'] }));
    } else {
      const url = `${env.SUPABASE_URL}/auth/v1/.well-known/jwks.json`;
      if (!jwksCache.has(url)) jwksCache.set(url, createRemoteJWKSet(new URL(url), { cooldownDuration: 30_000 }));
      ({ payload } = await jwtVerify(token, jwksCache.get(url)!, { issuer: `${env.SUPABASE_URL}/auth/v1` }));
    }
    if (payload.role !== 'authenticated' || typeof payload.sub !== 'string') throw new Error('rol inválido');
    return { sub: payload.sub };
  } catch (e: any) {
    throw new HttpError(401, 'unauthorized', 'Sesión inválida o caducada');
  }
}

export const requireUser: MiddlewareHandler<AppEnv> = async (c, next) => {
  const h = c.req.header('Authorization') ?? '';
  const jwt = h.startsWith('Bearer ') ? h.slice(7) : '';
  if (!jwt) throw new HttpError(401, 'unauthorized', 'Falta el token');
  const { sub } = await verifyUserJwt(c.env, jwt);
  c.set('user', { sub, jwt });
  await next();
};
