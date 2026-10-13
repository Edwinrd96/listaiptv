import { useEffect, useState } from 'react';
import { channelUptime, friendly, playlistScore, worstChannels } from '../api';
import type { HealthDay, PlaylistScore, WorstChannel } from '../api/types';
import { Modal } from './Modal';

const cell = (p: number | null) => (p === null ? 'bg-ink-3' : p >= 99 ? 'bg-ok' : p >= 90 ? 'bg-ok/60' : p >= 60 ? 'bg-warn' : 'bg-down');
const tone = (n: number) => (n >= 80 ? 'text-ok' : n >= 55 ? 'text-warn' : 'text-down');

export function Heatmap({ days }: { days: HealthDay[] }) {
  return (
    <div role="img" aria-label="Disponibilidad diaria de los últimos días" className="flex flex-wrap gap-[3px]">
      {days.map((d) => <span key={d.day} title={`${d.day}: ${d.uptime_pct === null ? 'sin pruebas' : d.uptime_pct + '%'} (${d.checks} pruebas)`} className={`h-4 w-4 rounded-sm ${cell(d.uptime_pct)}`} />)}
    </div>
  );
}

export function HealthModal({ playlistId, onClose }: { playlistId: string; onClose: () => void }) {
  const [score, setScore] = useState<PlaylistScore | null>(null); const [worst, setWorst] = useState<WorstChannel[] | null>(null);
  const [sel, setSel] = useState<WorstChannel | null>(null); const [days, setDays] = useState<HealthDay[] | null>(null); const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    playlistScore(playlistId).then(setScore).catch((e) => setErr(friendly((e as Error).message)));
    worstChannels(playlistId).then((w) => { setWorst(w); if (w[0]) setSel(w[0]); }).catch((e) => setErr(friendly((e as Error).message)));
  }, [playlistId]);
  useEffect(() => { if (!sel) { setDays(null); return; } setDays(null); channelUptime(sel.channel_id).then(setDays).catch((e) => setErr(friendly((e as Error).message))); }, [sel]);
  const bars: [string, number | undefined][] = [['Canales que funcionan', score?.healthy], ['Con logo', score?.logos], ['Con guía (EPG)', score?.epg], ['Con respaldo', score?.fallbacks], ['Con categoría', score?.categorized]];
  const tot = days ? days.reduce((a, d) => ({ c: a.c + d.checks, o: a.o + d.oks }), { c: 0, o: 0 }) : null;
  const avg = tot && tot.c ? Math.round((1000 * tot.o) / tot.c) / 10 : null;
  return (
    <Modal title="Salud de la lista" wide onClose={onClose}>
      {err && <p role="alert" className="text-sm text-down">{err}</p>}
      {!score ? <p className="text-dim" role="status">Cargando…</p> : (
        <section aria-label="Puntaje" className="grid gap-4 md:grid-cols-[10rem_1fr]">
          <div className="rounded border border-line p-4 text-center"><p className={`text-5xl font-semibold ${tone(score.score)}`}>{score.score}</p><p className="text-xs text-dim">de 100 · {score.channels} canales</p></div>
          <ul className="space-y-2">{bars.map(([l, v]) => (
            <li key={l} className="text-sm"><div className="flex justify-between"><span>{l}</span><span className="text-dim">{v ?? 0}%</span></div>
              <div className="h-2 rounded bg-ink-3"><div className="h-2 rounded bg-paper" style={{ width: `${v ?? 0}%` }} /></div></li>))}</ul>
        </section>)}
      <section aria-label="Peores canales">
        <h3 className="mb-2 text-sm font-medium">Los que más fallan (últimos 14 días)</h3>
        {!worst ? <p className="text-dim" role="status">Cargando…</p> : worst.length === 0 ? <p className="rounded border border-line px-4 py-5 text-center text-dim">Aún no hay suficientes pruebas para calcular disponibilidad.</p> : (
          <ul className="divide-y divide-line rounded border border-line">{worst.map((w) => (
            <li key={w.channel_id}><button type="button" onClick={() => setSel(w)} aria-pressed={sel?.channel_id === w.channel_id} className={`flex w-full items-center gap-3 px-3 py-2 text-left text-sm hover:bg-ink-2 ${sel?.channel_id === w.channel_id ? 'bg-ink-2' : ''}`}>
              <span className="min-w-0 flex-1 truncate">{w.name}</span><span className="text-xs text-dim">{w.avg_ms ? `${w.avg_ms} ms` : ''}</span><span className={`w-14 text-right font-medium ${tone(w.uptime_pct)}`}>{w.uptime_pct}%</span></button></li>))}</ul>)}
      </section>
      {sel && <section aria-label="Historial" className="space-y-2"><h3 className="text-sm font-medium">{sel.name} · últimos 90 días{avg !== null && <span className="ml-2 text-dim">disponibilidad {avg}%</span>}</h3>
        {days ? <Heatmap days={days} /> : <p className="text-dim" role="status">Cargando…</p>}
        <p className="text-xs text-dim">Verde = respondió casi siempre · amarillo = a ratos · rojo = caído · gris = sin pruebas. Tu plan define cuántos días de historia se guardan.</p></section>}
    </Modal>
  );
}
