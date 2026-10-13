import { legal, privacy, terms } from '../legal';

/** Página pública (sin iniciar sesión): #/terminos y #/privacidad */
export function LegalPage({ which }: { which: 'terminos' | 'privacidad' }) {
  const doc = which === 'terminos' ? terms() : privacy();
  return (
    <main className="mx-auto max-w-2xl px-4 py-10">
      <a href="#/" className="text-sm text-dim hover:text-paper">← Volver</a>
      {!legal.reviewed && <p role="alert" className="mt-4 rounded-md border border-warn/50 bg-warn/10 p-3 text-sm text-warn">Borrador sin revisar por un abogado. No lo publiques para el público hasta que lo revise un profesional de tu país.</p>}
      <h1 className="mt-4 text-3xl font-semibold tracking-tight">{doc.title}</h1>
      {doc.sections.map((s) => (
        <section key={s.h} className="mt-6"><h2 className="text-lg font-semibold">{s.h}</h2>{s.p.map((t) => <p key={t} className="mt-2 text-sm leading-relaxed text-dim">{t}</p>)}</section>
      ))}
    </main>
  );
}
export const LegalLinks = () => (
  <p className="mt-6 text-xs text-dim">Al crear una cuenta aceptas los <a className="underline hover:text-paper" href="#/terminos">Términos de uso</a> y la <a className="underline hover:text-paper" href="#/privacidad">Política de privacidad</a>.</p>
);
