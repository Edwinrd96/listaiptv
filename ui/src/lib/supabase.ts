import { createClient } from '@supabase/supabase-js';

export const env = {
  url: (import.meta.env.VITE_SUPABASE_URL as string | undefined) ?? '',
  anon: (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined) ?? '',
  worker: ((import.meta.env.VITE_WORKER_URL as string | undefined) ?? '').replace(/\/$/, ''),
};
export const configured = !!env.url && !!env.anon;
export const supabase = createClient(env.url || 'http://localhost:54321', env.anon || 'anon', {
  auth: { persistSession: true, autoRefreshToken: true },
  realtime: { params: { eventsPerSecond: 10 } },
});
