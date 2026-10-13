import type { ChannelRow, Health } from '../api/types';
import { ago } from '../lib/format';

export const HEALTH_META: Record<Health, { label: string; color: string }> = {
  ok: { label: 'Funciona', color: 'var(--color-ok)' },
  warn: { label: 'En observación', color: 'var(--color-warn)' },
  down: { label: 'Caído', color: 'var(--color-down)' },
  unverified: { label: 'No verificable desde el motor', color: 'var(--color-mute)' },
  unknown: { label: 'Sin medir', color: 'var(--color-mute)' },
  unchecked: { label: 'No se valida', color: 'var(--color-mute)' },
};

/** Forma + color: el estado nunca depende solo del color (círculo = ok, triángulo = observación, rombo = caído). */
export function HealthShape({ h, size = 14 }: { h: Health; size?: number }) {
  const c = HEALTH_META[h].color;
  const s = size;
  return (
    <svg width={s} height={s} viewBox="0 0 14 14" aria-hidden="true" className="shrink-0">
      {h === 'ok' && <circle cx="7" cy="7" r="5.5" fill={c} />}
      {h === 'warn' && <path d="M7 1.5 13 12.5H1z" fill={c} />}
      {h === 'down' && <path d="M7 .8 13.2 7 7 13.2.8 7z" fill={c} />}
      {h === 'unverified' && <circle cx="7" cy="7" r="5" fill="none" stroke={c} strokeWidth="2" strokeDasharray="3 2.2" />}
      {h === 'unknown' && <circle cx="7" cy="7" r="5" fill="none" stroke={c} strokeWidth="1.6" />}
      {h === 'unchecked' && <path d="M3 7h8" stroke={c} strokeWidth="2" strokeLinecap="round" />}
    </svg>
  );
}

export function healthDetail(c: ChannelRow): string {
  const m = HEALTH_META[c.health];
  const parts = [m.label];
  if (c.health === 'warn' || c.health === 'down') parts.push(`strikes ${c.strikes}/${c.strikes_to_down}`);
  if (c.latency_ms != null) parts.push(`${c.latency_ms} ms`);
  if (c.quality?.height) parts.push(`${c.quality.height}p`);
  parts.push(`revisado ${ago(c.last_checked_at)}`);
  return parts.join(' · ');
}

export function HealthCell({ c }: { c: ChannelRow }) {
  const m = HEALTH_META[c.health];
  return (
    <span className="inline-flex items-center gap-2 text-sm" title={healthDetail(c)}>
      <HealthShape h={c.health} />
      <span className="text-dim">{m.label}</span>
      {c.quality?.height ? <span className="rounded bg-ink-3 px-1.5 py-0.5 text-xs text-paper">{c.quality.height}p</span> : null}
    </span>
  );
}
