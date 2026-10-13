import { useCallback, useEffect, useState } from 'react';
import { addEpgSource, createOutput, deleteOutput, epgStatus, friendly, listEpgSources, myOutputs, outputUrl, removeEpgSource, requestSync, rotateToken, updateOutput } from '../api';
import type { Entitlements, EpgSource, EpgStatus, OutputRow } from '../api/types';
import { ago } from '../lib/format';
import { env } from '../lib/supabase';
import { Modal } from './Modal';

const btn = 'rounded border border-line px-2.5 py-1 text-sm hover:bg-ink-3 disabled:opacity-50';
const KINDS: { kind: 'm3u' | 'vlc' | 'txt' | 'e2' | 'epg'; label: string; hint: string; extra?: boolean }[] = [
  { kind: 'm3u', label: 'M3U', hint: 'Para casi todo: TiviMate, IPTV Smarters, Kodi, Smart TV.' },
  { kind: 'vlc', label: 'M3U para VLC', hint: 'Incluye las cabeceras en líneas que VLC entiende.' },
  { kind: 'txt', label: 'TXT', hint: 'Nombre,URL por línea (reproductores simples).', extra: true },
  { kind: 'e2', label: 'Enigma2', hint: 'Bouquet para decodificadores Enigma2.', extra: true },
  { kind: 'epg', label: 'Guía (EPG)', hint: 'Si tu reproductor no la toma sola de la lista, pégala en «URL de EPG / XMLTV».' },
];

function CopyButton({ text }: { text: string }) {
  const [done, setDone] = useState(false);
  async function copy() {
    try { await navigator.clipboard.writeText(text); } catch { const t = document.createElement('textarea'); t.value = text; document.body.append(t); t.select(); document.execCommand('copy'); t.remove(); }
    setDone(true); window.setTimeout(() => setDone(false), 1800);
  }
  return <button type="button" onClick={copy} className={btn} aria-live="polite">{done ? 'Copiado' : 'Copiar'}</button>;
}

function OutputCard({ o, ent, onChange, onDelete }: { o: OutputRow; ent: Entitlements | null; onChange: () => void; onDelete: () => void }) {
  const [err, setErr] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  const extra = ent ? !!ent.features['export_formats_extra'] : false;
  const smart = ent ? !!ent.features['smart_delivery'] : false;
  async function run(fn: () => Promise<unknown>) { setBusy(true); setErr(null); try { await fn(); onChange(); } catch (e) { setErr(friendly((e as Error).message)); } finally { setBusy(false); } }
  return (
    <section className="rounded-lg border border-line p-4" aria-label={`Enlace ${o.name}`}>
      <div className="flex flex-wrap items-center gap-2">
        <h3 className="min-w-0 flex-1 truncate font-medium">{o.name}</h3>
        <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={o.enabled} onChange={(e) => run(() => updateOutput(o.id, { enabled: e.target.checked }))} className="size-4 accent-[var(--color-focus)]" /> Activo</label>
      </div>
      {!o.enabled && <p className="mt-1 text-sm text-warn">Este enlace está apagado: quien lo use recibirá «no encontrada».</p>}
      <ul className="mt-3 space-y-2">
        {KINDS.map((k) => {
          const locked = !!k.extra && !extra; const url = outputUrl(o.token, k.kind);
          return (
            <li key={k.kind} className="flex flex-wrap items-center gap-2">
              <div className="w-36 shrink-0"><p className="text-sm font-medium">{k.label}</p></div>
              {locked ? <p className="min-w-0 flex-1 text-sm text-dim">Incluido en Pro.</p> : <>
                <input readOnly value={url} aria-label={`Enlace ${k.label}`} onFocus={(e) => e.currentTarget.select()} className="min-w-0 flex-1 rounded-md border border-line bg-ink px-2.5 py-1.5 font-mono text-xs" />
                <CopyButton text={url} />
              </>}
              <p className="basis-full pl-0 text-xs text-dim md:pl-[9.5rem]">{k.hint}</p>
            </li>
          );
        })}
      </ul>
      {!env.worker && <p className="mt-3 rounded border border-warn/40 bg-warn/10 px-3 py-2 text-sm text-warn">Falta definir <code>VITE_WORKER_URL</code> en el panel: los enlaces muestran un marcador en lugar de tu dirección real.</p>}
      <div className="mt-4 grid gap-3 border-t border-line pt-3 md:grid-cols-2">
        <label className="text-sm">Qué incluye
          <select value={o.only_healthy ? 'ok' : 'all'} onChange={(e) => run(() => updateOutput(o.id, { only_healthy: e.target.value === 'ok' }))} className="mt-1 w-full rounded-md border border-line bg-ink px-3 py-2">
            <option value="ok">Solo canales que funcionan</option><option value="all">Todos, aunque estén caídos</option>
          </select>
        </label>
        <label className="text-sm">Cómo se entrega
          <select value={o.delivery} onChange={(e) => run(() => updateOutput(o.id, { delivery: e.target.value as 'direct' | 'smart' }))} className="mt-1 w-full rounded-md border border-line bg-ink px-3 py-2">
            <option value="direct">Directo: la URL del canal va en la lista</option>
            <option value="smart" disabled={!smart}>Inteligente: salta solo al respaldo{smart ? '' : ' (Pro)'}</option>
          </select>
        </label>
      </div>
      {err && <p role="alert" className="mt-2 text-sm text-down">{err}</p>}
      <div className="mt-4 flex flex-wrap gap-2">
        <button type="button" disabled={busy} className={btn} onClick={() => { if (confirm('El enlace actual dejará de funcionar en todos tus reproductores y tendrás que pegar el nuevo. ¿Cambiarlo?')) void run(() => rotateToken(o.id)); }}>Cambiar el enlace</button>
        <button type="button" disabled={busy} className={`${btn} text-down`} onClick={() => { if (confirm(`¿Borrar el enlace «${o.name}»?`)) void run(() => deleteOutput(o.id).then(onDelete)); }}>Borrar</button>
      </div>
    </section>
  );
}


function EpgSection({ playlistId }: { playlistId: string }) {
  const [src, setSrc] = useState<EpgSource[] | null>(null); const [st, setSt] = useState<EpgStatus | null>(null); const [url, setUrl] = useState(''); const [err, setErr] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  const load = useCallback(() => { listEpgSources(playlistId).then(setSrc).catch((e) => setErr(friendly((e as Error).message))); epgStatus(playlistId).then(setSt).catch(() => {}); }, [playlistId]);
  useEffect(load, [load]);
  const running = st?.job && (st.job.status === 'queued' || st.job.status === 'running');
  useEffect(() => { if (!running) return; const t = window.setInterval(load, 3000); return () => window.clearInterval(t); }, [running, load]);
  async function run(fn: () => Promise<unknown>) { setBusy(true); setErr(null); try { await fn(); load(); } catch (e) { setErr(friendly((e as Error).message)); } finally { setBusy(false); } }
  const a = st?.artifact; const m = a?.meta;
  return (
    <section className="rounded-lg border border-line p-4" aria-label="Guía de programación">
      <h3 className="font-medium">Guía de programación (EPG)</h3>
      <p className="mt-1 text-sm text-dim">Agrega la dirección de un archivo XMLTV (termina en .xml o .xml.gz). El motor se queda solo con los canales de tu lista y los próximos días, y la actualiza sola cada 12 horas.</p>
      {err && <p role="alert" className="mt-2 text-sm text-down">{err}</p>}
      <ul className="mt-3 divide-y divide-line rounded border border-line" aria-label="Fuentes de guía">
        {src && src.length === 0 && <li className="px-3 py-3 text-sm text-dim">Aún no hay fuentes.</li>}
        {(src ?? []).map((s) => (
          <li key={s.id} className="flex items-center gap-3 px-3 py-2 text-sm"><span className="min-w-0 flex-1"><span className="block truncate font-mono text-xs">{s.url}</span><span className={`block truncate text-xs ${s.last_status && !s.last_status.startsWith('ok') ? 'text-down' : 'text-dim'}`}>{s.last_status ? `${s.last_status} · ${ago(s.last_fetched_at)}` : 'Sin leer todavía'}</span></span>
            <button type="button" className={btn} disabled={busy} onClick={() => void run(() => removeEpgSource(s.id))}>Quitar</button></li>))}
      </ul>
      <form className="mt-3 flex flex-wrap gap-2" onSubmit={(e) => { e.preventDefault(); void run(async () => { await addEpgSource(playlistId, url); setUrl(''); }); }}>
        <input type="url" required value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://…/epg.xml.gz" aria-label="Dirección de la guía" className="min-w-0 flex-1 rounded-md border border-line bg-ink px-3 py-2 text-sm placeholder:text-dim" />
        <button type="submit" className={btn} disabled={busy}>Agregar fuente</button>
      </form>
      <div className="mt-3 flex flex-wrap items-center gap-3">
        <button type="button" className="rounded-md bg-paper px-3 py-2 text-sm font-medium text-ink disabled:opacity-60" disabled={busy || !!running || !src?.length} onClick={() => void run(() => requestSync(playlistId, 'epg'))}>{running ? 'Generando…' : 'Actualizar guía ahora'}</button>
        <p className="text-sm" role="status">
          {running ? <span className="text-warn">El motor está armando la guía…</span>
            : st?.job?.status === 'failed' && (!a || new Date(st.job.requested_at) > new Date(a.built_at)) ? <span className="text-down">No se pudo: {st.job.error ?? 'error desconocido'}</span>
            : a && m ? <span className="text-ok">Lista {ago(a.built_at)}: {m.channels} de {m.wanted} canales con programación ({m.programmes} programas).</span> : <span className="text-dim">Todavía no se ha generado.</span>}
        </p>
      </div>
      {m && m.missing_sample.length > 0 && <p className="mt-2 text-xs text-dim">Sin programación en esta guía, por ejemplo: {m.missing_sample.slice(0, 5).join(', ')}{m.wanted - m.channels > 5 ? '…' : ''}. Revisa su ID de guía.</p>}
    </section>
  );
}

export function GetListModal({ playlistId, ent, onClose }: { playlistId: string; ent: Entitlements | null; onClose: () => void }) {
  const [rows, setRows] = useState<OutputRow[] | null>(null); const [err, setErr] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  const load = useCallback(() => { myOutputs(playlistId).then(setRows).catch((e) => setErr((e as Error).message)); }, [playlistId]);
  useEffect(load, [load]);
  async function add() { setBusy(true); setErr(null); try { await createOutput(playlistId, `Enlace ${(rows?.length ?? 0) + 1}`); load(); } catch (e) { setErr(friendly((e as Error).message)); } finally { setBusy(false); } }
  return (
    <Modal title="Obtener lista" onClose={onClose} footer={<button type="button" onClick={add} disabled={busy} className="rounded-md bg-paper px-3 py-2 text-sm font-medium text-ink disabled:opacity-60">Crear otro enlace</button>}>
      <p className="text-sm text-dim">Pega uno de estos enlaces en tu reproductor. Se actualiza solo: cuando el motor repara un canal, tu lista cambia sin que hagas nada. No lo compartas: quien lo tenga ve tu lista.</p>
      {err && <p role="alert" className="text-sm text-down">{err}</p>}
      {!rows ? <p className="text-dim" role="status">Cargando enlaces…</p> : rows.length === 0 ? <p className="text-dim">Aún no tienes enlaces. Crea el primero.</p> : rows.map((o) => <OutputCard key={o.id} o={o} ent={ent} onChange={load} onDelete={load} />)}
      <EpgSection playlistId={playlistId} />
    </Modal>
  );
}
