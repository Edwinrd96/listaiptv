import { useMemo, useState } from 'react';
import type { ChannelRow, Health } from '../api/types';
import { norm } from '../lib/format';
import { HealthCell } from './HealthDot';

const PAGE = 200;

function Logo({ c }: { c: ChannelRow }) {
  const [bad, setBad] = useState(false);
  if (!c.logo_url || bad) return <span className="grid size-10 place-items-center rounded bg-ink-3 text-xs text-dim" aria-hidden="true">{c.name.slice(0, 2)}</span>;
  return <img src={c.logo_url} alt="" loading="lazy" referrerPolicy="no-referrer" onError={() => setBad(true)} className="size-10 rounded bg-ink-3 object-contain p-0.5" />;
}

export function ChannelTable({ rows, filter, onFilter, onEdit, onNew, onPlay }: { rows: ChannelRow[]; filter: Health | null; onFilter: (h: Health | null) => void; onEdit: (id: string) => void; onNew: () => void; onPlay: (id: string, name: string) => void }) {
  const [q, setQ] = useState('');
  const [group, setGroup] = useState('');
  const [noEpg, setNoEpg] = useState(false);
  const [limit, setLimit] = useState(PAGE);
  const groups = useMemo(() => [...new Set(rows.map((r) => r.group_name))].sort((a, b) => a.localeCompare(b, 'es')), [rows]);
  const shown = useMemo(() => {
    const nq = norm(q.trim());
    return rows.filter((r) => {
      if (filter && (filter === 'unknown' ? !(r.health === 'unknown' || r.health === 'unchecked') : r.health !== filter)) return false;
      if (group && r.group_name !== group) return false;
      if (noEpg && r.epg_id) return false;
      return !nq || norm(`${r.name} ${r.tvg_id} ${r.epg_id ?? ''} ${r.group_name}`).includes(nq);
    });
  }, [rows, q, group, noEpg, filter]);
  const noEpgCount = useMemo(() => rows.filter((r) => !r.epg_id).length, [rows]);

  return (
    <section aria-label="Canales" className="flex min-h-0 flex-1 flex-col">
      <div className="flex flex-wrap items-center gap-2 px-4 pb-3 md:px-8">
        <input type="search" value={q} onChange={(e) => { setQ(e.target.value); setLimit(PAGE); }} placeholder="Buscar canal, categoría o EPG"
          aria-label="Buscar canal" className="min-w-0 flex-1 basis-56 rounded-md border border-line bg-ink-2 px-3 py-2 text-sm placeholder:text-dim" />
        <select value={group} onChange={(e) => { setGroup(e.target.value); setLimit(PAGE); }} aria-label="Categoría" className="rounded-md border border-line bg-ink-2 px-2 py-2 text-sm">
          <option value="">Todas las categorías</option>
          {groups.map((g) => <option key={g} value={g}>{g}</option>)}
        </select>
        <label className="inline-flex cursor-pointer items-center gap-2 text-sm text-dim">
          <input type="checkbox" checked={noEpg} onChange={(e) => setNoEpg(e.target.checked)} className="size-4 accent-[var(--color-focus)]" /> Sin guía ({noEpgCount})
        </label>
        <span className="ml-auto text-sm text-dim" aria-live="polite">{shown.length} de {rows.length}</span>
        <button type="button" onClick={onNew} className="rounded-md border border-line px-3 py-2 text-sm font-semibold hover:bg-ink-2">Nuevo canal</button>
      </div>

      <div className="scroll-thin min-h-0 flex-1 overflow-y-auto px-4 md:px-8">
        <div role="table" aria-label="Lista de canales" className="min-w-0">
          <div role="row" className="sticky top-0 z-10 hidden grid-cols-[2.5rem_minmax(0,1fr)_11rem_8rem_5rem_14rem_6rem] gap-4 border-b border-line bg-ink py-2 text-sm text-dim md:grid">
            <span role="columnheader" aria-label="Logo" /><span role="columnheader">Canal</span><span role="columnheader">Categoría</span>
            <span role="columnheader">Guía (EPG)</span><span role="columnheader">Catchup</span><span role="columnheader">Estado</span><span role="columnheader" aria-label="Acciones" />
          </div>
          {shown.slice(0, limit).map((c) => (
            <div role="row" key={c.id} className={`grid grid-cols-[2.5rem_minmax(0,1fr)] items-center gap-x-4 gap-y-1 border-b border-line/50 py-2.5 md:grid-cols-[2.5rem_minmax(0,1fr)_11rem_8rem_5rem_14rem_6rem] ${c.enabled ? '' : 'opacity-50'}`}>
              <div role="cell"><Logo c={c} /></div>
              <div role="cell" className="min-w-0">
                <p className="truncate font-medium">{c.chno ? <span className="mr-2 text-dim">{c.chno}</span> : null}{c.name}</p>
                <p className="truncate text-sm text-dim md:hidden">{c.group_name}</p>
              </div>
              <div role="cell" className="hidden truncate text-sm text-dim md:block">{c.group_name}</div>
              <div role="cell" className="hidden text-sm md:block">{c.epg_id ? <span className="text-dim">{c.epg_id}</span> : <span className="rounded bg-warn/15 px-1.5 py-0.5 text-warn">Sin guía</span>}</div>
              <div role="cell" className="hidden text-sm text-dim md:block">{c.catchup_enabled ? 'Sí' : 'No'}</div>
              <div role="cell" className="col-span-2 md:col-span-1"><HealthCell c={c} /></div>
              <div role="cell" className="col-span-2 flex gap-2 md:col-span-1 md:justify-end">
                <button type="button" onClick={() => onPlay(c.id, c.name)} className="rounded border border-line px-2.5 py-1 text-sm hover:bg-ink-2" aria-label={`Reproducir ${c.name}`}>Ver</button>
                <button type="button" onClick={() => onEdit(c.id)} className="rounded border border-line px-2.5 py-1 text-sm hover:bg-ink-2" aria-label={`Editar ${c.name}`}>Editar</button>
              </div>
            </div>
          ))}
          {shown.length === 0 && (
            <div className="py-16 text-center">
              <p className="text-lg font-medium">{rows.length === 0 ? 'Tu lista está vacía' : 'Ningún canal coincide'}</p>
              <p className="mt-1 text-sm text-dim">{rows.length === 0 ? 'Importa una lista M3U o añade un canal para empezar.' : 'Prueba con otra búsqueda o quita los filtros.'}</p>
              {(q || group || noEpg || filter) && <button type="button" className="mt-4 rounded-md border border-line px-3 py-1.5 text-sm hover:bg-ink-2" onClick={() => { setQ(''); setGroup(''); setNoEpg(false); onFilter(null); }}>Quitar filtros</button>}
            </div>
          )}
          {shown.length > limit && (
            <div className="py-4 text-center"><button type="button" className="rounded-md border border-line px-4 py-2 text-sm hover:bg-ink-2" onClick={() => setLimit(limit + PAGE)}>Mostrar {Math.min(PAGE, shown.length - limit)} más</button></div>
          )}
        </div>
      </div>
    </section>
  );
}
