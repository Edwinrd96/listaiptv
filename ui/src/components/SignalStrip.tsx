import type { Health } from '../api/types';
import { HEALTH_META, HealthShape } from './HealthDot';

const ORDER: Health[] = ['ok', 'warn', 'down', 'unverified', 'unknown'];

/** La pieza central: una tira como las barras de color de un generador de señal. Cada tramo filtra la tabla. */
export function SignalStrip({ counts, active, onPick }: { counts: Partial<Record<Health, number>>; active: Health | null; onPick: (h: Health | null) => void }) {
  const merged: Partial<Record<Health, number>> = { ...counts };
  merged.unknown = (counts.unknown ?? 0) + (counts.unchecked ?? 0);
  const total = ORDER.reduce((n, h) => n + (merged[h] ?? 0), 0);
  const okPct = total ? Math.round(((merged.ok ?? 0) / total) * 100) : 0;
  return (
    <section aria-label="Estado de la lista" className="px-4 pt-5 pb-3 md:px-8">
      <div className="mb-3 flex items-end justify-between gap-4">
        <div>
          <p className="text-3xl font-semibold tracking-tight md:text-4xl">{total ? `${okPct}% al aire` : 'Sin canales todavía'}</p>
          <p className="mt-1 text-sm text-dim">{total ? `${merged.ok ?? 0} de ${total} canales responden bien` : 'Importa una lista o añade tu primer canal.'}</p>
        </div>
      </div>
      <div className="flex h-5 w-full gap-0.5 overflow-hidden rounded-sm" role="group" aria-label="Filtrar por estado">
        {total === 0 && <div className="h-full w-full bg-ink-3" />}
        {ORDER.filter((h) => (merged[h] ?? 0) > 0).map((h) => (
          <button key={h} type="button" onClick={() => onPick(active === h ? null : h)} aria-pressed={active === h}
            title={`${HEALTH_META[h].label}: ${merged[h]}`} className="strip-seg h-full cursor-pointer transition-opacity hover:opacity-90"
            style={{ flexGrow: merged[h], background: HEALTH_META[h].color, opacity: active && active !== h ? 0.28 : 1 }} />
        ))}
      </div>
      <ul className="mt-2.5 flex flex-wrap gap-x-5 gap-y-1 text-sm text-dim">
        {ORDER.map((h) => (
          <li key={h}>
            <button type="button" onClick={() => onPick(active === h ? null : h)} className={`inline-flex items-center gap-1.5 rounded px-1 py-0.5 hover:text-paper ${active === h ? 'text-paper' : ''}`}>
              <HealthShape h={h} size={11} /> {HEALTH_META[h].label} <b className="font-semibold text-paper">{merged[h] ?? 0}</b>
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}
