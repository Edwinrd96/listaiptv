import { useCallback, useEffect, useRef, useState } from 'react';
import { channelNames, deleteLayout, friendly, listLayouts, playSession, primarySource, saveLayout, searchMyChannels } from '../api';
import type { Entitlements, MvLayout, MvSaved, MvSlot } from '../api/types';
import { env } from '../lib/supabase';
import { Modal } from './Modal';

const btn = 'rounded border border-line px-2.5 py-1 text-sm hover:bg-ink-3 disabled:opacity-50';
const field = 'rounded-md border border-line bg-ink px-3 py-1.5 text-sm placeholder:text-dim';
const LAYOUTS: [MvLayout, string][] = [['1x1', 'Uno solo'], ['1x2', 'Dos lado a lado'], ['2x2', 'Cuadrícula de cuatro'], ['pip', 'Imagen en imagen'], ['1+3', 'Uno grande y tres chicos']];

/** Un cuadro de la multivista: intenta directo; si el origen no deja (CORS / Referer), usa el proxy de sesión del Worker (≤90 s). */
function Tile({ slot, audio, onAudio, onRemove, small }: { slot: MvSlot; audio: boolean; onAudio: () => void; onRemove: () => void; small?: boolean }) {
  const video = useRef<HTMLVideoElement>(null); const [msg, setMsg] = useState('Conectando…'); const [mode, setMode] = useState<'direct' | 'proxy'>('direct'); const [ok, setOk] = useState(false);
  useEffect(() => {
    const v = video.current; if (!v) return; let hls: import('hls.js').default | null = null; let stop = false; let cap: number | undefined; setOk(false);
    const fail = (why: string) => { if (stop) return; if (mode === 'direct' && env.worker) { setMsg('Probando vía servidor…'); setMode('proxy'); } else setMsg(why); };
    (async () => {
      const src0 = await primarySource(slot.channel_id).catch(() => null);
      if (!src0) { setMsg('Este canal no tiene URL.'); return; }
      let url = src0.url;
      if (mode === 'proxy') {
        try { const s = await playSession({ url, referer: src0.referer ?? undefined, user_agent: src0.user_agent ?? undefined }); url = s.play_url; cap = window.setTimeout(() => { v.pause(); setMsg('Pausado a los 90 s para cuidar la cuota.'); }, 90_000); } catch (e) { setMsg((e as Error).message); return; }
      } else if (location.protocol === 'https:' && url.startsWith('http://')) { fail('El canal es http y esta página https: el navegador lo bloquea.'); return; }
      const { default: Hls } = await import('hls.js'); if (stop) return;
      if (Hls.isSupported()) {
        hls = new Hls({ maxBufferLength: 10, startLevel: small ? 0 : -1 });
        hls.on(Hls.Events.MANIFEST_PARSED, () => { setOk(true); void v.play().catch(() => setMsg('Pulsa ▶')); });
        hls.on(Hls.Events.ERROR, (_e, d) => { if (d.fatal) fail('No se pudo abrir desde el navegador.'); });
        hls.loadSource(url); hls.attachMedia(v);
      } else if (v.canPlayType('application/vnd.apple.mpegurl')) { v.src = url; setOk(true); void v.play(); } else setMsg('Este navegador no reproduce HLS.');
    })();
    return () => { stop = true; window.clearTimeout(cap); hls?.destroy(); };
  }, [slot.channel_id, mode, small]);
  return (
    <figure className="relative min-h-0 overflow-hidden rounded-lg border border-line bg-black" aria-label={slot.name}>
      <video ref={video} muted={!audio} playsInline controls={false} className="size-full object-contain" />
      {!ok && <p className="absolute inset-0 grid place-items-center p-2 text-center text-sm text-dim" role="status">{msg}</p>}
      <figcaption className="absolute inset-x-0 top-0 flex items-center gap-1 bg-gradient-to-b from-black/80 to-transparent p-1.5 text-xs">
        <span className="min-w-0 flex-1 truncate font-medium">{slot.name}</span>
        <button type="button" onClick={onAudio} aria-pressed={audio} aria-label={audio ? `Silenciar ${slot.name}` : `Escuchar ${slot.name}`} className={`rounded px-1.5 py-0.5 ${audio ? 'bg-paper text-ink' : 'bg-black/60 text-paper'}`}>{audio ? 'Con audio' : 'Mudo'}</button>
        <button type="button" onClick={onRemove} aria-label={`Quitar ${slot.name}`} className="rounded bg-black/60 px-1.5 py-0.5">Quitar</button>
      </figcaption>
    </figure>
  );
}

export function MultiviewModal({ playlistId, ent, onClose }: { playlistId: string; ent: Entitlements | null; onClose: () => void }) {
  const max = Math.max(1, Number(ent?.features['multiview_slots'] ?? 2));
  const [layout, setLayout] = useState<MvLayout>('1x2'); const [slots, setSlots] = useState<MvSlot[]>([]); const [audio, setAudio] = useState(0);
  const [q, setQ] = useState(''); const [hits, setHits] = useState<{ id: string; name: string }[]>([]); const [saved, setSaved] = useState<MvSaved[]>([]); const [name, setName] = useState('');
  const [err, setErr] = useState<string | null>(null); const [msg, setMsg] = useState<string | null>(null);
  const loadSaved = useCallback(() => { listLayouts().then(setSaved).catch((e) => setErr(friendly((e as Error).message))); }, []);
  useEffect(loadSaved, [loadSaved]);
  useEffect(() => { if (q.trim().length < 2 || slots.length >= max) { setHits([]); return; } const t = window.setTimeout(() => { searchMyChannels(playlistId, q).then(setHits).catch(() => setHits([])); }, 250); return () => window.clearTimeout(t); }, [q, playlistId, slots.length, max]);
  const shown = layout === '1x1' ? 1 : layout === '1x2' ? 2 : 4;
  function add(c: { id: string; name: string }) { if (slots.some((s) => s.channel_id === c.id)) { setErr('Ese canal ya está en la multivista.'); return; } setErr(null); setSlots((p) => [...p, { channel_id: c.id, name: c.name, muted: true }]); setQ(''); setHits([]); }
  function remove(i: number) { setSlots((p) => p.filter((_, k) => k !== i)); setAudio((a) => (a === i ? 0 : a > i ? a - 1 : a)); }
  async function save() { setErr(null); setMsg(null); try { await saveLayout(name, layout, slots.map((s, i) => ({ ...s, muted: i !== audio }))); setMsg('Guardada.'); setName(''); loadSaved(); } catch (e) { setErr(friendly((e as Error).message)); } }
  async function load(l: MvSaved) {
    setErr(null); const names = await channelNames(l.slots.map((s) => s.channel_id)).catch(() => ({} as Record<string, string>));
    const next = l.slots.filter((s) => names[s.channel_id]).slice(0, max).map((s) => ({ channel_id: s.channel_id, name: names[s.channel_id], muted: s.muted !== false }));
    setLayout(l.layout); setSlots(next); setAudio(Math.max(0, next.findIndex((s) => !s.muted)));
  }
  const visible = slots.slice(0, layout === 'pip' ? max : shown);
  const grid = layout === '1x1' ? 'grid-cols-1' : layout === '1x2' ? 'grid-cols-1 md:grid-cols-2' : layout === '2x2' ? 'grid-cols-2' : layout === '1+3' ? 'grid-cols-1 md:grid-cols-[2fr_1fr] md:grid-rows-3' : '';
  const tile = (s: MvSlot, i: number, small?: boolean) => <Tile key={s.channel_id} slot={s} small={small} audio={i === audio} onAudio={() => setAudio(i)} onRemove={() => remove(i)} />;
  return (
    <Modal title="Multivista" full onClose={onClose}>
      <div className="flex flex-wrap items-end gap-3">
        <label className="text-sm">Distribución<select value={layout} onChange={(e) => setLayout(e.target.value as MvLayout)} className={`${field} ml-2`}>{LAYOUTS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
        <div className="relative"><label className="text-sm">Agregar canal<input value={q} onChange={(e) => setQ(e.target.value)} disabled={slots.length >= max} placeholder={slots.length >= max ? `Máximo ${max} en tu plan` : 'Buscar por nombre'} className={`${field} ml-2 w-56`} /></label>
          {hits.length > 0 && <ul className="absolute z-20 mt-1 w-56 rounded border border-line bg-ink-2 shadow-lg">{hits.map((h) => <li key={h.id}><button type="button" className="w-full px-3 py-1.5 text-left text-sm hover:bg-ink-3" onClick={() => add(h)}>{h.name}</button></li>)}</ul>}</div>
        <span className="text-sm text-dim">{slots.length} de {max} canales</span>
        <span className="ml-auto flex flex-wrap items-center gap-2">
          {saved.length > 0 && <select aria-label="Cargar una guardada" value="" onChange={(e) => { const l = saved.find((x) => x.id === e.target.value); if (l) void load(l); }} className={field}><option value="">Cargar guardada…</option>{saved.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select>}
          <input aria-label="Nombre para guardar" value={name} onChange={(e) => setName(e.target.value)} maxLength={60} placeholder="Nombre" className={`${field} w-32`} />
          <button type="button" className={btn} disabled={!name.trim() || slots.length === 0} onClick={() => void save()}>Guardar</button>
          {saved.length > 0 && <select aria-label="Borrar una guardada" value="" onChange={(e) => { if (e.target.value && confirm('¿Borrar esa multivista guardada?')) void deleteLayout(e.target.value).then(loadSaved).catch((x) => setErr((x as Error).message)); }} className={field}><option value="">Borrar…</option>{saved.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</select>}
        </span>
      </div>
      {err && <p role="alert" className="text-sm text-down">{err}</p>}{msg && <p role="status" className="text-sm text-ok">{msg}</p>}
      {slots.length === 0 ? <p className="grid min-h-[50vh] flex-1 place-items-center rounded-lg border border-dashed border-line text-dim">Agrega hasta {max} canales para verlos a la vez. Solo uno suena: toca «Mudo» en el que quieras escuchar.</p>
        : layout === 'pip' ? (
          <div className="relative min-h-[50vh] flex-1">
            <div className="absolute inset-0 grid">{tile(slots[0], 0)}</div>
            {slots.length > 1 && <div className="absolute bottom-2 right-2 flex max-h-[calc(100%-1rem)] w-[20%] min-w-[8rem] flex-col-reverse gap-2 overflow-hidden">{visible.slice(1).map((s, k) => <div key={s.channel_id} className="aspect-video">{tile(s, k + 1, true)}</div>)}</div>}
          </div>
        ) : (
          <div className={`grid min-h-[50vh] flex-1 auto-rows-min content-start gap-2 md:auto-rows-fr ${grid}`}>{visible.map((s, i) => (layout === '1+3' && i === 0 ? <div key={s.channel_id} className="grid md:row-span-3">{tile(s, i)}</div> : <div key={s.channel_id} className="grid aspect-video md:aspect-auto">{tile(s, i, layout === '1+3' || layout === '2x2')}</div>))}</div>
        )}
      {slots.length > visible.length && <p className="text-sm text-warn">Esta distribución muestra {visible.length}; los otros {slots.length - visible.length} están guardados pero ocultos. Cambia a una distribución más grande.</p>}
    </Modal>
  );
}
