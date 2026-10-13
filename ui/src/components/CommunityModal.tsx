import { useCallback, useEffect, useState } from 'react';
import { acceptTos, contributionPreview, friendly, importFromCatalog, myProfile, mySuggestions, searchCatalog, setShareContributions, shareMetaOnly } from '../api';
import type { CatalogHit, ContributionRow, Entitlements, MyProfile, SuggestionRow } from '../api/types';
import { Modal } from './Modal';

const btn = 'rounded border border-line px-2.5 py-1 text-sm hover:bg-ink-3 disabled:opacity-50';
const primary = 'rounded-md bg-paper px-3 py-2 text-sm font-medium text-ink disabled:opacity-60';
type Tab = 'catalog' | 'share' | 'mine';
const STATUS = { pending: ['En revisión', 'text-warn'], accepted: ['Aceptado', 'text-ok'], rejected: ['No aceptado', 'text-down'] } as const;

function Catalog({ playlistId, ent, onImported }: { playlistId: string; ent: Entitlements | null; onImported: () => void }) {
  const [q, setQ] = useState(''); const [hits, setHits] = useState<CatalogHit[] | null>(null); const [sel, setSel] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [msg, setMsg] = useState<string | null>(null);
  const locked = ent ? !ent.features['catalog_follow'] : false;
  useEffect(() => { const t = window.setTimeout(() => { searchCatalog(q).then(setHits).catch((e) => setErr((e as Error).message)); }, 250); return () => window.clearTimeout(t); }, [q]);
  const toggle = (id: string) => setSel((p) => { const n = new Set(p); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  async function add() {
    setBusy(true); setErr(null); setMsg(null);
    try { await importFromCatalog(playlistId, [...sel]); setMsg(`${sel.size} ${sel.size === 1 ? 'canal agregado' : 'canales agregados'} a tu lista, con sus respaldos sanos.`); setSel(new Set()); onImported(); }
    catch (e) { setErr(friendly((e as Error).message)); } finally { setBusy(false); }
  }
  return (
    <div className="space-y-3">
      <p className="text-sm text-dim">El catálogo lo arma la comunidad: cada canal trae sus enlaces públicos y solo con los que funcionan. Elige y se copian a tu lista.</p>
      {locked && <p className="rounded border border-warn/40 bg-warn/10 px-3 py-2 text-sm text-warn">Agregar desde el catálogo es parte de Pro.</p>}
      <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Buscar canal del catálogo" aria-label="Buscar en el catálogo" className="w-full rounded-md border border-line bg-ink px-3 py-2 text-sm placeholder:text-dim" />
      {err && <p role="alert" className="text-sm text-down">{err}</p>}{msg && <p role="status" className="text-sm text-ok">{msg}</p>}
      {!hits ? <p className="text-dim" role="status">Buscando…</p> : hits.length === 0 ? <p className="rounded border border-line px-4 py-6 text-center text-dim">{q ? 'No hay coincidencias.' : 'El catálogo todavía está vacío. Tus aportes lo harán crecer.'}</p> : (
        <ul className="divide-y divide-line rounded border border-line" aria-label="Canales del catálogo">
          {hits.map((h) => (
            <li key={h.id}><label className="flex cursor-pointer items-center gap-3 px-3 py-2 text-sm">
              <input type="checkbox" checked={sel.has(h.id)} onChange={() => toggle(h.id)} disabled={locked} className="size-4 accent-[var(--color-focus)]" />
              <span className="min-w-0 flex-1"><span className="block truncate">{h.name}</span><span className="block truncate text-xs text-dim">{h.category ?? 'Sin categoría'}{h.country ? ` · ${h.country}` : ''}</span></span>
            </label></li>
          ))}
        </ul>
      )}
      <button type="button" className={primary} disabled={busy || sel.size === 0 || locked} onClick={add}>{busy ? 'Agregando…' : `Agregar ${sel.size || ''} a mi lista`.replace('  ', ' ')}</button>
    </div>
  );
}

function Share({ playlistId }: { playlistId: string }) {
  const [p, setP] = useState<MyProfile | null>(null); const [rows, setRows] = useState<ContributionRow[] | null>(null); const [err, setErr] = useState<string | null>(null); const [done, setDone] = useState<Set<string>>(new Set()); const [busy, setBusy] = useState(false);
  const load = useCallback(() => { myProfile().then(setP).catch((e) => setErr((e as Error).message)); contributionPreview(playlistId).then(setRows).catch((e) => setErr((e as Error).message)); }, [playlistId]);
  useEffect(load, [load]);
  async function run(fn: () => Promise<unknown>) { setBusy(true); setErr(null); try { await fn(); load(); } catch (e) { setErr(friendly((e as Error).message)); } finally { setBusy(false); } }
  const personal = rows?.filter((r) => !r.shareable) ?? []; const publicOnes = rows?.filter((r) => r.shareable) ?? [];
  const active = !!p?.tos_accepted_at && p.share_contributions;
  return (
    <div className="space-y-4">
      {err && <p role="alert" className="text-sm text-down">{err}</p>}
      <section className="rounded-lg border border-line p-4">
        <h3 className="font-medium">Compartir con la comunidad</h3>
        <p className="mt-1 text-sm text-dim">Los enlaces públicos de tus canales (sin usuario ni clave, sin DRM) se suman solos al catálogo para que otros los usen. Los enlaces personales o con credenciales <strong className="text-paper">nunca</strong> se comparten. Ganas XP cuando aceptan tu aporte; no hay dinero de por medio.</p>
        {!p ? <p className="mt-2 text-dim" role="status">Cargando…</p> : !p.tos_accepted_at ? (
          <div className="mt-3 flex flex-wrap items-center gap-3"><p className="text-sm text-warn">Para compartir, lee y acepta los <a className="underline" href="#/terminos" target="_blank" rel="noreferrer">términos de uso</a>.</p><button type="button" className={btn} disabled={busy} onClick={() => run(acceptTos)}>Aceptar términos</button></div>
        ) : (
          <label className="mt-3 flex items-center gap-2 text-sm"><input type="checkbox" checked={p.share_contributions} disabled={busy} onChange={(e) => run(() => setShareContributions(e.target.checked))} className="size-4 accent-[var(--color-focus)]" /> Compartir mis enlaces públicos automáticamente</label>
        )}
        {p && <p className={`mt-2 text-sm ${active ? 'text-ok' : 'text-dim'}`} role="status">{active ? 'Compartir está activado.' : 'Compartir está apagado: no sale nada de tu lista.'}</p>}
      </section>
      {rows && (<>
        <p className="text-sm" role="status">{publicOnes.length} {publicOnes.length === 1 ? 'canal es compartible' : 'canales son compartibles'} · {publicOnes.filter((r) => r.shared).length} ya están en el catálogo · {personal.length} {personal.length === 1 ? 'es personal' : 'son personales'}.</p>
        {personal.length > 0 && active && (
          <section><h3 className="mb-1 text-sm font-medium">Canales personales</h3><p className="mb-2 text-sm text-dim">Su enlace no se comparte. Si quieres, puedes aportar solo el nombre y el logo para que otros lo encuentren.</p>
            <ul className="max-h-64 divide-y divide-line overflow-y-auto rounded border border-line">{personal.map((r) => (
              <li key={r.channel_id} className="flex items-center gap-3 px-3 py-2 text-sm"><span className="min-w-0 flex-1 truncate">{r.name}</span>
                {done.has(r.channel_id) ? <span className="text-ok">Aportado</span> : <button type="button" className={btn} disabled={busy} onClick={() => run(async () => { await shareMetaOnly(r.channel_id); setDone((d) => new Set(d).add(r.channel_id)); })}>Aportar solo nombre y logo</button>}
              </li>))}</ul></section>
        )}
      </>)}
    </div>
  );
}

function Mine() {
  const [rows, setRows] = useState<SuggestionRow[] | null>(null); const [err, setErr] = useState<string | null>(null);
  useEffect(() => { mySuggestions().then(setRows).catch((e) => setErr((e as Error).message)); }, []);
  if (err) return <p role="alert" className="text-sm text-down">{err}</p>;
  if (!rows) return <p className="text-dim" role="status">Cargando…</p>;
  if (!rows.length) return <p className="rounded border border-line px-4 py-6 text-center text-dim">Todavía no has aportado nada. Cuando compartas, tus aportes aparecen aquí con su estado.</p>;
  return (
    <ul className="divide-y divide-line rounded border border-line" aria-label="Mis aportes">{rows.map((r) => { const [l, c] = STATUS[r.status]; return (
      <li key={r.id} className="flex items-center gap-3 px-3 py-2 text-sm"><span className="min-w-0 flex-1"><span className="block truncate">{r.name}</span><span className="block truncate text-xs text-dim">{r.url ? 'Con enlace público' : 'Solo nombre y logo'}{r.reject_reason ? ` · ${r.reject_reason}` : ''}</span></span><span className={`shrink-0 ${c}`}>{l}</span></li>); })}</ul>
  );
}

export function CommunityModal({ playlistId, ent, onClose, onImported }: { playlistId: string; ent: Entitlements | null; onClose: () => void; onImported: () => void }) {
  const [tab, setTab] = useState<Tab>('catalog');
  const tabs: [Tab, string][] = [['catalog', 'Catálogo'], ['share', 'Compartir'], ['mine', 'Mis aportes']];
  return (
    <Modal title="Comunidad" onClose={onClose}>
      <div role="tablist" aria-label="Secciones de la comunidad" className="flex gap-2">
        {tabs.map(([k, l]) => <button key={k} role="tab" type="button" aria-selected={tab === k} onClick={() => setTab(k)} className={`rounded-full border px-3 py-1 text-sm ${tab === k ? 'border-paper text-paper' : 'border-line text-dim hover:text-paper'}`}>{l}</button>)}
      </div>
      <div role="tabpanel">{tab === 'catalog' ? <Catalog playlistId={playlistId} ent={ent} onImported={onImported} /> : tab === 'share' ? <Share playlistId={playlistId} /> : <Mine />}</div>
    </Modal>
  );
}
