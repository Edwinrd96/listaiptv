import { useEffect, useRef } from 'react';

/** Ventana nativa <dialog>: foco atrapado, Esc cierra, clic fuera cierra. */
export function Modal({ title, onClose, wide, full, children, footer }: { title: string; onClose: () => void; wide?: boolean; full?: boolean; children: React.ReactNode; footer?: React.ReactNode }) {
  const dlg = useRef<HTMLDialogElement>(null);
  useEffect(() => { dlg.current?.showModal(); }, []);
  return (
    <dialog ref={dlg} onClose={onClose} onClick={(e) => { if (e.target === dlg.current) dlg.current?.close(); }}
      className={`m-auto max-h-[92vh] rounded-lg border border-line bg-ink-2 p-0 text-paper backdrop:bg-black/60 ${full ? 'h-[calc(100vh-1.5rem)] w-[calc(100vw-1.5rem)] max-w-none' : wide ? 'w-[min(60rem,calc(100vw-1.5rem))]' : 'w-[min(42rem,calc(100vw-1.5rem))]'}`}>
      <div className={`flex flex-col ${full ? 'h-full' : 'max-h-[92vh]'}`}>
        <div className="flex items-center justify-between border-b border-line px-5 py-3">
          <h2 className="text-lg font-semibold">{title}</h2>
          <button type="button" onClick={() => dlg.current?.close()} className="text-sm text-dim hover:text-paper">Cerrar</button>
        </div>
        <div className={`scroll-thin overflow-y-auto px-5 py-4 ${full ? 'flex min-h-0 flex-1 flex-col gap-3' : 'space-y-5'}`}>{children}</div>
        {footer && <div className="flex flex-wrap items-center justify-end gap-2 border-t border-line px-5 py-3">{footer}</div>}
      </div>
    </dialog>
  );
}
