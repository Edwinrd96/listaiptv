import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { batchItems, batchSummary, commitBatch, createImportBatch, discardBatch, friendly, setItemsSelected } from '../api';
import type { BatchSummary, ImportItem, TestState } from '../api/types';
import { parseM3U, type ParsedItem } from '../lib/m3u';
import { Modal } from './Modal';

const btn = 'rounded border border-line px-2.5 py-1 text-sm hover:bg-ink-3 disabled:opacity-50';
const primary = 'rounded-md bg-paper px-3 py-2 text-sm font-medium text-ink disabled:opacity-60';
const STATE: Record<TestState, { label: string; cls: string }> = {
  pending: { label: 'En cola', cls: 'text-dim' }, testing: { label: 'Probando…', cls: 'text-warn' }, ok: { label: 'Funciona', cls: 'text-ok' },
  fail: { label: 'Falla', cls: 'text-down' }, skipped: { label: 'Sin probar', cls: 'text-dim' },
};
type Filter = 'all' | TestState;

export function ImportModal({ playlistId, onClose, onDone }: { playlistId: string; onClose: () => void; onDone: (channels: number) => void }) {
  const [text, setText] = useState(''); const [parsed, setParsed] = useState<ParsedItem[] | null>(null);
  const [batch, setBatch] = useState<string | null>(null); const [sum, setSum] = useState<BatchSummary | null>(null); const [items, setItems] = useState<ImportItem[]>([]);
  const [filter, setFilter] = useState<Filter>('all'); const [shown, setShown] = useState(200); const [includeFailed, setIncludeFailed] = useState(false); const [enrich, setEnrich] = useState(true);
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [stalled, setStalled] = useState(false);
  const startedAt = useRef(0);

  function analyze(src: string) {
    setErr(null); const p = parseM3U(src);
    if (!p.length) { setParsed(null); setErr('No encontré canales en ese texto. Una lista M3U empieza con #EXTM3U y cada canal tiene una línea #EXTINF y una URL.'); return; }
    setParsed(p);
  }
  async function onFile(f: File | undefined) { if (!f) return; const t = await f.text(); setText(t); analyze(t); }

  async function start() {
    if (!parsed) return; setBusy(true); setErr(null);
    try {
      const r = await createImportBatch(playlistId, parsed.map((p) => ({ name: p.name, url: p.url, group: p.group, logo: p.logo, tvg_id: p.tvg_id, referer: p.referer, ua: p.ua })), `Importación ${new Date().toLocaleString('es-DO')}`, true);
      startedAt.current = Date.now(); setBatch(r.batch_id);
    } catch (e) { setErr(friendly((e as Error).message)); } finally { setBusy(false); }
  }

  const refresh = useCallback(async (id: string) => {
    const [s, it] = await Promise.all([batchSummary(id), batchItems(id)]); setSum(s); setItems(it);
    return s;
  }, []);
  useEffect(() => {
    if (!batch) return; let stop = false; let t: number;
    const tick = async () => {
      try { const s = await refresh(batch); if (stop) return; if (s.status === 'testing') { setStalled(Date.now() - startedAt.current > 25_000 && !(s.counts.ok || s.counts.fail || s.counts.testing)); t = window.setTimeout(tick, 2000); } }
      catch (e) { if (!stop) setErr((e as Error).message); }
    };
    void tick(); return () => { stop = true; window.clearTimeout(t); };
  }, [batch, refresh]);

  const counts = sum?.counts ?? {}; const total = items.length; const tested = (counts.ok ?? 0) + (counts.fail ?? 0);
  const waiting = (counts.pending ?? 0) + (counts.testing ?? 0);
  const visible = useMemo(() => items.filter((i) => filter === 'all' || i.test_state === filter), [items, filter]);
  const willImport = items.filter((i) => i.selected && (includeFailed || i.test_state === 'ok' || i.test_state === 'skipped')).length;

  async function toggle(i: ImportItem) { setItems((p) => p.map((x) => (x.id === i.id ? { ...x, selected: !x.selected } : x))); try { await setItemsSelected([i.id], !i.selected); } catch (e) { setErr((e as Error).message); } }
  async function bulk(ids: number[], sel: boolean) { setItems((p) => p.map((x) => (ids.includes(x.id) ? { ...x, selected: sel } : x))); try { await setItemsSelected(ids, sel); } catch (e) { setErr((e as Error).message); } }
  async function commit() {
    if (!batch) return; setBusy(true); setErr(null);
    try { const r = await commitBatch(batch, !includeFailed, enrich); onDone(r.channels); } catch (e) { setErr(friendly((e as Error).message)); setBusy(false); }
  }
  async function discard() { if (batch) await discardBatch(batch).catch(() => {}); onClose(); }

  const footer = !batch
    ? <><button type="button" className={btn} onClick={onClose}>Cancelar</button><button type="button" className={primary} disabled={!parsed || busy} onClick={start}>{busy ? 'Enviando…' : parsed ? `Analizar y probar ${parsed.length} canales` : 'Analizar y probar'}</button></>
    : <><button type="button" className={btn} onClick={discard} disabled={busy}>Descartar</button>
        <button type="button" className={primary} disabled={busy || willImport === 0} onClick={commit}>{busy ? 'Importando…' : `Importar ${willImport} ${willImport === 1 ? 'canal' : 'canales'}`}</button></>;

  return (
    <Modal title="Importar lista" wide onClose={() => { if (batch && sum?.status !== 'imported') void discardBatch(batch).catch(() => {}); onClose(); }} footer={footer}>
      {err && <p role="alert" className="rounded border border-down/40 bg-down/10 px-3 py-2 text-sm text-down">{err}</p>}
      {!batch ? (
        <div className="space-y-3">
          <p className="text-sm text-dim">Pega el contenido de una lista M3U o sube el archivo. Antes de importar probamos cada canal y los ordenamos por categoría; los repetidos se agrupan como respaldo del mismo canal. Tu lista no se envía a nadie hasta que pulses «Analizar».</p>
          <label className="block text-sm">Contenido M3U
            <textarea value={text} onChange={(e) => { setText(e.target.value); setParsed(null); }} onBlur={() => text.trim() && analyze(text)} rows={9} spellCheck={false} placeholder={'#EXTM3U\n#EXTINF:-1 tvg-id="" group-title="Noticias",Mi canal\nhttps://…/index.m3u8'}
              className="mt-1 w-full rounded-md border border-line bg-ink px-3 py-2 font-mono text-xs placeholder:text-dim" />
          </label>
          <div className="flex flex-wrap items-center gap-3">
            <label className={`${btn} cursor-pointer`}>Subir archivo<input type="file" accept=".m3u,.m3u8,.txt,audio/mpegurl,text/plain" className="sr-only" onChange={(e) => void onFile(e.target.files?.[0])} /></label>
            <button type="button" className={btn} onClick={() => analyze(text)} disabled={!text.trim()}>Leer lista</button>
            {parsed && <p role="status" className="text-sm text-ok">{parsed.length} canales encontrados{parsed.some((p) => p.referer || p.ua) ? ' · se conservan sus cabeceras' : ''}.</p>}
          </div>
          {parsed && <ul className="max-h-40 overflow-y-auto rounded border border-line text-sm" aria-label="Vista previa">{parsed.slice(0, 8).map((p, i) => <li key={i} className="flex gap-3 border-b border-line px-3 py-1.5 last:border-0"><span className="min-w-0 flex-1 truncate">{p.name}</span><span className="truncate text-dim">{p.group || 'Sin categoría'}</span></li>)}{parsed.length > 8 && <li className="px-3 py-1.5 text-dim">y {parsed.length - 8} más…</li>}</ul>}
        </div>
      ) : (
        <div className="space-y-4">
          <div>
            <p className="text-sm" role="status">{sum?.status === 'testing' ? `Probando… ${tested} de ${total}` : `Pruebas terminadas: ${counts.ok ?? 0} funcionan, ${counts.fail ?? 0} fallan${counts.skipped ? `, ${counts.skipped} sin probar` : ''}.`}</p>
            <div className="mt-2 flex h-2 overflow-hidden rounded-full bg-ink-3" role="img" aria-label="Progreso de pruebas">
              <span className="bg-ok" style={{ width: `${total ? ((counts.ok ?? 0) / total) * 100 : 0}%` }} /><span className="bg-down" style={{ width: `${total ? ((counts.fail ?? 0) / total) * 100 : 0}%` }} />
              <span className="bg-warn/60" style={{ width: `${total ? ((counts.testing ?? 0) / total) * 100 : 0}%` }} />
            </div>
            {stalled && waiting > 0 && <p className="mt-2 rounded border border-warn/40 bg-warn/10 px-3 py-2 text-sm text-warn">El motor todavía no empezó a probar. Puedes esperar, o marcar «Importar también los que fallan o no se probaron» e importar ya; el motor los revisará después.</p>}
          </div>
          <div className="flex flex-wrap items-center gap-2" role="group" aria-label="Filtrar por resultado">
            {([['all', 'Todos', total], ['ok', 'Funcionan', counts.ok ?? 0], ['fail', 'Fallan', counts.fail ?? 0], ['pending', 'En cola', waiting], ['skipped', 'Sin probar', counts.skipped ?? 0]] as [Filter, string, number][]).map(([k, l, n]) => (
              <button key={k} type="button" aria-pressed={filter === k} onClick={() => { setFilter(k); setShown(200); }} className={`rounded-full border px-3 py-1 text-sm ${filter === k ? 'border-paper text-paper' : 'border-line text-dim hover:text-paper'}`}>{l} {n}</button>
            ))}
            <span className="ml-auto flex gap-2"><button type="button" className={btn} onClick={() => void bulk(visible.map((i) => i.id), true)}>Marcar visibles</button><button type="button" className={btn} onClick={() => void bulk(visible.map((i) => i.id), false)}>Quitar visibles</button></span>
          </div>
          <ul className="divide-y divide-line rounded border border-line" aria-label="Canales a importar">
            {visible.slice(0, shown).map((i) => {
              const st = STATE[i.test_state]; const name = enrich ? i.enriched?.name ?? i.raw.name : i.raw.name; const grp = enrich ? i.enriched?.group ?? i.raw.group : i.raw.group;
              return (
                <li key={i.id} className="flex items-center gap-3 px-3 py-2 text-sm">
                  <input type="checkbox" checked={i.selected} onChange={() => void toggle(i)} aria-label={`Importar ${name}`} className="size-4 accent-[var(--color-focus)]" />
                  <span className="min-w-0 flex-1"><span className="block truncate">{name}{i.enriched?.quality ? <span className="ml-2 rounded bg-ink-3 px-1.5 py-0.5 text-xs text-dim">{i.enriched.quality}</span> : null}</span>
                    <span className="block truncate text-xs text-dim">{grp || 'Sin categoría'}{i.enriched?.origin === 'catalog' ? ' · reconocido en el catálogo' : ''}{i.test_error ? ` · ${i.test_error}` : ''}</span></span>
                  <span className={`shrink-0 ${st.cls}`}>{st.label}{i.test_latency_ms && i.test_state === 'ok' ? ` · ${i.test_latency_ms} ms` : ''}</span>
                </li>
              );
            })}
            {visible.length === 0 && <li className="px-3 py-4 text-dim">Ningún canal en este filtro.</li>}
          </ul>
          {visible.length > shown && <button type="button" className={btn} onClick={() => setShown((n) => n + 300)}>Mostrar más ({visible.length - shown} restantes)</button>}
          <div className="space-y-2 border-t border-line pt-3">
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={includeFailed} onChange={(e) => setIncludeFailed(e.target.checked)} className="size-4 accent-[var(--color-focus)]" /> Importar también los que fallan o no se probaron</label>
            <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={enrich} onChange={(e) => setEnrich(e.target.checked)} className="size-4 accent-[var(--color-focus)]" /> Ordenar y completar con el catálogo (nombres, categorías, logos, guía)</label>
          </div>
        </div>
      )}
    </Modal>
  );
}
