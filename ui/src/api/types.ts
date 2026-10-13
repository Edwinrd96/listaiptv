export type Health = 'ok' | 'warn' | 'down' | 'unverified' | 'unknown' | 'unchecked';

export interface ChannelRow {
  id: string; playlist_id: string; tvg_id: string; name: string; logo_url: string | null; logo_status: string;
  group_id: string | null; group_name: string; epg_id: string | null; chno: number | null; enabled: boolean; check_enabled: boolean;
  catchup_enabled: boolean; sort_order: number; primary_url: string | null; alt_url: string | null; primary_state: string | null;
  strikes: number; strikes_to_down: number; latency_ms: number | null; last_checked_at: string | null;
  quality: { height?: number | null; bandwidth?: number | null } | null; health: Health;
}

export interface Entitlements {
  plan: 'free' | 'pro'; billing_mode: 'off' | 'preview' | 'live'; level: number; xp: number;
  next_level: { level: number; name: string; xp_needed: number } | null;
  features: Record<string, number | boolean>;
  founder: { until: string | null; discount_pct: number } | null;
}

export interface EngineLog { id: number; at: string; level: 'debug' | 'info' | 'warn' | 'error'; message: string; channel_id: string | null }
export interface SyncJob { id: string; status: 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled'; kind: string; requested_at: string; finished_at: string | null; error: string | null }
export interface PlaylistStatus {
  counts: Partial<Record<Health, number>>;
  last_job: SyncJob | null;
  engine: { online: boolean; last_seen_at: string | null; vantage: string | null; version: string | null } | null;
}
export interface PlaylistRow { id: string; name: string; version: number }

export interface SourceRow { id: string; priority: number; url: string; referer: string | null; user_agent: string | null; kind: string; resolver: string | null; vantage_required: string | null }
export interface ChannelFull {
  id: string; playlist_id: string; tvg_id: string; name: string; logo_url: string | null; group_id: string | null; epg_id: string | null; chno: number | null;
  check_enabled: boolean; enabled: boolean; catchup_enabled: boolean; catchup_type: string | null; catchup_source: string | null; catchup_days: number | null;
  channel_sources: SourceRow[]; groups: { name: string } | null;
}
export interface ChannelForm {
  name: string; group: string; logo: string; epg: string; chno: string;
  url1: string; ref1: string; ua1: string; url2: string; ref2: string; ua2: string; res1: string; res2: string; vant: string;
  catchup: boolean; ctype: string; csource: string; cdays: string; check: boolean; enabled: boolean;
}
export interface ProbeReport { ok: boolean; http: number | null; latency_ms: number; variants: { height: number | null; bandwidth: number | null; codecs: string | null }[]; segment_ok: boolean; error: string | null; hint: string | null }

export type OutputFormat = 'm3u' | 'm3u_vlc' | 'txt' | 'enigma2';
export interface OutputRow { id: string; name: string; token: string; format: OutputFormat; delivery: 'direct' | 'smart'; only_healthy: boolean; enabled: boolean }
export type TestState = 'pending' | 'testing' | 'ok' | 'fail' | 'skipped';
export interface ImportItem {
  id: number; idx: number; test_state: TestState; test_http: number | null; test_error: string | null; test_latency_ms: number | null; selected: boolean;
  raw: { name: string; url: string; group?: string; logo?: string }; enriched: { name?: string; group?: string; quality?: string; origin?: 'catalog' | 'rules' | 'none'; catalog_id?: string | null } | null;
}
export interface BatchSummary { status: 'testing' | 'ready' | 'imported' | 'discarded'; counts: Partial<Record<TestState, number>> }

export interface HospitalRow { source_id: string; channel_id: string; channel_name: string; logo_url: string | null; url: string; priority: number; hospital_since: string; dead_at: string | null;
  last_error: string | null; last_http: number | null; last_checked_at: string | null; days_left: number; status: 'in_hospital' | 'dead' }
export interface MyProfile { share_contributions: boolean; tos_accepted_at: string | null; country: string | null }
export interface ContributionRow { channel_id: string; name: string; shareable: boolean; shared: boolean }
export interface CatalogHit { id: string; name: string; category: string | null; country: string | null; logo_url: string | null; epg_id: string | null }
export interface SuggestionRow { id: string; name: string; status: 'pending' | 'accepted' | 'rejected'; reject_reason: string | null; created_at: string; url: string | null }

export interface FlagRow { key: string; description: string | null; free_value: unknown; pro_value: unknown; lower_is_better: boolean; open_during_free_phase: boolean; cost_sensitive: boolean }
export interface SettingRow { key: string; value: unknown; note: string | null; updated_at: string }
export interface AdminOverview { users: number; pro_active: number; manual_grants: number; playlists: number; channels: number; catalog_channels: number; pending_suggestions: number; in_hospital: number; dead: number; billing_mode: 'off' | 'preview' | 'live' }
export interface AdminSuggestion { id: string; name: string; country: string | null; category: string | null; url: string | null; logo_url: string | null; created_at: string; suggestion_submitters: { count: number }[] }
export interface Hotspot { fingerprint: string; reporters: number; reports: number; last_report: string; last_kind: string | null }
export interface FoundUser { user_id: string; email: string; display_name: string | null; plan: string; created_at: string }
export interface AuditRow { id: number; at: string; actor: string | null; action: string; target: string | null; detail: unknown }

export interface AgentRow { id: string; name: string; country: string | null; vantage: string; enabled: boolean; version: string | null; last_seen_at: string | null; created_at: string }
export interface ProxyRow { id: string; name: string; scheme: 'http' | 'https' | 'socks5' | 'socks5h'; host: string; port: number; username: string | null; country: string | null; enabled: boolean;
  last_test_at: string | null; last_ok: boolean | null; last_error: string | null; latency_ms: number | null; exit_country: string | null }
export interface ProxyForm { name: string; scheme: ProxyRow['scheme']; host: string; port: string; username: string; password: string; country: string }
export interface AssignmentRow { id: string; proxy_id: string; scope: 'country' | 'channel' | 'source'; country: string | null; channel_id: string | null; channels: { name: string } | null }

export interface LevelRow { level: number; name: string; min_xp: number; perks_text: string | null }
export interface BadgeRow { key: string; name: string; description: string | null; icon: string | null; hidden: boolean }
export interface MissionRow { key: string; title: string; metric: string; goal: number; xp: number }
export interface UserMissionRow { mission_key: string; progress: number; completed_at: string | null }
export interface XpEvent { id: number; kind: string; xp: number; at: string }
export interface LeaderRow { handle: string; level: number; xp: number }
export interface Progress { levels: LevelRow[]; badges: BadgeRow[]; earned: { badge_key: string; at: string }[]; missions: MissionRow[]; progress: UserMissionRow[]; events: XpEvent[]; leaders: LeaderRow[]; handle: string | null }
export type MvLayout = '1x1' | '1x2' | '2x2' | 'pip' | '1+3';
export interface MvSlot { channel_id: string; name: string; muted: boolean }
export interface MvSaved { id: string; name: string; layout: MvLayout; slots: { channel_id: string; muted?: boolean }[] }

export interface EpgSource { id: string; url: string; enabled: boolean; last_fetched_at: string | null; last_status: string | null; channel_count: number | null }
export interface EpgMeta { channels: number; wanted: number; programmes: number; days: number; missing_sample: string[] }
export interface EpgStatus { artifact: { built_at: string; bytes: number | null; meta: EpgMeta | null } | null; job: SyncJob | null }

export interface PlaylistScore { score: number; channels: number; healthy?: number; logos?: number; epg?: number; fallbacks?: number; categorized?: number }
export interface HealthDay { day: string; checks: number; oks: number; uptime_pct: number | null }
export interface WorstChannel { channel_id: string; name: string; checks: number; uptime_pct: number; avg_ms: number | null }
