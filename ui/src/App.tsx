import type { Session } from '@supabase/supabase-js';
import { useCallback, useEffect, useRef, useState } from 'react';
import { dbHealth, friendly, requestSync, isAdmin, latestJob, listChannels, myEntitlements, myPlaylists, playlistStatus, primarySource, recentLogs, subscribe, workerHealth } from './api';
import type { ChannelRow, EngineLog, Entitlements, Health, PlaylistRow, PlaylistStatus, SyncJob } from './api/types';
import { ChannelTable } from './components/ChannelTable';
import { ChannelModal } from './components/ChannelModal';
import { Console } from './components/Console';
import { AchievementsModal } from './components/AchievementsModal';
import { AdminModal } from './components/AdminModal';
import { MultiviewModal } from './components/MultiviewModal';
import { ConnectionsModal } from './components/ConnectionsModal';
import { CommunityModal } from './components/CommunityModal';
import { LegalPage } from './components/LegalPage';
import { CommandPalette, type Cmd } from './components/CommandPalette';
import { HealthModal } from './components/HealthModal';
import { HospitalModal } from './components/HospitalModal';
import { GetListModal } from './components/GetListModal';
import { ImportModal } from './components/ImportModal';
import { Player, type PlayTarget } from './components/Player';
import { Login } from './components/Login';
import { PlanChip } from './components/PlanChip';
import { SignalStrip } from './components/SignalStrip';
import { StatusDots } from './components/StatusDots';
import { SyncButton } from './components/SyncButton';
import { supabase } from './lib/supabase';

function Workspace({ playlist, email }: { playlist: PlaylistRow; email: string }) {
  const [rows, setRows] = useState<ChannelRow[]>([]);
  const [status, setStatus] = useState<PlaylistStatus | null>(null);
  const [ent, setEnt] = useState<Entitlements | null>(null);
  const [logs, setLogs] = useState<EngineLog[]>([]);
  const [job, setJob] = useState<SyncJob | null>(null);
  const [worker, setWorker] = useState<boolean | null>(null);
  const [db, setDb] = useState<boolean | null>(null);
  const [filter, setFilter] = useState<Health | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [wins, setWins] = useState(false);
  const [admin, setAdmin] = useState(false);
  const [isAdm, setIsAdm] = useState(false);
  const [mv, setMv] = useState(false);
  const [conns, setConns] = useState(false);
  const [hosp, setHosp] = useState(false);
  const [health, setHealth] = useState(false);
  const [pal, setPal] = useState(false);
  const [community, setCommunity] = useState(false);
  const [getList, setGetList] = useState(false);
  const [importing, setImporting] = useState(false);
  const [editing, setEditing] = useState<string | null | undefined>(undefined);   // undefined = cerrado · null = nuevo
  const [playing, setPlaying] = useState<PlayTarget | null>(null);
  const timer = useRef<number>();

  const reload = useCallback(async () => {
    try {
      const [r, s, j] = await Promise.all([listChannels(playlist.id), playlistStatus(playlist.id), latestJob(playlist.id)]);
      setRows(r); setStatus(s); setJob(j); setError(null);
    } catch (e) { setError((e as Error).message); } finally { setLoading(false); }
  }, [playlist.id]);
  const soon = useCallback(() => { window.clearTimeout(timer.current); timer.current = window.setTimeout(reload, 1200); }, [reload]);

  useEffect(() => {
    void isAdmin().then(setIsAdm); void reload(); void myEntitlements().then(setEnt).catch(() => {}); void recentLogs(playlist.id).then(setLogs).catch(() => {});
    const off = subscribe(playlist.id, { logs: (l) => setLogs((p) => [...p.slice(-299), l]), health: soon, job: soon });
    const poll = window.setInterval(reload, 30000);                       // red de seguridad si Realtime no conecta
    return () => { off(); window.clearInterval(poll); window.clearTimeout(timer.current); };
  }, [playlist.id, reload, soon]);

  useEffect(() => {
    const tick = async () => { setWorker(await workerHealth()); setDb(await dbHealth()); };
    void tick(); const t = window.setInterval(tick, 30000);
    return () => window.clearInterval(t);
  }, []);

  useEffect(() => {
    const h = (e: KeyboardEvent) => { if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); setPal((v) => !v); } };
    window.addEventListener('keydown', h); return () => window.removeEventListener('keydown', h);
  }, []);
  const playById = async (id: string, name: string) => { const s = await primarySource(id).catch(() => null); if (s) setPlaying({ title: name, url: s.url, referer: s.referer, ua: s.user_agent }); };
  const commands: Cmd[] = [
    { id: 'new', label: 'Nuevo canal', run: () => setEditing(null) }, { id: 'imp', label: 'Importar lista M3U', run: () => setImporting(true) },
    { id: 'get', label: 'Obtener enlace de la lista', hint: 'M3U · EPG', run: () => setGetList(true) }, { id: 'sync', label: 'Forzar sincronización', run: () => { void requestSync(playlist.id).then(soon).catch((e) => setError(friendly((e as Error).message))); } },
    { id: 'health', label: 'Salud de la lista', run: () => setHealth(true) }, { id: 'hosp', label: 'Hospital de canales', run: () => setHosp(true) },
    { id: 'mv', label: 'Multivista', run: () => setMv(true) }, { id: 'conn', label: 'Conexiones (agentes y proxies)', run: () => setConns(true) },
    { id: 'com', label: 'Comunidad y catálogo', run: () => setCommunity(true) }, { id: 'win', label: 'Logros y nivel', run: () => setWins(true) },
    { id: 'down', label: 'Mostrar solo canales caídos', run: () => setFilter('down') }, { id: 'all', label: 'Mostrar todos los canales', run: () => setFilter(null) },
    ...(isAdm ? [{ id: 'adm', label: 'Administración', run: () => setAdmin(true) }] : []),
    { id: 'out', label: 'Cerrar sesión', run: () => { void supabase.auth.signOut(); } },
  ];

  return (
    <div className="flex h-full flex-col">
      <header className="flex flex-wrap items-center gap-x-6 gap-y-3 border-b border-line px-4 py-3 md:px-8">
        <div className="min-w-0"><p className="truncate font-semibold">{playlist.name}</p><p className="truncate text-xs text-dim">{email}</p></div>
        <StatusDots worker={worker} db={db} status={status} />
        <div className="flex flex-wrap items-center gap-3 md:ml-auto">
          <nav aria-label="Herramientas" className="flex flex-wrap gap-2">
            <button type="button" onClick={() => setMv(true)} className="whitespace-nowrap rounded-md border border-line px-3 py-2 text-sm hover:bg-ink-2">Multivista</button>
            <button type="button" onClick={() => setPal(true)} aria-label="Abrir paleta de comandos" className="hidden whitespace-nowrap rounded-md border border-line px-3 py-2 text-sm text-dim hover:bg-ink-2 md:block">Buscar · Ctrl K</button>
            <button type="button" onClick={() => setHealth(true)} className="whitespace-nowrap rounded-md border border-line px-3 py-2 text-sm hover:bg-ink-2">Salud</button>
            <button type="button" onClick={() => setHosp(true)} className="whitespace-nowrap rounded-md border border-line px-3 py-2 text-sm hover:bg-ink-2">Hospital</button>
            <button type="button" onClick={() => setConns(true)} className="whitespace-nowrap rounded-md border border-line px-3 py-2 text-sm hover:bg-ink-2">Conexiones</button>
            <button type="button" onClick={() => setCommunity(true)} className="whitespace-nowrap rounded-md border border-line px-3 py-2 text-sm hover:bg-ink-2">Comunidad</button>
            <button type="button" onClick={() => setImporting(true)} className="whitespace-nowrap rounded-md border border-line px-3 py-2 text-sm hover:bg-ink-2">Importar</button>
            <button type="button" onClick={() => setGetList(true)} className="whitespace-nowrap rounded-md border border-line px-3 py-2 text-sm hover:bg-ink-2">Obtener lista</button>
            {isAdm && <button type="button" onClick={() => setAdmin(true)} className="whitespace-nowrap rounded-md border border-line px-3 py-2 text-sm hover:bg-ink-2">Admin</button>}
          </nav>
          <PlanChip ent={ent} onClick={() => setWins(true)} />
          <SyncButton playlistId={playlist.id} job={job} onDone={() => { void reload(); }} />
          <button type="button" className="text-sm text-dim hover:text-paper" onClick={() => supabase.auth.signOut()}>Salir</button>
        </div>
      </header>
      {error && <p role="alert" className="border-b border-down/40 bg-down/10 px-4 py-2 text-sm text-down md:px-8">No se pudo cargar la lista: {error}</p>}
      <SignalStrip counts={status?.counts ?? {}} active={filter} onPick={setFilter} />
      {loading ? <p className="px-8 py-10 text-dim" role="status">Cargando canales…</p> : <ChannelTable rows={rows} filter={filter} onFilter={setFilter} onNew={() => setEditing(null)} onEdit={setEditing}
        onPlay={async (id, name) => { const s = await primarySource(id).catch(() => null); if (s) setPlaying({ title: name, url: s.url, referer: s.referer, ua: s.user_agent }); }} />}
      <Console logs={logs} />
      {editing !== undefined && <ChannelModal playlistId={playlist.id} channelId={editing} onClose={() => setEditing(undefined)} onSaved={() => { setEditing(undefined); void reload(); }} onPlay={setPlaying} />}
      {wins && <AchievementsModal ent={ent} onClose={() => setWins(false)} />}
      {admin && <AdminModal onClose={() => setAdmin(false)} />}
      {mv && <MultiviewModal playlistId={playlist.id} ent={ent} onClose={() => setMv(false)} />}
      {conns && <ConnectionsModal playlistId={playlist.id} ent={ent} onClose={() => setConns(false)} />}
      {pal && <CommandPalette commands={commands} channels={rows} onEdit={setEditing} onPlay={playById} onClose={() => setPal(false)} />}
      {health && <HealthModal playlistId={playlist.id} onClose={() => setHealth(false)} />}
      {hosp && <HospitalModal playlistId={playlist.id} ent={ent} onClose={() => setHosp(false)} onEdit={setEditing} />}
      {community && <CommunityModal playlistId={playlist.id} ent={ent} onClose={() => setCommunity(false)} onImported={() => void reload()} />}
      {getList && <GetListModal playlistId={playlist.id} ent={ent} onClose={() => setGetList(false)} />}
      {importing && <ImportModal playlistId={playlist.id} onClose={() => setImporting(false)} onDone={() => { setImporting(false); void reload(); }} />}
      {playing && <Player key={playing.url} target={playing} onClose={() => setPlaying(null)} />}
    </div>
  );
}

export function App() {
  const [session, setSession] = useState<Session | null | undefined>(undefined);
  const [playlists, setPlaylists] = useState<PlaylistRow[] | null>(null);
  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => data.subscription.unsubscribe();
  }, []);
  useEffect(() => { if (session) void myPlaylists().then(setPlaylists).catch(() => setPlaylists([])); else setPlaylists(null); }, [session]);

  const [hash, setHash] = useState(window.location.hash);
  useEffect(() => { const h = () => setHash(window.location.hash); window.addEventListener('hashchange', h); return () => window.removeEventListener('hashchange', h); }, []);
  if (hash === '#/terminos' || hash === '#/privacidad') return <LegalPage which={hash === '#/terminos' ? 'terminos' : 'privacidad'} />;
  if (session === undefined) return <p className="p-8 text-dim" role="status">Cargando…</p>;
  if (!session) return <Login />;
  if (!playlists) return <p className="p-8 text-dim" role="status">Preparando tu espacio…</p>;
  if (playlists.length === 0) return <p className="p-8">Tu cuenta aún no tiene listas. Cierra sesión y vuelve a entrar; si persiste, revisa que las migraciones estén aplicadas.</p>;
  return <Workspace playlist={playlists[0]} email={session.user.email ?? ''} />;
}
