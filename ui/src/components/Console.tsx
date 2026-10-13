import { useEffect, useRef, useState } from 'react';
import type { EngineLog } from '../api/types';

const COLOR: Record<EngineLog['level'], string> = { debug: 'text-mute', info: 'text-paper', warn: 'text-warn', error: 'text-down' };

export function Console({ logs }: { logs: EngineLog[] }) {
  const [open, setOpen] = useState(false);
  const [level, setLevel] = useState<'all' | 'warn'>('all');
  const end = useRef<HTMLDivElement>(null);
  const shown = level === 'warn' ? logs.filter((l) => l.level === 'warn' || l.level === 'error') : logs;
  const last = logs[logs.length - 1];
  useEffect(() => { if (open) end.current?.scrollIntoView({ block: 'end' }); }, [open, logs.length]);
  return (
    <section aria-label="Consola del motor" className="border-t border-line bg-ink-2">
      <div className="flex items-center gap-3 px-4 py-2 md:px-8">
        <button type="button" onClick={() => setOpen(!open)} aria-expanded={open} className="text-sm font-semibold">{open ? 'Ocultar consola' : 'Consola'}</button>
        {!open && last && <span className={`min-w-0 flex-1 truncate text-sm ${COLOR[last.level]}`}>{last.message}</span>}
        {open && (
          <>
            <div className="flex gap-1 text-sm" role="group" aria-label="Nivel">
              {(['all', 'warn'] as const).map((l) => (
                <button key={l} type="button" onClick={() => setLevel(l)} aria-pressed={level === l} className={`rounded px-2 py-0.5 ${level === l ? 'bg-ink-3 text-paper' : 'text-dim'}`}>{l === 'all' ? 'Todo' : 'Avisos y errores'}</button>
              ))}
            </div>
            <button type="button" className="ml-auto text-sm text-dim hover:text-paper" onClick={() => navigator.clipboard?.writeText(shown.map((l) => `${l.at} ${l.level} ${l.message}`).join('\n'))}>Copiar</button>
          </>
        )}
      </div>
      {open && (
        <div className="scroll-thin max-h-56 overflow-y-auto px-4 pb-3 font-mono text-[13px] leading-6 md:px-8" role="log" aria-live="polite">
          {shown.length === 0 && <p className="text-dim">Todavía no hay mensajes. Pulsa «Forzar sincronización» para que el motor trabaje.</p>}
          {shown.map((l) => (
            <p key={l.id} className={COLOR[l.level]}><span className="text-mute">{new Date(l.at).toLocaleTimeString('es-DO', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</span> {l.message}</p>
          ))}
          <div ref={end} />
        </div>
      )}
    </section>
  );
}
