export interface Env {
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
  SUPABASE_SERVICE_KEY: string;
  SUPABASE_JWT_SECRET?: string;      // HS256 (proyectos con clave compartida). Si falta se usa JWKS (claves asimétricas)
  SIGNING_SECRET: string;            // firma sesiones de prueba y URLs de logos
  ALLOWED_ORIGINS?: string;          // "https://panel.tudominio.com,http://localhost:5173"
  ALLOWED_DM_IDS?: string;           // "x7gy059,x8mwmvs"  (opcional: solo resuelve tus canales)
  PLAYER_PROXY_ENABLED?: string;     // "false" desactiva el proxy del reproductor (protege la cuota gratis)
  GITHUB_DISPATCH_TOKEN?: string;
  GITHUB_REPO?: string;              // "usuario/repositorio"
  GITHUB_WORKFLOW?: string;          // "engine.yml"
  ALLOW_PRIVATE_HOSTS?: string;      // "1" SOLO en desarrollo/tests (desactiva la protección SSRF)
  EPG_BUCKET?: R2Bucket;
  EPG_PUBLIC_BASE?: string;          // alternativa a R2 (VPS/MinIO/CDN): URL base pública donde el motor deja los epg/<lista>.xml.gz
  BILLING_WEBHOOK_SECRET?: string;   // secreto de firma del webhook del Merchant of Record (Lemon Squeezy / Paddle)
}

export interface User { sub: string; jwt: string }
export type AppEnv = { Bindings: Env; Variables: { user: User } };

export interface Drm { type: 'clearkey' | 'widevine' | 'playready'; keys?: string; license_url?: string }
export interface HeaderProfile { ua?: string; headers?: Record<string, string> }
export interface Source {
  url: string; referer?: string | null; ua?: string | null; kind?: string; resolve_ref?: string | null; state?: string;
  drm?: Drm | null; stream_format?: string | null; extra_headers?: Record<string, string> | null; header_profile?: string | null; profile?: HeaderProfile | null;
}
export interface PayloadChannel {
  tvg_id: string; name: string; logo?: string | null; group: string; epg_id?: string | null; chno?: number | null; lang?: string | null;
  catchup?: { type: string; source?: string | null; days?: number | null } | null; fallbacks?: number; source: Source;
}
export interface Payload {
  playlist: { id: string; name: string; version: number; settings: Record<string, any> };
  output: { id: string; format: 'm3u' | 'm3u_vlc' | 'txt' | 'enigma2'; only_healthy: boolean; delivery?: 'direct' | 'smart'; extra_formats?: boolean };
  channels: PayloadChannel[];
}

export interface PlayCandidate extends Source { source_id: string; resolver?: string | null }
export interface PlayCandidates { delivery: 'direct' | 'smart'; candidates: PlayCandidate[]; disabled_resolvers?: string[] }
