import { useCallback, useEffect, useState } from 'react';
import { friendly, hospital, requestSync } from '../api';
import type { Entitlements, HospitalRow } from '../api/types';
import { Modal } from './Modal';

const btn = 'rounded border border-line px-2.5 py-1 text-sm hover:bg-ink-3 disabled:opacity-50';
const ago = (iso: string | null) => {
  if (!iso) return 'nunca'; const m = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  return m < 1 ? 'hace un momento' : m < 60 ? `hace ${m} min` : m < 1440 ? `hace ${Math.round(m / 60)} h` : `hace ${Math.round(m / 1440)} d`;
};

export function HospitalModal({ playlistId, ent, onClose, onEdit }: { playlistId: string; ent: Entitlements | null; onClose: () => void; onEdit: (channelId: string) => void }) {
  const [rows, setRows] = useState<HospitalRow[] | null>(null); const [err, setErr] = useState<string | null>(null); const [msg, setMsg] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  const load = useCallback(() => { hospital(playlistId).then(setRows).catch((e) => setErr((e as Error).message)); }, [playlistId]);
  useEffect(load, [load]);
  const locked = ent ? !ent.features['hospital'] : false;
  async function recheck() {
    setBusy(true); setErr(null); setMsg(null);
    try { await requestSync(playlistId); setMsg('Pedimos al motor que revise todo. Los canales que se recuperen salen solos del Hospital.'); } catch (e) { setErr(friendly((e as Error).message)); } finally { setBusy(false); }
  }
  const dead = rows?.filter((r) => r.status === 'dead') ?? []; const sick = rows?.filter((r) => r.status === 'in_hospital') ?? [];
  const Row = (r: HospitalRow) => (
    <li key={r.source_id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2.5 text-sm">
      <span className="min-w-0 flex-1"><span className="block truncate font-medium">{r.channel_name}{r.priority > 0 && <span className="ml-2 rounded bg-ink-3 px-1.5 py-0.5 text-xs text-dim">respaldo {r.priority}</span>}</span>
        <span className="block truncate text-xs text-dim">{r.last_error ?? (r.last_http ? `HTTP ${r.last_http}` : 'Sin respuesta')} · última prueba {ago(r.last_checked_at)}</span></span>
      <span className={`shrink-0 text-xs ${r.status === 'dead' ? 'text-down' : 'text-warn'}`}>{r.status === 'dead' ? 'Declarado muerto' : `Quedan ${r.days_left} ${r.days_left === 1 ? 'día' : 'días'}`}</span>
      <button type="button" className={btn} onClick={() => { onClose(); onEdit(r.channel_id); }} aria-label={`Editar ${r.channel_name}`}>Editar</button>
    </li>
  );
  return (
    <Modal title="Hospital de canales" wide onClose={onClose} footer={<button type="button" className="rounded-md bg-paper px-3 py-2 text-sm font-medium text-ink disabled:opacity-60" disabled={busy || locked} onClick={recheck}>{busy ? 'Pidiendo…' : 'Revisar todo ahora'}</button>}>
      <p className="text-sm text-dim">Aquí están los canales que dejaron de responder. No se borran: el motor los vuelve a probar de vez en cuando, y si un canal revive, sale solo. Si pasan 7 días caídos se declaran muertos y solo se revisan una vez por semana.</p>
      {locked && <p className="rounded border border-warn/40 bg-warn/10 px-3 py-2 text-sm text-warn">El Hospital con sondeo espaciado es parte de Pro. En el plan gratis los canales caídos se siguen revisando como siempre.</p>}
      {err && <p role="alert" className="text-sm text-down">{err}</p>}{msg && <p role="status" className="text-sm text-ok">{msg}</p>}
      {!rows ? <p className="text-dim" role="status">Cargando…</p> : rows.length === 0 ? <p className="rounded border border-line px-4 py-6 text-center text-dim">Ningún canal está caído. Todo en orden.</p> : (<>
        {sick.length > 0 && <section aria-label="En el hospital"><h3 className="mb-2 text-sm font-medium">En observación ({sick.length})</h3><ul className="divide-y divide-line rounded border border-line">{sick.map(Row)}</ul></section>}
        {dead.length > 0 && <section aria-label="Declarados muertos"><h3 className="mb-2 text-sm font-medium">Declarados muertos ({dead.length})</h3><ul className="divide-y divide-line rounded border border-line">{dead.map(Row)}</ul></section>}
      </>)}
    </Modal>
  );
}
