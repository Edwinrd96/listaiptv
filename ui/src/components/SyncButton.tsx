import { useState } from 'react';
import { friendly, requestSync } from '../api';
import type { SyncJob } from '../api/types';
import { ago } from '../lib/format';

export function SyncButton({ playlistId, job, onDone }: { playlistId: string; job: SyncJob | null; onDone: () => void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const active = job && (job.status === 'queued' || job.status === 'running');
  async function go() {
    setBusy(true); setErr(null);
    try { await requestSync(playlistId); onDone(); } catch (e) { setErr(friendly((e as Error).message)); } finally { setBusy(false); }
  }
  const label = active ? (job!.status === 'queued' ? 'En cola…' : 'Sincronizando…') : 'Forzar sincronización';
  const last = !active && job ? (job.status === 'succeeded' ? `Última: ${ago(job.finished_at)}` : job.status === 'failed' ? 'La última falló' : '') : '';
  return (
    <div className="flex flex-col items-end gap-0.5">
      <button type="button" onClick={go} disabled={busy || !!active}
        className="rounded-md bg-paper px-3.5 py-2 text-sm font-semibold text-ink transition hover:bg-white disabled:cursor-progress disabled:opacity-70">
        <span className={active ? 'pulse' : ''}>{label}</span>
      </button>
      {(err || last) && <span className={`text-xs ${err || job?.status === 'failed' ? 'text-down' : 'text-dim'}`} role={err ? 'alert' : undefined}>{err ?? last}</span>}
    </div>
  );
}
