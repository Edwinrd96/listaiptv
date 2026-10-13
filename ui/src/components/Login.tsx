import { useState } from 'react';
import { configured, supabase } from '../lib/supabase';
import { LegalLinks } from './LegalPage';

export function Login() {
  const [email, setEmail] = useState(''); const [pass, setPass] = useState('');
  const [mode, setMode] = useState<'in' | 'up'>('in'); const [msg, setMsg] = useState<string | null>(null); const [busy, setBusy] = useState(false);
  async function submit(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); setMsg(null);
    const r = mode === 'in' ? await supabase.auth.signInWithPassword({ email, password: pass }) : await supabase.auth.signUp({ email, password: pass });
    setBusy(false);
    if (r.error) setMsg(r.error.message === 'Invalid login credentials' ? 'Correo o contraseña incorrectos.' : r.error.message);
    else if (mode === 'up' && !r.data.session) setMsg('Te enviamos un correo para confirmar la cuenta.');
  }
  return (
    <main className="grid min-h-full place-items-center px-4">
      <form onSubmit={submit} className="w-full max-w-sm">
        <div className="mb-8 flex h-2 w-24 gap-0.5 overflow-hidden rounded-sm" aria-hidden="true">
          {['ok', 'warn', 'down', 'mute'].map((c) => <span key={c} className="strip-seg h-full flex-1" style={{ background: `var(--color-${c})` }} />)}
        </div>
        <h1 className="text-3xl font-semibold tracking-tight">{mode === 'in' ? 'Entra a tu panel' : 'Crea tu cuenta'}</h1>
        <p className="mt-2 text-sm text-dim">Gestiona tus listas IPTV y mira qué canales funcionan.</p>
        {!configured && <p className="mt-4 rounded-md border border-warn/50 bg-warn/10 p-3 text-sm text-warn" role="alert">Falta configurar VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY en el archivo .env del panel.</p>}
        <label className="mt-6 block text-sm" htmlFor="email">Correo</label>
        <input id="email" type="email" required autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} className="mt-1 w-full rounded-md border border-line bg-ink-2 px-3 py-2.5" />
        <label className="mt-4 block text-sm" htmlFor="pass">Contraseña</label>
        <input id="pass" type="password" required minLength={8} autoComplete={mode === 'in' ? 'current-password' : 'new-password'} value={pass} onChange={(e) => setPass(e.target.value)} className="mt-1 w-full rounded-md border border-line bg-ink-2 px-3 py-2.5" />
        {msg && <p className="mt-3 text-sm text-down" role="alert">{msg}</p>}
        <button type="submit" disabled={busy || !configured} className="mt-6 w-full rounded-md bg-paper py-2.5 font-semibold text-ink hover:bg-white disabled:opacity-60">{mode === 'in' ? 'Entrar' : 'Crear cuenta'}</button>
        <button type="button" className="mt-4 text-sm text-dim hover:text-paper" onClick={() => { setMode(mode === 'in' ? 'up' : 'in'); setMsg(null); }}>
          {mode === 'in' ? '¿No tienes cuenta? Crea una' : '¿Ya tienes cuenta? Entra'}
        </button>
        <LegalLinks />
      </form>
    </main>
  );
}
