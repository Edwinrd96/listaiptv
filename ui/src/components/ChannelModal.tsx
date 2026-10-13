import { useEffect, useRef, useState } from 'react';
import { deleteChannel, friendly, getChannel, listGroups, probeUrl, saveChannel, searchEpg, validateLogoRemote } from '../api';
import type { ChannelForm, ChannelFull, ProbeReport } from '../api/types';
import type { PlayTarget } from './Player';

const EMPTY: ChannelForm = { name: '', group: '', logo: '', epg: '', chno: '', url1: '', ref1: '', ua1: '', url2: '', ref2: '', ua2: '', res1: '', res2: '', vant: '', catchup: false, ctype: 'append', csource: '', cdays: '', check: true, enabled: true };
const field = 'mt-1 w-full rounded-md border border-line bg-ink px-3 py-2 text-sm placeholder:text-dim';

function toForm(c: ChannelFull): ChannelForm {
  const [a, b] = [c.channel_sources.find((s) => s.priority === 0), c.channel_sources.find((s) => s.priority === 1)];
  return { name: c.name, group: c.groups?.name ?? '', logo: c.logo_url ?? '', epg: c.epg_id ?? '', chno: c.chno?.toString() ?? '',
    url1: a?.url ?? '', ref1: a?.referer ?? '', ua1: a?.user_agent ?? '', url2: b?.url ?? '', ref2: b?.referer ?? '', ua2: b?.user_agent ?? '', res1: a?.resolver ?? '', res2: b?.resolver ?? '', vant: a?.vantage_required ?? b?.vantage_required ?? '',
    catchup: c.catchup_enabled, ctype: c.catchup_type ?? 'append', csource: c.catchup_source ?? '', cdays: c.catchup_days?.toString() ?? '', check: c.check_enabled, enabled: c.enabled };
}

/** Cuadro de logo reactivo: primero el navegador (instantáneo); si falla, el Worker explica el motivo exacto. */
function LogoBox({ url }: { url: string }) {
  const [state, setState] = useState<'idle' | 'ok' | 'bad'>('idle'); const [why, setWhy] = useState('');
  useEffect(() => {
    setWhy(''); if (!/^https?:\/\//i.test(url)) { setState('idle'); return; }
    let live = true; const img = new Image(); img.referrerPolicy = 'no-referrer';
    img.onload = () => live && setState('ok');
    img.onerror = async () => {
      if (!live) return; setState('bad');
      if (url.startsWith('http://') && location.protocol === 'https:') { setWhy('El logo es http y este panel es https: el navegador lo bloquea. Usa la versión https.'); return; }
      try { const r = await validateLogoRemote(url); if (live && !r.ok) setWhy(r.error ?? 'El servidor del logo no entrega una imagen válida.'); } catch { if (live) setWhy('No se pudo cargar la imagen (puede bloquear el acceso desde otras webs).'); }
    };
    const t = window.setTimeout(() => { img.src = url; }, 350);
    return () => { live = false; window.clearTimeout(t); };
  }, [url]);
  return (
    <div className="flex items-center gap-3">
      <div className="grid size-16 shrink-0 place-items-center overflow-hidden rounded bg-ink-3">
        {state === 'ok' ? <img src={url} alt="Vista previa del logo" referrerPolicy="no-referrer" className="size-full object-contain p-1" /> : <span className="text-xs text-dim">{state === 'bad' ? 'Error' : 'Logo'}</span>}
      </div>
      <p className={`text-sm ${state === 'bad' ? 'text-down' : 'text-dim'}`} role={state === 'bad' ? 'alert' : undefined}>{state === 'ok' ? 'El logo carga bien.' : state === 'bad' ? (why || 'No se pudo cargar la imagen.') : 'Pega la URL de una imagen (png, jpg, webp o svg).'}</p>
    </div>
  );
}

function ProbeRow({ url, referer, ua, label, onPlay }: { url: string; referer: string; ua: string; label: string; onPlay: () => void }) {
  const [r, setR] = useState<ProbeReport | null>(null); const [err, setErr] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  useEffect(() => { setR(null); setErr(null); }, [url, referer, ua]);
  async function go() { setBusy(true); setErr(null); try { setR(await probeUrl(url, referer, ua)); } catch (e) { setErr((e as Error).message); } finally { setBusy(false); } }
  const ready = /^https?:\/\//i.test(url);
  return (
    <div className="mt-2 flex flex-wrap items-center gap-2">
      <button type="button" onClick={go} disabled={!ready || busy} className="rounded border border-line px-2.5 py-1 text-sm hover:bg-ink-3 disabled:opacity-50" aria-label={`Probar ${label}`}>{busy ? 'Probando…' : 'Probar'}</button>
      <button type="button" onClick={onPlay} disabled={!ready} className="rounded border border-line px-2.5 py-1 text-sm hover:bg-ink-3 disabled:opacity-50" aria-label={`Reproducir ${label}`}>Reproducir</button>
      {r && <span className={`text-sm ${r.ok ? 'text-ok' : 'text-down'}`}>{r.ok ? `Funciona · ${r.latency_ms} ms${r.variants.length ? ` · ${Math.max(...r.variants.map((v) => v.height ?? 0))}p` : ''}` : `Falla: ${r.error}`}</span>}
      {r?.hint && <span className="basis-full text-sm text-warn">{r.hint}</span>}
      {err && <span className="basis-full text-sm text-down" role="alert">{err}</span>}
    </div>
  );
}

export function ChannelModal({ playlistId, channelId, onClose, onSaved, onPlay }: { playlistId: string; channelId: string | null; onClose: () => void; onSaved: () => void; onPlay: (t: PlayTarget) => void }) {
  const [f, setF] = useState<ChannelForm>(EMPTY); const [orig, setOrig] = useState<ChannelFull | undefined>();
  const [groups, setGroups] = useState<string[]>([]); const [epg, setEpg] = useState<{ guide_id: string; display_name: string }[]>([]);
  const [loading, setLoading] = useState(!!channelId); const [saving, setSaving] = useState(false); const [err, setErr] = useState<string | null>(null); const [adv, setAdv] = useState(false);
  const dlg = useRef<HTMLDialogElement>(null);
  const set = <K extends keyof ChannelForm>(k: K, v: ChannelForm[K]) => setF((p) => ({ ...p, [k]: v }));

  useEffect(() => { dlg.current?.showModal(); void listGroups(playlistId).then(setGroups).catch(() => {}); }, [playlistId]);
  useEffect(() => { if (!channelId) return; getChannel(channelId).then((c) => { setOrig(c); setF(toForm(c)); setAdv(!!(c.channel_sources.some((s) => s.referer || s.user_agent || s.resolver || s.vantage_required) || c.catchup_enabled)); }).catch((e) => setErr((e as Error).message)).finally(() => setLoading(false)); }, [channelId]);
  useEffect(() => { const t = window.setTimeout(() => { void searchEpg(playlistId, f.epg).then(setEpg).catch(() => setEpg([])); }, 250); return () => window.clearTimeout(t); }, [f.epg, playlistId]);

  async function submit(e: React.FormEvent) {
    e.preventDefault(); setSaving(true); setErr(null);
    try { await saveChannel(playlistId, f, orig); onSaved(); } catch (x) { setErr(friendly((x as Error).message)); } finally { setSaving(false); }
  }
  async function remove() { if (!orig || !confirm(`¿Borrar «${orig.name}»? No se puede deshacer desde aquí.`)) return; try { await deleteChannel(orig.id); onSaved(); } catch (x) { setErr((x as Error).message); } }
  const play = (url: string, referer: string, ua: string) => onPlay({ title: f.name || 'Canal', url, referer, ua });

  return (
    <dialog ref={dlg} onClose={onClose} onClick={(e) => { if (e.target === dlg.current) dlg.current?.close(); }}
      className="m-auto w-[min(42rem,calc(100vw-1.5rem))] max-h-[92vh] rounded-lg border border-line bg-ink-2 p-0 text-paper backdrop:bg-black/60">
      <form onSubmit={submit} className="flex max-h-[92vh] flex-col">
        <div className="flex items-center justify-between border-b border-line px-5 py-3">
          <h2 className="text-lg font-semibold">{channelId ? 'Editar canal' : 'Nuevo canal'}</h2>
          <button type="button" onClick={() => dlg.current?.close()} className="text-sm text-dim hover:text-paper">Cerrar</button>
        </div>
        <div className="scroll-thin space-y-5 overflow-y-auto px-5 py-4">
          {loading ? <p className="text-dim" role="status">Cargando canal…</p> : (<>
            <div className="grid gap-4 sm:grid-cols-2">
              <div><label htmlFor="c-name" className="text-sm">Nombre</label><input id="c-name" required maxLength={120} value={f.name} onChange={(e) => set('name', e.target.value)} className={field} /></div>
              <div><label htmlFor="c-group" className="text-sm">Categoría</label>
                <input id="c-group" list="groups" value={f.group} onChange={(e) => set('group', e.target.value)} placeholder="Elige o escribe una nueva" className={field} />
                <datalist id="groups">{groups.map((g) => <option key={g} value={g} />)}</datalist></div>
            </div>
            <div><label htmlFor="c-logo" className="text-sm">Logo (URL)</label><input id="c-logo" type="url" value={f.logo} onChange={(e) => set('logo', e.target.value)} className={field} placeholder="https://…/logo.png" /><div className="mt-2"><LogoBox url={f.logo} /></div></div>
            <div className="grid gap-4 sm:grid-cols-[1fr_7rem]">
              <div><label htmlFor="c-epg" className="text-sm">ID de la guía (EPG)</label>
                <input id="c-epg" list="epgs" value={f.epg} onChange={(e) => set('epg', e.target.value)} placeholder="Escribe para buscar" className={field} />
                <datalist id="epgs">{epg.map((x) => <option key={x.guide_id} value={x.guide_id}>{x.display_name}</option>)}</datalist></div>
              <div><label htmlFor="c-chno" className="text-sm">N.º de canal</label><input id="c-chno" inputMode="numeric" pattern="[0-9]*" value={f.chno} onChange={(e) => set('chno', e.target.value)} className={field} /></div>
            </div>

            <fieldset className="rounded-md border border-line p-3"><legend className="px-1 text-sm font-semibold">URL principal</legend>
              <input aria-label="URL principal" type="url" required value={f.url1} onChange={(e) => set('url1', e.target.value)} className={field} placeholder="https://…/index.m3u8" />
              <ProbeRow url={f.url1} referer={f.ref1} ua={f.ua1} label="URL principal" onPlay={() => play(f.url1, f.ref1, f.ua1)} />
            </fieldset>
            <fieldset className="rounded-md border border-line p-3"><legend className="px-1 text-sm font-semibold">URL alternativa (respaldo)</legend>
              <input aria-label="URL alternativa" type="url" value={f.url2} onChange={(e) => set('url2', e.target.value)} className={field} placeholder="Opcional" />
              {f.url2 && <ProbeRow url={f.url2} referer={f.ref2} ua={f.ua2} label="URL alternativa" onPlay={() => play(f.url2, f.ref2, f.ua2)} />}
            </fieldset>

            <button type="button" onClick={() => setAdv(!adv)} aria-expanded={adv} className="text-sm font-semibold text-focus">{adv ? 'Ocultar opciones avanzadas' : 'Opciones avanzadas'}</button>
            {adv && (
              <div className="space-y-4">
                <div className="grid gap-4 sm:grid-cols-2">
                  <div><label htmlFor="r1" className="text-sm">Referer de la principal</label><input id="r1" type="url" value={f.ref1} onChange={(e) => set('ref1', e.target.value)} className={field} /></div>
                  <div><label htmlFor="u1" className="text-sm">User-Agent de la principal</label><input id="u1" value={f.ua1} onChange={(e) => set('ua1', e.target.value)} className={field} /></div>
                  <div><label htmlFor="rs1" className="text-sm">Cómo obtener la URL de la principal</label><select id="rs1" value={f.res1} onChange={(e) => set('res1', e.target.value)} className={field}><option value="">Directa (la URL es el video)</option><option value="generic">Buscar el .m3u8 dentro de una página web</option></select></div>
                  {f.url2 && <><div><label htmlFor="rs2" className="text-sm">Cómo obtener la URL de la alternativa</label><select id="rs2" value={f.res2} onChange={(e) => set('res2', e.target.value)} className={field}><option value="">Directa (la URL es el video)</option><option value="generic">Buscar el .m3u8 dentro de una página web</option></select></div><div><label htmlFor="r2" className="text-sm">Referer de la alternativa</label><input id="r2" type="url" value={f.ref2} onChange={(e) => set('ref2', e.target.value)} className={field} /></div>
                  <div><label htmlFor="u2" className="text-sm">User-Agent de la alternativa</label><input id="u2" value={f.ua2} onChange={(e) => set('ua2', e.target.value)} className={field} /></div></>}
                </div>
                <div><label htmlFor="vq" className="text-sm">¿Desde dónde se valida este canal?</label><select id="vq" value={f.vant} onChange={(e) => set('vant', e.target.value)} className={field}><option value="">Desde cualquier motor</option><option value="local-do">Solo desde República Dominicana (tu PC con agente o motor en RD)</option></select>
                  <p className="mt-1 text-xs text-dim">Elige RD si el canal solo se ve dentro del país: así un servidor en EE. UU. no lo marca como caído por error.</p></div>
                <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={f.catchup} onChange={(e) => set('catchup', e.target.checked)} className="size-4 accent-[var(--color-focus)]" /> Este canal permite ver programas pasados (catchup)</label>
                {f.catchup && (
                  <div className="grid gap-4 sm:grid-cols-[9rem_1fr_6rem]">
                    <div><label htmlFor="ct" className="text-sm">Tipo</label><select id="ct" value={f.ctype} onChange={(e) => set('ctype', e.target.value)} className={field}>{['append', 'default', 'shift', 'flussonic', 'xc'].map((t) => <option key={t}>{t}</option>)}</select></div>
                    <div><label htmlFor="cs" className="text-sm">Plantilla</label><input id="cs" value={f.csource} onChange={(e) => set('csource', e.target.value)} placeholder="?utc={utc}&lutc={lutc}" className={field} /></div>
                    <div><label htmlFor="cd" className="text-sm">Días</label><input id="cd" inputMode="numeric" value={f.cdays} onChange={(e) => set('cdays', e.target.value)} className={field} /></div>
                  </div>
                )}
                <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={!f.check} onChange={(e) => set('check', !e.target.checked)} className="size-4 accent-[var(--color-focus)]" /> No validar este canal (solo se ve en un país concreto)</label>
                <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={!f.enabled} onChange={(e) => set('enabled', !e.target.checked)} className="size-4 accent-[var(--color-focus)]" /> Ocultar de mi lista (no se borra)</label>
              </div>
            )}
          </>)}
          {err && <p className="text-sm text-down" role="alert">{err}</p>}
        </div>
        <div className="flex items-center gap-3 border-t border-line px-5 py-3">
          {orig && <button type="button" onClick={remove} className="text-sm text-down hover:underline">Borrar canal</button>}
          <button type="button" onClick={() => dlg.current?.close()} className="ml-auto rounded-md border border-line px-3.5 py-2 text-sm hover:bg-ink-3">Cancelar</button>
          <button type="submit" disabled={saving || loading} className="rounded-md bg-paper px-4 py-2 text-sm font-semibold text-ink hover:bg-white disabled:opacity-60">{saving ? 'Guardando…' : 'Guardar cambios'}</button>
        </div>
      </form>
    </dialog>
  );
}
