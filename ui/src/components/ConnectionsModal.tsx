import { useCallback, useEffect, useState } from 'react';
import { assignProxy, createAgent, createProxy, deleteAgent, deleteProxy, friendly, listAgents, listAssignments, listProxies, requestProxyTest, searchMyChannels, setAgentEnabled, setProxyEnabled, unassignProxy } from '../api';
import type { AgentRow, AssignmentRow, Entitlements, ProxyForm, ProxyRow } from '../api/types';
import { env } from '../lib/supabase';
import { Modal } from './Modal';

const btn = 'rounded border border-line px-2.5 py-1 text-sm hover:bg-ink-3 disabled:opacity-50';
const primary = 'rounded-md bg-paper px-3 py-2 text-sm font-medium text-ink disabled:opacity-60';
const field = 'mt-1 w-full rounded-md border border-line bg-ink px-3 py-2 text-sm placeholder:text-dim';
type Tab = 'agents' | 'proxies';
const ago = (iso: string | null) => { if (!iso) return 'nunca'; const m = Math.round((Date.now() - new Date(iso).getTime()) / 60000); return m < 1 ? 'hace un momento' : m < 60 ? `hace ${m} min` : m < 1440 ? `hace ${Math.round(m / 60)} h` : `hace ${Math.round(m / 1440)} d`; };
const Err = ({ e }: { e: string | null }) => (e ? <p role="alert" className="text-sm text-down">{e}</p> : null);
const Locked = ({ what }: { what: string }) => <p className="rounded border border-warn/40 bg-warn/10 px-3 py-2 text-sm text-warn">{what} es parte de Pro.</p>;

function Copy({ text, label = 'Copiar' }: { text: string; label?: string }) {
  const [done, setDone] = useState(false);
  async function go() { try { await navigator.clipboard.writeText(text); } catch { const t = document.createElement('textarea'); t.value = text; document.body.append(t); t.select(); document.execCommand('copy'); t.remove(); } setDone(true); window.setTimeout(() => setDone(false), 1800); }
  return <button type="button" onClick={go} className={btn} aria-live="polite">{done ? 'Copiado' : label}</button>;
}

function Agents({ ent }: { ent: Entitlements | null }) {
  const [rows, setRows] = useState<AgentRow[] | null>(null); const [err, setErr] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  const [name, setName] = useState(''); const [country, setCountry] = useState('DO'); const [fresh, setFresh] = useState<{ name: string; token: string } | null>(null);
  const load = useCallback(() => { listAgents().then(setRows).catch((e) => setErr(friendly((e as Error).message))); }, []);
  useEffect(load, [load]);
  useEffect(() => { const t = window.setInterval(load, 15000); return () => window.clearInterval(t); }, [load]);
  const locked = ent ? Number(ent.features['max_agents'] ?? 0) <= 0 : false;
  async function run(fn: () => Promise<unknown>) { setBusy(true); setErr(null); try { await fn(); load(); } catch (e) { setErr(friendly((e as Error).message)); } finally { setBusy(false); } }
  const cmd = (tok: string) => `SUPABASE_URL=${env.url} SUPABASE_ANON_KEY=${env.anon} AGENT_TOKEN=${tok} python -m iptv_engine agent`;
  return (
    <div className="space-y-4">
      <p className="text-sm text-dim">Un agente es el programa del motor corriendo en <strong className="text-paper">tu propia PC</strong>. Prueba tus canales desde tu internet de casa, así los canales que solo se ven en tu país (por ejemplo, locales de RD) se revisan bien. Usa un token propio y solo puede tocar tus canales.</p>
      {locked && <Locked what="Ejecutar agentes propios" />}<Err e={err} />
      {fresh && (
        <section className="space-y-2 rounded-lg border border-ok/50 bg-ok/10 p-4" aria-label="Token nuevo">
          <p className="font-medium">Agente «{fresh.name}» creado. Guarda el token ahora: no se vuelve a mostrar.</p>
          <div className="flex items-center gap-2"><input readOnly value={fresh.token} aria-label="Token del agente" onFocus={(e) => e.currentTarget.select()} className="min-w-0 flex-1 rounded-md border border-line bg-ink px-2.5 py-1.5 font-mono text-xs" /><Copy text={fresh.token} /></div>
          <p className="text-sm text-dim">Para arrancarlo en tu PC (necesitas Python y el motor instalados):</p>
          <div className="flex items-start gap-2"><code className="min-w-0 flex-1 break-all rounded-md bg-ink px-2.5 py-1.5 font-mono text-xs">{cmd(fresh.token)}</code><Copy text={cmd(fresh.token)} label="Copiar comando" /></div>
          <button type="button" className={btn} onClick={() => setFresh(null)}>Ya lo guardé</button>
        </section>)}
      <ul className="divide-y divide-line rounded border border-line" aria-label="Mis agentes">
        {rows && rows.length === 0 && <li className="px-3 py-4 text-dim">Aún no tienes agentes.</li>}
        {(rows ?? []).map((a) => {
          const online = !!a.last_seen_at && Date.now() - new Date(a.last_seen_at).getTime() < 3 * 60_000;
          return (
            <li key={a.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2.5 text-sm">
              <span className={`size-2.5 shrink-0 rounded-full ${online ? 'bg-ok' : 'bg-line'}`} role="img" aria-label={online ? 'Conectado' : 'Sin conexión'} />
              <span className="min-w-0 flex-1"><span className="block truncate font-medium">{a.name}{a.country ? ` · ${a.country}` : ''}</span><span className="block truncate text-xs text-dim">{online ? 'Conectado' : 'Sin conexión'} · visto {ago(a.last_seen_at)}{a.version ? ` · v${a.version}` : ''}</span></span>
              <label className="flex items-center gap-2"><input type="checkbox" checked={a.enabled} disabled={busy} onChange={(e) => void run(() => setAgentEnabled(a.id, e.target.checked))} className="size-4 accent-[var(--color-focus)]" /> Activo</label>
              <button type="button" className={`${btn} text-down`} disabled={busy} onClick={() => { if (confirm(`¿Borrar el agente «${a.name}»? Su token dejará de funcionar.`)) void run(() => deleteAgent(a.id)); }}>Borrar</button>
            </li>);
        })}
      </ul>
      <form className="grid gap-3 rounded-lg border border-line p-4 md:grid-cols-[1fr_6rem_auto] md:items-end" onSubmit={(e) => { e.preventDefault(); void run(async () => { const r = await createAgent(name.trim(), country.trim()); setFresh({ name: name.trim(), token: r.token }); setName(''); }); }}>
        <label className="text-sm">Nombre del agente<input required maxLength={60} value={name} onChange={(e) => setName(e.target.value)} placeholder="PC de casa" className={field} /></label>
        <label className="text-sm">País<input maxLength={2} pattern="[A-Za-z]{2}" value={country} onChange={(e) => setCountry(e.target.value)} className={`${field} uppercase`} /></label>
        <button type="submit" className={primary} disabled={busy || locked}>Crear agente</button>
      </form>
    </div>);
}

const EMPTY: ProxyForm = { name: '', scheme: 'http', host: '', port: '', username: '', password: '', country: '' };

function ProxyState({ p }: { p: ProxyRow }) {
  if (!p.last_test_at) return <span className="text-warn">Esperando prueba del motor…</span>;
  if (!p.last_ok) return <span className="text-down">Falla{p.last_error ? `: ${p.last_error}` : ''}</span>;
  const mismatch = p.country && p.exit_country && p.country !== p.exit_country;
  return <span className="text-ok">Funciona · {p.latency_ms} ms{p.exit_country ? ` · sale por ${p.exit_country}` : ''}{mismatch ? <span className="ml-1 text-warn"> (indicaste {p.country})</span> : null}</span>;
}

function Proxies({ playlistId, ent }: { playlistId: string; ent: Entitlements | null }) {
  const [rows, setRows] = useState<ProxyRow[] | null>(null); const [asg, setAsg] = useState<AssignmentRow[]>([]); const [f, setF] = useState<ProxyForm>(EMPTY);
  const [err, setErr] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  const [aProxy, setAProxy] = useState(''); const [aKind, setAKind] = useState<'country' | 'channel'>('country'); const [aCountry, setACountry] = useState('DO'); const [aQ, setAQ] = useState(''); const [hits, setHits] = useState<{ id: string; name: string }[]>([]); const [aChan, setAChan] = useState<{ id: string; name: string } | null>(null);
  const load = useCallback(() => { listProxies().then(setRows).catch((e) => setErr(friendly((e as Error).message))); listAssignments().then(setAsg).catch(() => {}); }, []);
  useEffect(load, [load]);
  useEffect(() => { const t = window.setInterval(load, 8000); return () => window.clearInterval(t); }, [load]);
  useEffect(() => { if (aKind !== 'channel' || aQ.trim().length < 2 || aChan) { setHits([]); return; } const t = window.setTimeout(() => { searchMyChannels(playlistId, aQ).then(setHits).catch(() => setHits([])); }, 250); return () => window.clearTimeout(t); }, [aQ, aKind, aChan, playlistId]);
  const locked = ent ? Number(ent.features['max_proxies'] ?? 0) <= 0 : false;
  async function run(fn: () => Promise<unknown>) { setBusy(true); setErr(null); try { await fn(); load(); } catch (e) { setErr(friendly((e as Error).message)); } finally { setBusy(false); } }
  const set = <K extends keyof ProxyForm>(k: K, v: ProxyForm[K]) => setF((p) => ({ ...p, [k]: v }));
  const proxyName = (id: string) => rows?.find((r) => r.id === id)?.name ?? 'proxy';
  return (
    <div className="space-y-5">
      <p className="text-sm text-dim">Si un canal solo se ve desde cierto país, puedes pasar su revisión por <strong className="text-paper">tu propio proxy</strong> (HTTP o SOCKS5). La clave se guarda sin poder leerse de vuelta. Los proxies SOCKS5 los usa el motor o tu agente; el servidor web no.</p>
      {locked && <Locked what="Usar proxies propios" />}<Err e={err} />
      <ul className="divide-y divide-line rounded border border-line" aria-label="Mis proxies">
        {rows && rows.length === 0 && <li className="px-3 py-4 text-dim">Aún no tienes proxies.</li>}
        {(rows ?? []).map((p) => (
          <li key={p.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2.5 text-sm">
            <span className="min-w-0 flex-1"><span className="block truncate font-medium">{p.name}{p.country ? ` · ${p.country}` : ''}</span><span className="block truncate font-mono text-xs text-dim">{p.scheme}://{p.username ? `${p.username}:••••@` : ''}{p.host}:{p.port}</span><span className="block text-xs"><ProxyState p={p} /></span></span>
            <button type="button" className={btn} disabled={busy} onClick={() => void run(() => requestProxyTest(p.id))}>Probar</button>
            <label className="flex items-center gap-2"><input type="checkbox" checked={p.enabled} disabled={busy} onChange={(e) => void run(() => setProxyEnabled(p.id, e.target.checked))} className="size-4 accent-[var(--color-focus)]" /> Activo</label>
            <button type="button" className={`${btn} text-down`} disabled={busy} onClick={() => { if (confirm(`¿Borrar el proxy «${p.name}»?`)) void run(() => deleteProxy(p.id)); }}>Borrar</button>
          </li>))}
      </ul>
      <form className="grid gap-3 rounded-lg border border-line p-4 md:grid-cols-2" onSubmit={(e) => { e.preventDefault(); void run(async () => { await createProxy(f); setF(EMPTY); }); }}>
        <h3 className="font-medium md:col-span-2">Agregar un proxy</h3>
        <label className="text-sm">Nombre<input required maxLength={60} value={f.name} onChange={(e) => set('name', e.target.value)} placeholder="Proxy de casa" className={field} /></label>
        <label className="text-sm">Tipo<select value={f.scheme} onChange={(e) => set('scheme', e.target.value as ProxyForm['scheme'])} className={field}><option value="http">HTTP</option><option value="https">HTTPS</option><option value="socks5">SOCKS5</option><option value="socks5h">SOCKS5 (DNS por el proxy)</option></select></label>
        <label className="text-sm">Servidor<input required pattern="[A-Za-z0-9.\-]{1,253}" value={f.host} onChange={(e) => set('host', e.target.value)} placeholder="mi-casa.duckdns.org" className={field} /></label>
        <label className="text-sm">Puerto<input required inputMode="numeric" pattern="[0-9]{1,5}" value={f.port} onChange={(e) => set('port', e.target.value)} placeholder="1080" className={field} /></label>
        <label className="text-sm">Usuario (opcional)<input autoComplete="off" value={f.username} onChange={(e) => set('username', e.target.value)} className={field} /></label>
        <label className="text-sm">Clave (opcional)<input type="password" autoComplete="new-password" value={f.password} onChange={(e) => set('password', e.target.value)} className={field} /></label>
        <label className="text-sm">País de salida esperado<input maxLength={2} pattern="[A-Za-z]{2}" value={f.country} onChange={(e) => set('country', e.target.value)} placeholder="DO" className={`${field} uppercase`} /></label>
        <div className="flex items-end"><button type="submit" className={primary} disabled={busy || locked}>Agregar proxy</button></div>
      </form>
      <section className="space-y-3">
        <h3 className="font-medium">Cuándo usar cada proxy</h3>
        <p className="text-sm text-dim">Se usa el más específico: primero el de la fuente, luego el del canal y al final el del país.</p>
        <ul className="divide-y divide-line rounded border border-line" aria-label="Asignaciones">
          {asg.length === 0 && <li className="px-3 py-3 text-sm text-dim">Sin asignaciones: los canales se revisan sin proxy.</li>}
          {asg.map((a) => <li key={a.id} className="flex items-center gap-3 px-3 py-2 text-sm"><span className="min-w-0 flex-1 truncate">{a.scope === 'country' ? `Canales de ${a.country}` : a.scope === 'channel' ? `Canal «${a.channels?.name ?? '…'}»` : 'Una fuente'} → <strong>{proxyName(a.proxy_id)}</strong></span><button type="button" className={btn} onClick={() => void run(() => unassignProxy(a.id))}>Quitar</button></li>)}
        </ul>
        {(rows?.length ?? 0) > 0 && (
          <form className="flex flex-wrap items-end gap-3" onSubmit={(e) => { e.preventDefault(); void run(async () => { await assignProxy(aProxy || rows![0].id, aKind === 'channel' ? { channelId: aChan?.id } : { country: aCountry }); setAChan(null); setAQ(''); }); }}>
            <label className="text-sm">Proxy<select value={aProxy || rows![0].id} onChange={(e) => setAProxy(e.target.value)} className={field}>{rows!.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
            <label className="text-sm">Para<select value={aKind} onChange={(e) => setAKind(e.target.value as 'country' | 'channel')} className={field}><option value="country">Todos los canales de un país</option><option value="channel">Un canal</option></select></label>
            {aKind === 'country' ? <label className="text-sm">País<input maxLength={2} pattern="[A-Za-z]{2}" required value={aCountry} onChange={(e) => setACountry(e.target.value)} className={`${field} w-20 uppercase`} /></label> : (
              <div className="relative text-sm"><label>Canal<input value={aChan ? aChan.name : aQ} onChange={(e) => { setAChan(null); setAQ(e.target.value); }} placeholder="Buscar canal" required className={`${field} w-56`} /></label>
                {hits.length > 0 && <ul className="absolute z-10 mt-1 w-56 rounded border border-line bg-ink-2 shadow-lg">{hits.map((h) => <li key={h.id}><button type="button" className="w-full px-3 py-1.5 text-left hover:bg-ink-3" onClick={() => { setAChan(h); setHits([]); }}>{h.name}</button></li>)}</ul>}</div>)}
            <button type="submit" className={btn} disabled={busy || (aKind === 'channel' && !aChan)}>Asignar</button>
          </form>)}
      </section>
    </div>);
}

export function ConnectionsModal({ playlistId, ent, onClose }: { playlistId: string; ent: Entitlements | null; onClose: () => void }) {
  const [tab, setTab] = useState<Tab>('agents');
  return (
    <Modal title="Mis conexiones" wide onClose={onClose}>
      <div role="tablist" aria-label="Secciones de conexiones" className="flex gap-2">
        {([['agents', 'Agentes (mi PC)'], ['proxies', 'Proxies propios']] as [Tab, string][]).map(([k, l]) => <button key={k} role="tab" type="button" aria-selected={tab === k} onClick={() => setTab(k)} className={`rounded-full border px-3 py-1 text-sm ${tab === k ? 'border-paper text-paper' : 'border-line text-dim hover:text-paper'}`}>{l}</button>)}
      </div>
      <div role="tabpanel">{tab === 'agents' ? <Agents ent={ent} /> : <Proxies playlistId={playlistId} ent={ent} />}</div>
    </Modal>
  );
}
