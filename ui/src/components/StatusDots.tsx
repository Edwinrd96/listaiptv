import type { PlaylistStatus } from '../api/types';
import { ago } from '../lib/format';

function Dot({ ok, label, hint, pulse }: { ok: boolean | null; label: string; hint: string; pulse?: boolean }) {
  const color = ok === null ? 'var(--color-mute)' : ok ? 'var(--color-ok)' : 'var(--color-down)';
  return (
    <span className="inline-flex items-center gap-1.5 text-sm text-dim" title={hint}>
      <span className={`size-2.5 rounded-full ${pulse ? 'pulse' : ''}`} style={{ background: color }} aria-hidden="true" />
      <span>{label}</span>
      <span className="sr-only">{ok === null ? 'sin datos' : ok ? 'en línea' : 'sin conexión'}</span>
    </span>
  );
}

export function StatusDots({ worker, db, status }: { worker: boolean | null; db: boolean | null; status: PlaylistStatus | null }) {
  const eng = status?.engine;
  return (
    <div className="flex items-center gap-4" aria-label="Estado de los servicios">
      <Dot ok={worker} label="Worker" hint={worker === null ? 'Sin configurar: define VITE_WORKER_URL para activarlo' : worker ? 'La API responde' : 'La API no responde'} />
      <Dot ok={db} label="Base" hint={db ? 'Base de datos conectada' : 'No se pudo consultar la base de datos'} />
      <Dot ok={eng ? eng.online : null} label={eng?.vantage ? `Motor ${eng.vantage}` : 'Motor'} pulse={!!eng?.online}
        hint={eng?.last_seen_at ? `Último latido ${ago(eng.last_seen_at)}` : 'Aún no hay un motor conectado'} />
    </div>
  );
}
