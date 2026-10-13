// ÚNICA capa que habla con el backend. Si algún día cambias de Supabase a otra cosa, solo se reescribe esta carpeta.
import { env, supabase } from '../lib/supabase';
import type { AdminOverview, HealthDay, PlaylistScore, WorstChannel, AdminSuggestion, AgentRow, AssignmentRow, AuditRow, BatchSummary, ChannelForm, ChannelFull, ChannelRow, EngineLog, Entitlements, EpgSource, EpgStatus, FlagRow, FoundUser, Hotspot, ImportItem, MvLayout, MvSaved, MvSlot, OutputFormat, OutputRow, PlaylistRow, PlaylistStatus, ProbeReport, Progress, ProxyForm, ProxyRow, SettingRow, SyncJob } from './types';

function must<T>(r: { data: T | null; error: { message: string; code?: string } | null }): T {
  if (r.error) throw Object.assign(new Error(friendly(r.error.message)), { code: r.error.code });
  return r.data as T;
}
/** Los límites del plan llegan como `limit_reached:<función> (…)`: se traducen a un mensaje que dice qué hacer. */
export function friendly(msg: string): string {
  const m = msg.match(/limit_reached:(\w+)/);
  if (!m) return msg;
  const names: Record<string, string> = { max_channels: 'canales', max_playlists: 'listas', max_outputs: 'enlaces de salida', max_alternates: 'URLs alternas',
    max_proxies: 'proxies', max_agents: 'agentes', import_batch_max: 'canales por importación', multiview_slots: 'canales en multivista' };
  return names[m[1]] ? `Llegaste al máximo de ${names[m[1]]} de tu plan. Sube de nivel o mejora a Pro para ampliarlo.` : 'Esta función no está incluida en tu plan.';
}

export async function myPlaylists(): Promise<PlaylistRow[]> {
  return must(await supabase.from('playlists').select('id,name,version').order('created_at'));
}
export async function listChannels(playlistId: string): Promise<ChannelRow[]> {
  const all: ChannelRow[] = [];
  for (let from = 0; ; from += 1000) {                 // PostgREST corta en 1000 filas por petición
    const page = must(await supabase.from('v_channels_table').select('*').eq('playlist_id', playlistId).order('sort_order').range(from, from + 999)) as ChannelRow[];
    all.push(...page);
    if (page.length < 1000) break;
  }
  return all;
}
export async function myEntitlements(): Promise<Entitlements> {
  return must(await supabase.rpc('my_entitlements')) as Entitlements;
}
export async function playlistStatus(playlistId: string): Promise<PlaylistStatus> {
  return must(await supabase.rpc('playlist_status', { p_playlist: playlistId })) as PlaylistStatus;
}
/** null = el Worker no está configurado (no es un fallo). */
export async function workerHealth(): Promise<boolean | null> {
  if (!env.worker) return null;
  const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 3000);
  try { return (await fetch(`${env.worker}/health`, { signal: ctl.signal, cache: 'no-store' })).ok; } catch { return false; } finally { clearTimeout(t); }
}
export async function dbHealth(): Promise<boolean> {
  const t0 = performance.now();
  const r = await Promise.race([supabase.from('plans').select('key', { head: true, count: 'exact' }), new Promise<{ error: Error }>((res) => setTimeout(() => res({ error: new Error('timeout') }), 3000))]);
  return !(r as { error: unknown }).error && performance.now() - t0 < 3000;
}
/** Con Worker configurado se usa /api/sync (también despierta al motor en GitHub Actions); sin él, directo a la base. */
export async function requestSync(playlistId: string, kind: 'full' | 'epg' = 'full'): Promise<{ job_id: string; status: string; deduped: boolean }> {
  if (env.worker) {
    const { data } = await supabase.auth.getSession();
    try {
      const r = await fetch(`${env.worker}/api/sync`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${data.session?.access_token ?? ''}` }, body: JSON.stringify({ playlist_id: playlistId, kind }) });
      if (r.ok) return await r.json();
    } catch { /* cae al RPC directo */ }
  }
  const rows = must(await supabase.rpc('request_sync', { p_playlist: playlistId, p_kind: kind })) as { job_id: string; status: string; deduped: boolean }[];
  return rows[0];
}
export async function recentLogs(playlistId: string, limit = 200): Promise<EngineLog[]> {
  const rows = must(await supabase.from('engine_logs').select('id,at,level,message,channel_id').eq('playlist_id', playlistId).order('id', { ascending: false }).limit(limit)) as EngineLog[];
  return rows.reverse();
}
export async function latestJob(playlistId: string): Promise<SyncJob | null> {
  const rows = must(await supabase.from('sync_jobs').select('id,status,kind,requested_at,finished_at,error').eq('playlist_id', playlistId).neq('kind', 'epg').order('requested_at', { ascending: false }).limit(1)) as SyncJob[];
  return rows[0] ?? null;
}
/** Tiempo real por Realtime (respeta RLS). Devuelve una función para cancelar. */
export function subscribe(playlistId: string, on: { logs?: (l: EngineLog) => void; health?: () => void; job?: () => void }): () => void {
  const f = `playlist_id=eq.${playlistId}`;
  const ch = supabase.channel(`pl-${playlistId}`)
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'engine_logs', filter: f }, (p) => on.logs?.(p.new as EngineLog))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'source_health', filter: f }, () => on.health?.())
    .on('postgres_changes', { event: '*', schema: 'public', table: 'sync_jobs', filter: f }, () => on.job?.())
    .subscribe();
  return () => { void supabase.removeChannel(ch); };
}

// ------------------------------------------------------------------ edición de canales

export async function getChannel(id: string): Promise<ChannelFull> {
  const r = must(await supabase.from('channels').select('*, channel_sources(id,priority,url,referer,user_agent,kind,resolver,vantage_required), groups(name)').eq('id', id).single());
  const c = r as unknown as ChannelFull; c.channel_sources.sort((a, b) => a.priority - b.priority); return c;
}
export async function listGroups(playlistId: string): Promise<string[]> {
  return (must(await supabase.from('groups').select('name').eq('playlist_id', playlistId).order('sort_order')) as { name: string }[]).map((g) => g.name);
}
const slug = (t: string) => t.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'canal';
const nn = (v: string) => (v.trim() === '' ? null : v.trim());

export async function saveChannel(playlistId: string, f: ChannelForm, existing?: ChannelFull): Promise<string> {
  let groupId: string | null = null;
  if (f.group.trim()) {
    await supabase.from('groups').upsert({ playlist_id: playlistId, name: f.group.trim() }, { onConflict: 'playlist_id,name', ignoreDuplicates: true });
    groupId = (must(await supabase.from('groups').select('id').eq('playlist_id', playlistId).eq('name', f.group.trim()).single()) as { id: string }).id;
  }
  const row = {
    name: f.name.trim(), logo_url: nn(f.logo), group_id: groupId, epg_id: nn(f.epg), chno: f.chno.trim() ? Number(f.chno) : null,
    check_enabled: f.check, enabled: f.enabled, catchup_enabled: f.catchup,
    catchup_type: f.catchup ? f.ctype : null, catchup_source: f.catchup ? nn(f.csource) : null, catchup_days: f.catchup && f.cdays.trim() ? Number(f.cdays) : null,
  };
  let id = existing?.id;
  try {
    if (id) must(await supabase.from('channels').update(row).eq('id', id));
    else id = (must(await supabase.from('channels').insert({ ...row, playlist_id: playlistId, tvg_id: `${slug(f.name)}-${Math.random().toString(36).slice(2, 6)}` }).select('id').single()) as { id: string }).id;
  } catch (e) { throw e; }
  for (const [pr, url, ref, ua, res] of [[0, f.url1, f.ref1, f.ua1, f.res1], [1, f.url2, f.ref2, f.ua2, f.res2]] as const) {
    if (url.trim()) must(await supabase.from('channel_sources').upsert({ channel_id: id, priority: pr, url: url.trim(), referer: nn(ref), user_agent: nn(ua), resolver: nn(res), vantage_required: nn(f.vant) }, { onConflict: 'channel_id,priority' }));
    else if (existing) must(await supabase.from('channel_sources').delete().eq('channel_id', id!).eq('priority', pr));
  }
  return id!;
}
export async function deleteChannel(id: string): Promise<void> { must(await supabase.from('channels').delete().eq('id', id)); }
export async function searchEpg(playlistId: string, q: string): Promise<{ guide_id: string; display_name: string }[]> {
  if (q.trim().length < 2) return [];
  return must(await supabase.rpc('search_epg', { p_playlist: playlistId, p_q: q, p_limit: 6 })) as { guide_id: string; display_name: string }[];
}

// ------------------------------------------------------------------ Worker: probar y reproducir
async function workerFetch<T>(path: string, body: unknown): Promise<T> {
  if (!env.worker) throw new Error('Esta función necesita el Worker. Define VITE_WORKER_URL en el .env del panel.');
  const { data } = await supabase.auth.getSession();
  const r = await fetch(`${env.worker}${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${data.session?.access_token ?? ''}` }, body: JSON.stringify(body) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j?.error?.message ?? `El Worker respondió HTTP ${r.status}`);
  return j as T;
}
export const probeUrl = (url: string, referer?: string, user_agent?: string) => workerFetch<ProbeReport>('/api/probe', { url, referer: referer || undefined, user_agent: user_agent || undefined });
export const playSession = (b: { url: string; referer?: string; user_agent?: string }) => workerFetch<{ play_url: string; expires_at: string; max_seconds?: number }>('/api/play-session', b);
export const validateLogoRemote = (url: string) => workerFetch<{ ok: boolean; error?: string }>('/api/validate/logo', { url });
export async function primarySource(channelId: string): Promise<SourceRowLite | null> {
  const r = must(await supabase.from('channel_sources').select('url,referer,user_agent').eq('channel_id', channelId).eq('enabled', true).order('priority').limit(1)) as SourceRowLite[];
  return r[0] ?? null;
}
export interface SourceRowLite { url: string; referer: string | null; user_agent: string | null }

// ------------------------------------------------------------------ enlaces de salida ("Obtener lista")
export async function myOutputs(playlistId: string): Promise<OutputRow[]> {
  return must(await supabase.from('outputs').select('id,name,token,format,delivery,only_healthy,enabled').eq('playlist_id', playlistId).order('created_at'));
}
export async function createOutput(playlistId: string, name: string): Promise<OutputRow> {
  return must(await supabase.from('outputs').insert({ playlist_id: playlistId, name }).select('id,name,token,format,delivery,only_healthy,enabled').single());
}
export async function updateOutput(id: string, patch: Partial<Pick<OutputRow, 'name' | 'format' | 'delivery' | 'only_healthy' | 'enabled'>>): Promise<void> {
  must(await supabase.from('outputs').update(patch).eq('id', id));
}
export async function deleteOutput(id: string): Promise<void> { must(await supabase.from('outputs').delete().eq('id', id)); }
export async function rotateToken(id: string): Promise<string> { return must(await supabase.rpc('rotate_output_token', { p_output: id })) as string; }
/** URL pública del archivo. Variantes: .m3u (estándar), .vlc.m3u (cabeceras para VLC), .txt, .e2 (Enigma2). */
export function outputUrl(token: string, kind: 'm3u' | 'vlc' | 'txt' | 'e2' | 'epg'): string {
  const ext = { m3u: '.m3u', vlc: '.vlc.m3u', txt: '.txt', e2: '.e2', epg: '/epg.xml.gz' }[kind];
  return `${env.worker || '<URL-DE-TU-WORKER>'}/p/${token}${ext}`;
}
export type { OutputFormat };

// ------------------------------------------------------------------ importador con pruebas en vivo
export interface RawImportItem { name: string; url: string; group?: string; logo?: string; tvg_id?: string; referer?: string; ua?: string }
export async function createImportBatch(playlistId: string, items: RawImportItem[], label: string, test = true): Promise<{ batch_id: string; total: number; enriched: boolean }> {
  return must(await supabase.rpc('create_import_batch', { p_playlist: playlistId, p_items: items, p_label: label, p_test: test })) as { batch_id: string; total: number; enriched: boolean };
}
export async function batchSummary(id: string): Promise<BatchSummary> { return must(await supabase.rpc('import_batch_summary', { p_batch: id })) as BatchSummary; }
export async function batchItems(id: string): Promise<ImportItem[]> {
  const all: ImportItem[] = [];
  for (let from = 0; ; from += 1000) {
    const page = must(await supabase.from('import_items').select('id,idx,test_state,test_http,test_error,test_latency_ms,selected,raw,enriched').eq('batch_id', id).order('idx').range(from, from + 999)) as ImportItem[];
    all.push(...page); if (page.length < 1000) break;
  }
  return all;
}
export async function setItemsSelected(ids: number[], selected: boolean): Promise<void> {
  for (let i = 0; i < ids.length; i += 200) must(await supabase.from('import_items').update({ selected }).in('id', ids.slice(i, i + 200)));
}
export const commitBatch = async (id: string, onlyOk: boolean, enrich: boolean) =>
  must(await supabase.rpc('commit_import_batch', { p_batch: id, p_only_ok: onlyOk, p_apply_enrichment: enrich })) as { channels: number };
export async function discardBatch(id: string): Promise<void> { must(await supabase.rpc('discard_import_batch', { p_batch: id })); }

// ------------------------------------------------------------------ Hospital de Canales
export async function hospital(playlistId: string): Promise<import('./types').HospitalRow[]> {
  return must(await supabase.from('v_hospital').select('*').eq('playlist_id', playlistId).order('hospital_since')) as import('./types').HospitalRow[];
}

// ------------------------------------------------------------------ Comunidad: privacidad, aportes y catálogo
/** Id del usuario desde la sesión local (no hace una petición de red extra). */
async function myId(): Promise<string> {
  const { data } = await supabase.auth.getSession();
  if (!data.session) throw new Error('Tu sesión expiró. Vuelve a entrar.');
  return data.session.user.id;
}
export async function myProfile(): Promise<import('./types').MyProfile> {
  const uid = await myId();
  return must(await supabase.from('profiles').select('share_contributions,tos_accepted_at,country').eq('id', uid).single()) as import('./types').MyProfile;
}
export async function setShareContributions(v: boolean): Promise<void> {
  must(await supabase.from('profiles').update({ share_contributions: v }).eq('id', await myId()));
}
export async function acceptTos(): Promise<void> { must(await supabase.rpc('accept_tos', {})); }
export async function contributionPreview(playlistId: string): Promise<import('./types').ContributionRow[]> {
  return must(await supabase.rpc('contribution_preview', { p_playlist: playlistId })) as import('./types').ContributionRow[];
}
export async function shareMetaOnly(channelId: string): Promise<void> { must(await supabase.rpc('suggest_channel_meta', { p_channel: channelId })); }
export async function searchCatalog(q: string): Promise<import('./types').CatalogHit[]> {
  const t = q.trim().replace(/[%,()]/g, ' ');
  let req = supabase.from('catalog_channels').select('id,name,category,country,logo_url,epg_id').eq('status', 'approved').order('name').limit(40);
  if (t) req = req.ilike('name', `%${t}%`);
  return must(await req) as import('./types').CatalogHit[];
}
export const importFromCatalog = async (playlistId: string, ids: string[]) => must(await supabase.rpc('import_from_catalog', { p_playlist: playlistId, p_catalog_ids: ids })) as Record<string, number>;
export async function mySuggestions(): Promise<import('./types').SuggestionRow[]> {
  return must(await supabase.from('channel_suggestions').select('id,name,status,reject_reason,created_at,url').order('created_at', { ascending: false }).limit(100)) as import('./types').SuggestionRow[];
}

// ------------------------------------------------------------------ Administración (cada RPC comprueba is_admin() en la base: esto solo decide qué se muestra)
export async function isAdmin(): Promise<boolean> { const r = await supabase.rpc('is_admin'); return !r.error && r.data === true; }
export async function adminOverview(): Promise<AdminOverview> { return must(await supabase.rpc('admin_overview')) as AdminOverview; }
export async function listFlags(): Promise<FlagRow[]> { return must(await supabase.from('feature_flags').select('*').order('key')) as FlagRow[]; }
export async function setFlag(key: string, patch: { free?: unknown; pro?: unknown; open?: boolean }): Promise<void> {
  must(await supabase.rpc('admin_set_flag', { p_key: key, p_free: patch.free ?? null, p_pro: patch.pro ?? null, p_open: patch.open ?? null }));
}
export async function listSettings(): Promise<SettingRow[]> { return must(await supabase.from('app_settings').select('*').order('key')) as SettingRow[]; }
export async function setSetting(key: string, value: unknown): Promise<void> { must(await supabase.rpc('admin_set_setting', { p_key: key, p_value: value })); }
export async function activateBilling(): Promise<{ billing_mode: string; founders_granted: number }> { return must(await supabase.rpc('admin_activate_billing')) as { billing_mode: string; founders_granted: number }; }
export async function pendingSuggestions(): Promise<AdminSuggestion[]> {
  return must(await supabase.from('channel_suggestions').select('id,name,country,category,url,logo_url,created_at,suggestion_submitters(count)').eq('status', 'pending').order('created_at').limit(200)) as unknown as AdminSuggestion[];
}
export async function acceptSuggestion(id: string): Promise<void> { must(await supabase.rpc('admin_accept_suggestion', { p_id: id })); }
export async function rejectSuggestion(id: string, reason: string): Promise<void> { must(await supabase.rpc('admin_reject_suggestion', { p_id: id, p_reason: reason || null })); }
export async function hotspots(min = 2): Promise<Hotspot[]> { return must(await supabase.rpc('admin_report_hotspots', { p_min: min })) as Hotspot[]; }
export async function findUser(email: string): Promise<FoundUser[]> { return must(await supabase.rpc('admin_find_user', { p_email: email })) as FoundUser[]; }
export async function grantPlan(user: string, days: number, reason: string): Promise<string> { return must(await supabase.rpc('admin_grant_plan', { p_user: user, p_days: days, p_reason: reason || null })) as string; }
export async function auditLog(limit = 100): Promise<AuditRow[]> { return must(await supabase.from('admin_audit').select('*').order('id', { ascending: false }).limit(limit)) as AuditRow[]; }

// ------------------------------------------------------------------ Conexiones propias: agentes (BYON) y proxies (BYOP)
export async function listAgents(): Promise<AgentRow[]> {
  return must(await supabase.from('agents').select('id,name,country,vantage,enabled,version,last_seen_at,created_at').order('created_at')) as AgentRow[];
}
/** El token se devuelve UNA sola vez: la base solo guarda su huella. */
export async function createAgent(name: string, country: string): Promise<{ agent_id: string; token: string }> {
  return must(await supabase.rpc('create_agent', { p_name: name, p_country: country || null })) as { agent_id: string; token: string };
}
export async function setAgentEnabled(id: string, enabled: boolean): Promise<void> { must(await supabase.from('agents').update({ enabled }).eq('id', id)); }
export async function deleteAgent(id: string): Promise<void> { must(await supabase.from('agents').delete().eq('id', id)); }

const PROXY_COLS = 'id,name,scheme,host,port,username,country,enabled,last_test_at,last_ok,last_error,latency_ms,exit_country';
export async function listProxies(): Promise<ProxyRow[]> { return must(await supabase.from('proxies').select(PROXY_COLS).order('created_at')) as ProxyRow[]; }
export async function createProxy(f: ProxyForm): Promise<void> {
  const row = must(await supabase.from('proxies').insert({ name: f.name.trim(), scheme: f.scheme, host: f.host.trim(), port: Number(f.port), username: f.username.trim() || null, country: f.country.trim().toUpperCase() || null }).select('id').single()) as { id: string };
  if (f.password) {
    const r = await supabase.from('proxy_secrets').insert({ proxy_id: row.id, password: f.password });
    if (r.error) { await supabase.from('proxies').delete().eq('id', row.id); throw new Error(friendly(r.error.message)); }
  }
}
export async function setProxyEnabled(id: string, enabled: boolean): Promise<void> { must(await supabase.from('proxies').update({ enabled }).eq('id', id)); }
/** El motor prueba los proxies sin comprobar: «sin comprobar» = last_test_at nulo. */
export async function requestProxyTest(id: string): Promise<void> { must(await supabase.from('proxies').update({ last_test_at: null, last_ok: null, last_error: null }).eq('id', id)); }
export async function deleteProxy(id: string): Promise<void> { must(await supabase.from('proxies').delete().eq('id', id)); }
export async function listAssignments(): Promise<AssignmentRow[]> {
  return must(await supabase.from('proxy_assignments').select('id,proxy_id,scope,country,channel_id,channels(name)').order('scope')) as unknown as AssignmentRow[];
}
export async function assignProxy(proxyId: string, a: { country?: string; channelId?: string }): Promise<void> {
  must(await supabase.from('proxy_assignments').insert(a.channelId ? { proxy_id: proxyId, scope: 'channel', channel_id: a.channelId } : { proxy_id: proxyId, scope: 'country', country: (a.country ?? '').trim().toUpperCase() }));
}
export async function unassignProxy(id: string): Promise<void> { must(await supabase.from('proxy_assignments').delete().eq('id', id)); }
export async function searchMyChannels(playlistId: string, q: string): Promise<{ id: string; name: string }[]> {
  const t = q.trim().replace(/[%,()]/g, ' ');
  return must(await supabase.from('channels').select('id,name').eq('playlist_id', playlistId).ilike('name', `%${t}%`).order('name').limit(8)) as { id: string; name: string }[];
}

// ------------------------------------------------------------------ Logros (XP, insignias, misiones, ranking). Sin dinero: solo reconocimiento y funciones.
export async function loadProgress(): Promise<Progress> {
  const uid = await myId();
  const [levels, badges, earned, missions, progress, events, leaders, me] = await Promise.all([
    supabase.from('levels').select('level,name,min_xp,perks_text').order('level'),
    supabase.from('badges').select('key,name,description,icon,hidden').order('key'),
    supabase.from('user_badges').select('badge_key,at'),
    supabase.from('missions').select('key,title,metric,goal,xp').eq('active', true).order('key'),
    supabase.from('user_missions').select('mission_key,progress,completed_at'),
    supabase.from('xp_events').select('id,kind,xp,at').order('id', { ascending: false }).limit(15),
    supabase.from('v_leaderboard').select('handle,level,xp'),
    supabase.from('profiles').select('handle').eq('id', uid).single(),
  ]);
  return { levels: must(levels), badges: must(badges), earned: must(earned), missions: must(missions), progress: must(progress), events: must(events), leaders: must(leaders), handle: (must(me) as { handle: string | null }).handle } as Progress;
}
/** Alias del ranking público. Vacío = no apareces. */
export async function setHandle(handle: string): Promise<void> {
  const h = handle.trim().toLowerCase();
  if (h && !/^[a-z0-9_]{3,24}$/.test(h)) throw new Error('El alias usa 3 a 24 letras minúsculas, números o guion bajo.');
  const r = await supabase.from('profiles').update({ handle: h || null }).eq('id', await myId());
  if (r.error) throw new Error(r.error.code === '23505' ? 'Ese alias ya lo usa otra persona.' : friendly(r.error.message));
}

// ------------------------------------------------------------------ Multivista
export async function listLayouts(): Promise<MvSaved[]> { return must(await supabase.from('multiview_layouts').select('id,name,layout,slots').order('created_at')) as MvSaved[]; }
export async function saveLayout(name: string, layout: MvLayout, slots: MvSlot[]): Promise<void> {
  must(await supabase.from('multiview_layouts').insert({ name: name.trim(), layout, slots: slots.map((s) => ({ channel_id: s.channel_id, muted: s.muted })) }));
}
export async function deleteLayout(id: string): Promise<void> { must(await supabase.from('multiview_layouts').delete().eq('id', id)); }
export async function channelNames(ids: string[]): Promise<Record<string, string>> {
  if (!ids.length) return {};
  const rows = must(await supabase.from('channels').select('id,name').in('id', ids)) as { id: string; name: string }[];
  return Object.fromEntries(rows.map((r) => [r.id, r.name]));
}

// ------------------------------------------------------------------ Guía EPG (fuentes XMLTV + estado del archivo generado por el motor)
export async function listEpgSources(playlistId: string): Promise<EpgSource[]> {
  return must(await supabase.from('epg_sources').select('id,url,enabled,last_fetched_at,last_status,channel_count').eq('playlist_id', playlistId).order('sort_order')) as EpgSource[];
}
export async function addEpgSource(playlistId: string, url: string): Promise<void> {
  const u = url.trim(); if (!/^https?:\/\/\S+$/i.test(u)) throw new Error('La dirección debe empezar con http:// o https://');
  const r = await supabase.from('epg_sources').insert({ playlist_id: playlistId, url: u });
  if (r.error) throw new Error(r.error.code === '23505' ? 'Esa fuente ya está agregada.' : friendly(r.error.message));
}
export async function removeEpgSource(id: string): Promise<void> { must(await supabase.from('epg_sources').delete().eq('id', id)); }
export async function epgStatus(playlistId: string): Promise<EpgStatus> {
  const [a, j] = await Promise.all([
    supabase.from('playlist_artifacts').select('built_at,bytes,meta').eq('playlist_id', playlistId).eq('kind', 'epg_gz').maybeSingle(),
    supabase.from('sync_jobs').select('id,status,kind,requested_at,finished_at,error').eq('playlist_id', playlistId).eq('kind', 'epg').order('requested_at', { ascending: false }).limit(1),
  ]);
  return { artifact: must(a) as EpgStatus['artifact'], job: ((must(j) as SyncJob[])[0] ?? null) };
}

// ---- Salud: puntaje, uptime 90 días y peores canales
export async function playlistScore(playlistId: string): Promise<PlaylistScore> {
  return must(await supabase.rpc('playlist_score', { p_playlist: playlistId })) as PlaylistScore;
}
export async function channelUptime(channelId: string, days = 90): Promise<HealthDay[]> {
  return must(await supabase.rpc('channel_uptime', { p_channel: channelId, p_days: days })) as HealthDay[];
}
export async function worstChannels(playlistId: string, days = 14, limit = 10): Promise<WorstChannel[]> {
  const since = new Date(Date.now() - days * 86400000).toISOString().slice(0, 10);
  const rows = must(await supabase.from('health_daily').select('channel_id,checks,oks,latency_sum').eq('playlist_id', playlistId).gte('day', since).limit(20000)) as { channel_id: string; checks: number; oks: number; latency_sum: number }[];
  const agg = new Map<string, { checks: number; oks: number; lat: number }>();
  for (const r of rows) { const a = agg.get(r.channel_id) ?? { checks: 0, oks: 0, lat: 0 }; a.checks += r.checks; a.oks += r.oks; a.lat += r.latency_sum; agg.set(r.channel_id, a); }
  const list = [...agg.entries()].filter(([, a]) => a.checks >= 3).map(([id, a]) => ({ channel_id: id, checks: a.checks, uptime_pct: Math.round((1000 * a.oks) / a.checks) / 10, avg_ms: a.oks ? Math.round(a.lat / a.checks) : null }))
    .sort((x, y) => x.uptime_pct - y.uptime_pct).slice(0, limit);
  const names = await channelNames(list.map((l) => l.channel_id));
  return list.map((l) => ({ ...l, name: names[l.channel_id] ?? 'Canal' }));
}
