import { useCallback, useEffect, useState } from 'react';
import { friendly, loadProgress, setHandle } from '../api';
import type { Entitlements, Progress } from '../api/types';
import { Modal } from './Modal';

const btn = 'rounded border border-line px-2.5 py-1 text-sm hover:bg-ink-3 disabled:opacity-50';
const ICON: Record<string, string> = { rocket: '🚀', users: '👥', stethoscope: '🩺', shield: '🛡️' };
const KIND: Record<string, string> = { import: 'Importaste canales', contrib_accepted: 'Un aporte tuyo fue aceptado', report: 'Reporte de un fallo real', mission: 'Misión cumplida' };
const when = (iso: string) => new Date(iso).toLocaleDateString('es-DO', { day: 'numeric', month: 'short' });

export function AchievementsModal({ ent, onClose }: { ent: Entitlements | null; onClose: () => void }) {
  const [p, setP] = useState<Progress | null>(null); const [err, setErr] = useState<string | null>(null); const [alias, setAlias] = useState(''); const [msg, setMsg] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  const load = useCallback(() => { loadProgress().then((d) => { setP(d); setAlias(d.handle ?? ''); }).catch((e) => setErr(friendly((e as Error).message))); }, []);
  useEffect(load, [load]);
  async function saveAlias(e: React.FormEvent) { e.preventDefault(); setBusy(true); setErr(null); setMsg(null); try { await setHandle(alias); setMsg(alias.trim() ? 'Listo: apareces en el ranking con ese alias.' : 'Ya no apareces en el ranking.'); load(); } catch (x) { setErr((x as Error).message); } finally { setBusy(false); } }
  const xp = ent?.xp ?? 0; const level = ent?.level ?? 1;
  const cur = p?.levels.find((l) => l.level === level); const next = p?.levels.find((l) => l.level === level + 1);
  const pct = next && cur ? Math.min(100, Math.round(((xp - cur.min_xp) / (next.min_xp - cur.min_xp)) * 100)) : 100;
  const have = new Set(p?.earned.map((e) => e.badge_key)); const prog = Object.fromEntries((p?.progress ?? []).map((m) => [m.mission_key, m]));
  const shownBadges = (p?.badges ?? []).filter((b) => !b.hidden || have.has(b.key));
  return (
    <Modal title="Mis logros" wide onClose={onClose}>
      {err && <p role="alert" className="text-sm text-down">{err}</p>}
      <section className="rounded-lg border border-line p-4" aria-label="Nivel">
        <p className="text-sm text-dim">Nivel {level}</p>
        <p className="text-2xl font-semibold">{cur?.name ?? '…'} <span className="text-base font-normal text-dim">· {xp} XP</span></p>
        <div className="mt-3 h-2 overflow-hidden rounded-full bg-ink-3" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100} aria-label="Progreso al siguiente nivel"><div className="h-full bg-focus" style={{ width: `${pct}%` }} /></div>
        <p className="mt-2 text-sm text-dim">{next ? `Te faltan ${next.min_xp - xp} XP para ${next.name}${next.perks_text ? `: ${next.perks_text}` : ''}.` : 'Llegaste al nivel máximo.'}</p>
        <p className="mt-1 text-xs text-dim">El XP se gana ayudando: importar listas, reportar fallos reales y aportar canales al catálogo. No tiene valor en dinero.</p>
      </section>
      <section aria-label="Misiones"><h3 className="mb-2 font-medium">Misiones</h3>
        <ul className="divide-y divide-line rounded border border-line">{(p?.missions ?? []).map((m) => { const g = prog[m.key]; const done = !!g?.completed_at; const n = Math.min(g?.progress ?? 0, m.goal); return (
          <li key={m.key} className="space-y-1.5 px-3 py-2.5 text-sm"><div className="flex items-center gap-3"><span className="min-w-0 flex-1">{m.title}</span><span className={done ? 'text-ok' : 'text-dim'}>{done ? 'Cumplida' : `${n} de ${m.goal}`} · +{m.xp} XP</span></div>
            <div className="h-1.5 overflow-hidden rounded-full bg-ink-3" role="progressbar" aria-valuenow={n} aria-valuemin={0} aria-valuemax={m.goal} aria-label={m.title}><div className={`h-full ${done ? 'bg-ok' : 'bg-focus'}`} style={{ width: `${(n / m.goal) * 100}%` }} /></div></li>); })}</ul></section>
      <section aria-label="Insignias"><h3 className="mb-2 font-medium">Insignias</h3>
        <ul className="grid grid-cols-2 gap-3 md:grid-cols-4">{shownBadges.map((b) => { const got = have.has(b.key); return (
          <li key={b.key} className={`rounded-lg border p-3 text-center text-sm ${got ? 'border-ok/50' : 'border-line opacity-60'}`}><p className="text-2xl" aria-hidden="true">{got ? ICON[b.icon ?? ''] ?? '⭐' : '🔒'}</p><p className="mt-1 font-medium">{b.name}</p><p className="text-xs text-dim">{b.description}</p><p className="sr-only">{got ? 'Conseguida' : 'Bloqueada'}</p></li>); })}</ul></section>
      <section aria-label="Niveles"><h3 className="mb-2 font-medium">Qué desbloquea cada nivel</h3>
        <ol className="divide-y divide-line rounded border border-line">{(p?.levels ?? []).map((l) => <li key={l.level} className={`flex items-center gap-3 px-3 py-2 text-sm ${l.level === level ? 'bg-ink-3' : ''}`}><span className="w-6 text-dim">{l.level}</span><span className="w-28 font-medium">{l.name}</span><span className="min-w-0 flex-1 text-dim">{l.perks_text}</span><span className="text-xs text-dim">{l.min_xp} XP</span></li>)}</ol></section>
      <section aria-label="Ranking"><h3 className="mb-1 font-medium">Ranking</h3>
        <p className="mb-2 text-sm text-dim">Solo aparecen quienes eligen un alias; se ve el alias, el nivel y el XP, nada más. Déjalo vacío para no aparecer.</p>
        <form onSubmit={saveAlias} className="mb-3 flex flex-wrap items-center gap-2"><label className="sr-only" htmlFor="alias">Tu alias</label><input id="alias" value={alias} onChange={(e) => setAlias(e.target.value)} maxLength={24} placeholder="tu_alias" className="rounded-md border border-line bg-ink px-3 py-1.5 text-sm placeholder:text-dim" /><button type="submit" className={btn} disabled={busy}>Guardar alias</button>{msg && <span role="status" className="text-sm text-ok">{msg}</span>}</form>
        {p && p.leaders.length === 0 ? <p className="rounded border border-line px-4 py-4 text-dim">Nadie ha elegido alias todavía.</p> : <ol className="divide-y divide-line rounded border border-line">{(p?.leaders ?? []).slice(0, 10).map((r, i) => <li key={r.handle} className={`flex items-center gap-3 px-3 py-2 text-sm ${r.handle === p?.handle ? 'bg-ink-3' : ''}`}><span className="w-6 text-dim">{i + 1}</span><span className="min-w-0 flex-1 truncate">@{r.handle}</span><span className="text-dim">nivel {r.level} · {r.xp} XP</span></li>)}</ol>}</section>
      {p && p.events.length > 0 && <section aria-label="Actividad"><h3 className="mb-2 font-medium">Últimos puntos</h3><ul className="divide-y divide-line rounded border border-line">{p.events.map((e) => <li key={e.id} className="flex items-center gap-3 px-3 py-2 text-sm"><span className="min-w-0 flex-1">{KIND[e.kind] ?? e.kind}</span><span className="text-ok">+{e.xp} XP</span><span className="text-xs text-dim">{when(e.at)}</span></li>)}</ul></section>}
    </Modal>
  );
}
