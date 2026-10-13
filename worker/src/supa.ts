import type { Env } from './types';
import { HttpError } from './util';

export interface Auth { service?: boolean; jwt?: string }

function headers(env: Env, a: Auth): Record<string, string> {
  const key = a.service ? env.SUPABASE_SERVICE_KEY : env.SUPABASE_ANON_KEY;
  return { apikey: key, Authorization: `Bearer ${a.service ? env.SUPABASE_SERVICE_KEY : (a.jwt ?? env.SUPABASE_ANON_KEY)}`, 'Content-Type': 'application/json' };
}

async function handle(res: Response): Promise<any> {
  const text = await res.text();
  if (!res.ok) {
    let msg = text; try { msg = JSON.parse(text).message ?? text; } catch { /* texto plano */ }
    const status = res.status === 401 || res.status === 403 ? 403 : res.status === 404 ? 404 : res.status >= 500 ? 502 : 400;
    throw new HttpError(status, 'db_error', String(msg).slice(0, 300));
  }
  return text ? JSON.parse(text) : null;
}

export async function rpc<T = any>(env: Env, fn: string, args: object, a: Auth): Promise<T> {
  return handle(await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: headers(env, a), body: JSON.stringify(args) }));
}

export async function select<T = any>(env: Env, path: string, a: Auth): Promise<T> {
  return handle(await fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, { headers: headers(env, a) }));
}
