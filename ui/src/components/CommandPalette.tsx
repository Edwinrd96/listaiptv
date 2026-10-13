import { useEffect, useMemo, useRef, useState } from 'react';
import type { ChannelRow } from '../api/types';

export interface Cmd { id: string; label: string; hint?: string; run: () => void }
const norm = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

/** Paleta de comandos (Ctrl/⌘+K): acciones del panel y búsqueda de canales para editar o ver. */
export function CommandPalette({ commands, channels, onEdit, onPlay, onClose }: { commands: Cmd[]; channels: ChannelRow[]; onEdit: (id: string) => void; onPlay: (id: string, name: string) => void; onClose: () => void }) {
  const dlg = useRef<HTMLDialogElement>(null); const [q, setQ] = useState(''); const [i, setI] = useState(0);
  useEffect(() => { dlg.current?.showModal(); }, []);
  const items = useMemo<Cmd[]>(() => {
    const n = norm(q.trim());
    const cs = commands.filter((c) => !n || norm(c.label).includes(n));
    if (!n) return cs;
    const chs = channels.filter((c) => norm(c.name).includes(n) || norm(c.group_name ?? '').includes(n)).slice(0, 8)
      .flatMap((c) => [{ id: `e-${c.id}`, label: `Editar ${c.name}`, hint: c.group_name, run: () => onEdit(c.id) }, { id: `p-${c.id}`, label: `Ver ${c.name}`, hint: c.health === 'down' ? 'caído' : undefined, run: () => onPlay(c.id, c.name) }]);
    return [...cs, ...chs];
  }, [q, commands, channels, onEdit, onPlay]);
  useEffect(() => setI(0), [q]);
  const go = (c?: Cmd) => { if (!c) return; dlg.current?.close(); window.setTimeout(c.run, 0); };
  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); setI((x) => Math.min(x + 1, items.length - 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setI((x) => Math.max(x - 1, 0)); }
    else if (e.key === 'Enter') { e.preventDefault(); go(items[i]); }
  };
  return (
    <dialog ref={dlg} onClose={onClose} onClick={(e) => { if (e.target === dlg.current) dlg.current?.close(); }} aria-label="Paleta de comandos"
      className="mx-auto mt-[12vh] w-[min(34rem,calc(100vw-1.5rem))] rounded-lg border border-line bg-ink-2 p-0 text-paper backdrop:bg-black/60">
      <input autoFocus value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={onKey} role="combobox" aria-expanded="true" aria-controls="cmd-list" aria-activedescendant={items[i] ? `cmd-${items[i].id}` : undefined}
        placeholder="Escribe una acción o el nombre de un canal…" className="w-full border-b border-line bg-transparent px-4 py-3 outline-none placeholder:text-dim" />
      <ul id="cmd-list" role="listbox" className="scroll-thin max-h-[50vh] overflow-y-auto p-1">
        {items.length === 0 && <li className="px-3 py-4 text-sm text-dim">Nada coincide.</li>}
        {items.map((c, k) => (
          <li key={c.id} id={`cmd-${c.id}`} role="option" aria-selected={k === i} onMouseEnter={() => setI(k)} onClick={() => go(c)}
            className={`flex cursor-pointer items-center justify-between gap-3 rounded px-3 py-2 text-sm ${k === i ? 'bg-ink-3' : ''}`}>
            <span className="truncate">{c.label}</span>{c.hint && <span className="shrink-0 text-xs text-dim">{c.hint}</span>}</li>))}
      </ul>
      <p className="border-t border-line px-4 py-2 text-xs text-dim">↑ ↓ para moverte · Enter para elegir · Esc para cerrar</p>
    </dialog>
  );
}
