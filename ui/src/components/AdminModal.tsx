import { useCallback, useEffect, useState } from 'react';
import { acceptSuggestion, activateBilling, adminOverview, auditLog, findUser, friendly, grantPlan, hotspots, listFlags, listSettings, pendingSuggestions, rejectSuggestion, setFlag, setSetting } from '../api';
import type { AdminOverview, AdminSuggestion, AuditRow, FlagRow, FoundUser, Hotspot, SettingRow } from '../api/types';
import { Modal } from './Modal';

const btn = 'rounded border border-line px-2.5 py-1 text-sm hover:bg-ink-3 disabled:opacity-50';
const input = 'rounded-md border border-line bg-ink px-2.5 py-1.5 text-sm placeholder:text-dim';
type Tab = 'overview' | 'billing' | 'flags' | 'suggestions' | 'reports' | 'users' | 'audit';
const TABS: [Tab, string][] = [['overview', 'Resumen'], ['billing', 'Cobro'], ['flags', 'Funciones'], ['suggestions', 'Sugerencias'], ['reports', 'Reportes'], ['users', 'Usuarios'], ['audit', 'Auditoría']];
const show = (v: unknown) => JSON.stringify(v);
function parseLike(text: string, orig: unknown): unknown {
  const t = text.trim();
  if (typeof orig === 'string') return t.startsWith('"') ? JSON.parse(t) : t;
  return JSON.parse(t);
}
function useAsync<T>(fn: () => Promise<T>) {
  const [data, setData] = useState<T | null>(null); const [err, setErr] = useState<string | null>(null);
  const load = useCallback(() => { fn().then((d) => { setData(d); setErr(null); }).catch((e) => setErr(friendly((e as Error).message))); }, [fn]);
  useEffect(load, [load]);
  return { data, err, load };
}
const Err = ({ e }: { e: string | null }) => (e ? <p role="alert" className="text-sm text-down">{e}</p> : null);

function Overview() {
  const { data, err } = useAsync<AdminOverview>(adminOverview);
  const items: [string, number | string | undefined][] = data ? [['Usuarios', data.users], ['Con Pro pagado', data.pro_active], ['Con Pro regalado', data.manual_grants], ['Listas', data.playlists], ['Canales', data.channels],
    ['En el catálogo', data.catalog_channels], ['Sugerencias por revisar', data.pending_suggestions], ['En el Hospital', data.in_hospital], ['Declarados muertos', data.dead], ['Modo de cobro', data.billing_mode]] : [];
  return (<div className="space-y-3"><Err e={err} />{!data && !err && <p className="text-dim" role="status">Cargando…</p>}
    <dl className="grid grid-cols-2 gap-3 md:grid-cols-5">{items.map(([k, v]) => <div key={k} className="rounded-lg border border-line p-3"><dt className="text-xs text-dim">{k}</dt><dd className="mt-1 text-xl font-semibold">{v}</dd></div>)}</dl></div>);
}

function Billing() {
  const { data, err, load } = useAsync<SettingRow[]>(listSettings);
  const [e2, setE2] = useState<string | null>(null); const [ok, setOk] = useState<string | null>(null); const [word, setWord] = useState(''); const [busy, setBusy] = useState(false);
  const get = (k: string) => data?.find((s) => s.key === k)?.value;
  const mode = get('billing_mode') as string | undefined; const provider = get('billing_provider') as string | undefined;
  async function run(fn: () => Promise<unknown>, done?: string) { setBusy(true); setE2(null); setOk(null); try { await fn(); if (done) setOk(done); load(); } catch (e) { setE2(friendly((e as Error).message)); } finally { setBusy(false); } }
  const editable = (data ?? []).filter((s) => !['billing_mode', 'founder_granted_at'].includes(s.key));
  return (
    <div className="space-y-5"><Err e={err} /><Err e={e2} />{ok && <p role="status" className="text-sm text-ok">{ok}</p>}
      <section className="rounded-lg border border-line p-4">
        <h3 className="font-medium">Modo de cobro: <span className={mode === 'live' ? 'text-warn' : 'text-ok'}>{mode ?? '…'}</span></h3>
        <p className="mt-1 text-sm text-dim">Apagado: nadie paga y las funciones marcadas como abiertas son para todos. Vista previa: se muestran los planes sin cobrar. Cobro real: se cobra y las funciones abiertas se cierran.</p>
        {mode !== 'live' && <div className="mt-3 flex gap-2"><button type="button" className={btn} disabled={busy || mode === 'off'} onClick={() => run(() => setSetting('billing_mode', 'off'), 'Cobro apagado.')}>Apagado</button>
          <button type="button" className={btn} disabled={busy || mode === 'preview'} onClick={() => run(() => setSetting('billing_mode', 'preview'), 'Vista previa activada.')}>Vista previa</button></div>}
      </section>
      {mode !== 'live' && (
        <section className="rounded-lg border border-warn/40 p-4">
          <h3 className="font-medium">Activar el cobro real</h3>
          <p className="mt-1 text-sm text-dim">La primera vez, todos los usuarios que ya existen reciben el plan Founder: {String(get('founder_months') ?? 6)} meses de Pro gratis y {String(get('founder_discount_pct') ?? 20)} % de descuento de por vida. No hay vuelta atrás para esa concesión. Antes hay que elegir un proveedor de pago abajo.</p>
          {provider === 'none' && <p className="mt-2 text-sm text-warn">Falta elegir el proveedor (lemonsqueezy o paddle).</p>}
          <div className="mt-3 flex flex-wrap items-center gap-2"><label className="text-sm">Escribe ACTIVAR para confirmar <input value={word} onChange={(e) => setWord(e.target.value)} className={`${input} ml-2 w-32`} /></label>
            <button type="button" className="rounded-md bg-warn px-3 py-2 text-sm font-medium text-ink disabled:opacity-50" disabled={busy || word !== 'ACTIVAR' || provider === 'none'} onClick={() => run(async () => { const r = await activateBilling(); setOk(`Cobro activado. ${r.founders_granted} usuarios recibieron el plan Founder.`); setWord(''); })}>Activar cobro</button></div>
        </section>)}
      <section><h3 className="mb-2 font-medium">Ajustes</h3>
        <ul className="divide-y divide-line rounded border border-line">{editable.map((s) => (
          <li key={s.key} className="flex flex-wrap items-center gap-3 px-3 py-2 text-sm"><span className="min-w-0 flex-1"><span className="block font-mono text-xs">{s.key}</span><span className="block text-xs text-dim">{s.note}</span></span>
            <input aria-label={s.key} defaultValue={typeof s.value === 'string' ? s.value : show(s.value)} className={`${input} w-40`} onBlur={(e) => {
              let v: unknown; try { v = parseLike(e.target.value, s.value); } catch { setE2(`«${s.key}»: valor no válido.`); return; }
              if (show(v) !== show(s.value)) void run(() => setSetting(s.key, v), `«${s.key}» guardado.`);
            }} /></li>))}</ul></section>
    </div>);
}

function Flags() {
  const { data, err, load } = useAsync<FlagRow[]>(listFlags); const [e2, setE2] = useState<string | null>(null);
  async function save(f: FlagRow, patch: { free?: unknown; pro?: unknown; open?: boolean }) { setE2(null); try { await setFlag(f.key, patch); load(); } catch (e) { setE2(friendly((e as Error).message)); } }
  const cell = (f: FlagRow, side: 'free' | 'pro') => (
    <input aria-label={`${f.key} ${side === 'free' ? 'gratis' : 'Pro'}`} defaultValue={show(side === 'free' ? f.free_value : f.pro_value)} className={`${input} w-24`}
      onBlur={(e) => { let v: unknown; try { v = JSON.parse(e.target.value); } catch { setE2(`«${f.key}»: usa un número, true o false.`); return; } if (show(v) !== show(side === 'free' ? f.free_value : f.pro_value)) void save(f, { [side]: v }); }} />);
  return (
    <div className="space-y-3"><p className="text-sm text-dim">Qué incluye cada plan. «Abierta» = mientras no haya cobro real, todos disfrutan el valor Pro. Las funciones que le cuestan dinero al operador nunca se abren.</p><Err e={err} /><Err e={e2} />
      <ul className="divide-y divide-line rounded border border-line">{(data ?? []).map((f) => (
        <li key={f.key} className="flex flex-col gap-2 px-3 py-2 text-sm md:grid md:grid-cols-[1fr_6rem_6rem_9rem] md:items-center md:gap-x-3">
          <span className="min-w-0"><span className="block break-all font-mono text-xs">{f.key}{f.cost_sensitive && <span className="ml-2 rounded bg-warn/20 px-1.5 text-warn">cuesta dinero</span>}</span><span className="block truncate text-xs text-dim">{f.description}</span></span>
          <span className="flex items-center gap-2 text-xs text-dim md:contents"><span className="md:hidden">Gratis</span>{cell(f, 'free')}<span className="md:hidden">Pro</span>{cell(f, 'pro')}</span>
          <label className="flex items-center gap-2 text-xs"><input type="checkbox" checked={f.open_during_free_phase} disabled={f.cost_sensitive} onChange={(e) => void save(f, { open: e.target.checked })} className="size-4 accent-[var(--color-focus)]" /> Abierta para todos</label>
        </li>))}</ul></div>);
}

function Suggestions() {
  const { data, err, load } = useAsync<AdminSuggestion[]>(pendingSuggestions); const [e2, setE2] = useState<string | null>(null); const [rej, setRej] = useState<string | null>(null); const [why, setWhy] = useState(''); const [busy, setBusy] = useState(false);
  async function run(fn: () => Promise<unknown>) { setBusy(true); setE2(null); try { await fn(); setRej(null); setWhy(''); load(); } catch (e) { setE2(friendly((e as Error).message)); } finally { setBusy(false); } }
  return (
    <div className="space-y-3"><Err e={err} /><Err e={e2} />
      {data && data.length === 0 && <p className="rounded border border-line px-4 py-6 text-center text-dim">No hay sugerencias pendientes.</p>}
      <ul className="divide-y divide-line rounded border border-line">{(data ?? []).map((s) => (
        <li key={s.id} className="space-y-2 px-3 py-2.5 text-sm">
          <div className="flex flex-wrap items-center gap-3"><span className="min-w-0 flex-1"><span className="block truncate font-medium">{s.name}</span>
            <span className="block truncate text-xs text-dim">{s.category ?? 'Sin categoría'}{s.country ? ` · ${s.country}` : ''} · {s.suggestion_submitters[0]?.count ?? 0} aportó · {s.url ?? 'solo nombre y logo'}</span></span>
            <button type="button" className={btn} disabled={busy} onClick={() => run(() => acceptSuggestion(s.id))}>Aceptar</button>
            <button type="button" className={btn} disabled={busy} onClick={() => setRej(rej === s.id ? null : s.id)}>Rechazar</button></div>
          {rej === s.id && <div className="flex gap-2"><input aria-label="Motivo" value={why} onChange={(e) => setWhy(e.target.value)} placeholder="Motivo (opcional)" className={`${input} flex-1`} /><button type="button" className={btn} disabled={busy} onClick={() => run(() => rejectSuggestion(s.id, why))}>Confirmar rechazo</button></div>}
        </li>))}</ul></div>);
}

function Reports() {
  const { data, err } = useAsync<Hotspot[]>(useCallback(() => hotspots(2), []));
  return (
    <div className="space-y-3"><p className="text-sm text-dim">Enlaces reportados como caídos por al menos 2 personas distintas en los últimos 7 días.</p><Err e={err} />
      {data && data.length === 0 && <p className="rounded border border-line px-4 py-6 text-center text-dim">Sin reportes repetidos.</p>}
      <ul className="divide-y divide-line rounded border border-line">{(data ?? []).map((h) => <li key={h.fingerprint} className="flex items-center gap-3 px-3 py-2 text-sm"><span className="min-w-0 flex-1 truncate font-mono text-xs">{h.fingerprint}</span><span>{h.reporters} personas · {h.reports} reportes</span><span className="text-dim">{h.last_kind ?? ''}</span></li>)}</ul></div>);
}

function Users() {
  const [q, setQ] = useState(''); const [rows, setRows] = useState<FoundUser[] | null>(null); const [days, setDays] = useState(30); const [reason, setReason] = useState(''); const [err, setErr] = useState<string | null>(null); const [ok, setOk] = useState<string | null>(null);
  useEffect(() => { if (q.trim().length < 3) { setRows(null); return; } const t = window.setTimeout(() => { findUser(q).then(setRows).catch((e) => setErr(friendly((e as Error).message))); }, 300); return () => window.clearTimeout(t); }, [q]);
  async function grant(u: FoundUser) { setErr(null); setOk(null); try { const until = await grantPlan(u.user_id, days, reason); setOk(`${u.email} tiene Pro hasta el ${new Date(until).toLocaleDateString('es-DO')}.`); } catch (e) { setErr(friendly((e as Error).message)); } }
  return (
    <div className="space-y-3"><div className="flex flex-wrap gap-2"><input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Buscar por correo (3 letras o más)" aria-label="Buscar usuario" className={`${input} min-w-0 flex-1`} />
      <select aria-label="Días de Pro" value={days} onChange={(e) => setDays(Number(e.target.value))} className={input}>{[7, 30, 90, 180, 365].map((d) => <option key={d} value={d}>{d} días</option>)}</select>
      <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Motivo" aria-label="Motivo" className={`${input} w-40`} /></div>
      <Err e={err} />{ok && <p role="status" className="text-sm text-ok">{ok}</p>}
      {rows && rows.length === 0 && <p className="text-dim">Sin resultados.</p>}
      <ul className="divide-y divide-line rounded border border-line">{(rows ?? []).map((u) => <li key={u.user_id} className="flex items-center gap-3 px-3 py-2 text-sm"><span className="min-w-0 flex-1 truncate">{u.email}<span className="ml-2 text-xs text-dim">{u.plan}</span></span><button type="button" className={btn} onClick={() => void grant(u)}>Dar Pro</button></li>)}</ul></div>);
}

function Audit() {
  const { data, err } = useAsync<AuditRow[]>(useCallback(() => auditLog(100), []));
  return (<div className="space-y-3"><Err e={err} />{data && data.length === 0 && <p className="text-dim">Sin movimientos todavía.</p>}
    <ul className="divide-y divide-line rounded border border-line">{(data ?? []).map((a) => <li key={a.id} className="px-3 py-2 text-sm"><span className="font-medium">{a.action}</span> <span className="text-dim">{a.target ?? ''} · {new Date(a.at).toLocaleString('es-DO')}</span>{a.detail != null && <span className="block truncate font-mono text-xs text-dim">{show(a.detail)}</span>}</li>)}</ul></div>);
}

export function AdminModal({ onClose }: { onClose: () => void }) {
  const [tab, setTab] = useState<Tab>('overview');
  return (
    <Modal title="Administración" wide onClose={onClose}>
      <div role="tablist" aria-label="Secciones de administración" className="flex flex-wrap gap-2">{TABS.map(([k, l]) => <button key={k} role="tab" type="button" aria-selected={tab === k} onClick={() => setTab(k)} className={`rounded-full border px-3 py-1 text-sm ${tab === k ? 'border-paper text-paper' : 'border-line text-dim hover:text-paper'}`}>{l}</button>)}</div>
      <div role="tabpanel">{tab === 'overview' ? <Overview /> : tab === 'billing' ? <Billing /> : tab === 'flags' ? <Flags /> : tab === 'suggestions' ? <Suggestions /> : tab === 'reports' ? <Reports /> : tab === 'users' ? <Users /> : <Audit />}</div>
    </Modal>
  );
}
