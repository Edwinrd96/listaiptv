import type { Entitlements } from '../api/types';

export function PlanChip({ ent, onClick }: { ent: Entitlements | null; onClick?: () => void }) {
  if (!ent) return null;
  const pct = ent.next_level ? Math.min(100, Math.round((ent.xp / ent.next_level.xp_needed) * 100)) : 100;
  const title = ent.next_level ? `${ent.xp} XP · te faltan ${ent.next_level.xp_needed - ent.xp} para ${ent.next_level.name}` : `${ent.xp} XP · nivel máximo`;
  return (
    <button type="button" onClick={onClick} className="flex items-center gap-2 whitespace-nowrap rounded-md border border-line px-2.5 py-1.5 text-sm hover:bg-ink-2" title={title} aria-label={`Mis logros: ${title}`}>
      <span className="font-semibold">{ent.plan === 'pro' ? 'Pro' : 'Gratis'}</span>
      <span className="text-dim">nivel {ent.level}</span>
      <span className="h-1 w-10 overflow-hidden rounded-full bg-ink-3" aria-hidden="true"><span className="block h-full bg-focus" style={{ width: `${pct}%` }} /></span>
    </button>
  );
}
