import { useEffect, useRef, useState } from 'react';
import { playSession, probeUrl } from '../api';
import type { ProbeReport } from '../api/types';
import { env } from '../lib/supabase';

export interface PlayTarget { title: string; url: string; referer?: string | null; ua?: string | null }
type Mode = 'direct' | 'proxy' | 'report';

interface Stats { level: string; kbps: number; buffer: number; dropped: number }

/** Reproductor flotante. Modo 1: directo. Modo 2: proxy de sesión (≤90 s) cuando el origen no admite CORS / exige Referer. Modo 3: informe del servidor. */
export function Player({ target, onClose }: { target: PlayTarget; onClose: () => void }) {
  const video = useRef<HTMLVideoElement>(null);
  const [mode, setMode] = useState<Mode>('direct');
  const [msg, setMsg] = useState('Conectando…');
  const [stats, setStats] = useState<Stats | null>(null);
  const [report, setReport] = useState<ProbeReport | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    setStats(null); setReport(null);
    if (mode === 'report') return;
    const v = video.current; if (!v) return;
    let hls: import('hls.js').default | null = null; let stop = false; let timer: number | undefined; let cap: number | undefined;
    const fallback = (why: string) => {
      if (stop) return;
      if (mode === 'direct' && env.worker && !target.url.startsWith('blob:')) { setMsg(`${why} Probando a través del servidor…`); setMode('proxy'); } else setMsg(`${why} Mira el informe del servidor para saber el motivo.`);
    };
    (async () => {
      let src = target.url;
      if (mode === 'proxy') {
        try { const s = await playSession({ url: target.url, referer: target.referer ?? undefined, user_agent: target.ua ?? undefined }); src = s.play_url; cap = window.setTimeout(() => { v.pause(); setMsg('La prueba por servidor se detiene a los 90 s para cuidar la cuota. Pulsa «Reintentar».'); }, 90_000); }
        catch (e) { setMsg((e as Error).message); return; }
      } else if (location.protocol === 'https:' && src.startsWith('http://')) { fallback('La página es https y el canal http (el navegador lo bloquea).'); return; }
      const { default: Hls } = await import('hls.js');
      if (stop) return;
      if (Hls.isSupported()) {
        hls = new Hls({ lowLatencyMode: false, maxBufferLength: 20 });
        hls.on(Hls.Events.MANIFEST_PARSED, () => { setMsg(mode === 'proxy' ? 'Reproduciendo vía servidor' : 'Reproduciendo directo'); void v.play().catch(() => setMsg('Pulsa ▶ para reproducir.')); });
        hls.on(Hls.Events.ERROR, (_e, d) => { if (d.fatal) fallback(d.details === 'manifestLoadError' || d.details === 'manifestParsingError' ? 'El origen no se puede abrir desde el navegador.' : 'El flujo se cortó.'); });
        hls.loadSource(src); hls.attachMedia(v);
        timer = window.setInterval(() => {
          const l = hls?.levels?.[hls.currentLevel];
          setStats({ level: l ? `${l.height || '?'}p` : '—', kbps: Math.round((hls?.bandwidthEstimate ?? 0) / 1000), buffer: Math.round((v.buffered.length ? v.buffered.end(v.buffered.length - 1) - v.currentTime : 0) * 10) / 10, dropped: v.getVideoPlaybackQuality?.().droppedVideoFrames ?? 0 });
        }, 1000);
      } else if (v.canPlayType('application/vnd.apple.mpegurl')) { v.src = src; void v.play(); } else setMsg('Este navegador no reproduce HLS.');
    })();
    return () => { stop = true; window.clearInterval(timer); window.clearTimeout(cap); hls?.destroy(); };
  }, [mode, target.url, target.referer, target.ua]);

  async function runReport() {
    setBusy(true); setMode('report');
    try { setReport(await probeUrl(target.url, target.referer ?? undefined, target.ua ?? undefined)); setMsg('Informe del servidor'); } catch (e) { setMsg((e as Error).message); } finally { setBusy(false); }
  }

  return (
    <aside aria-label={`Reproductor: ${target.title}`} className="fixed inset-x-0 bottom-0 z-40 border border-line bg-ink-2 shadow-2xl md:inset-x-auto md:bottom-4 md:right-4 md:w-[26rem] md:rounded-lg">
      <div className="flex items-center gap-2 px-3 py-2">
        <p className="min-w-0 flex-1 truncate font-medium">{target.title}</p>
        <button type="button" onClick={onClose} className="rounded px-2 py-1 text-sm text-dim hover:text-paper" aria-label="Cerrar reproductor">Cerrar</button>
      </div>
      {mode !== 'report' && <video ref={video} controls playsInline muted className="aspect-video w-full bg-black" />}
      <div className="space-y-2 px-3 py-2 text-sm">
        <p className="text-dim" role="status">{msg}</p>
        {stats && mode !== 'report' && <p className="text-dim">Nivel {stats.level} · {stats.kbps} kbps · búfer {stats.buffer} s · {stats.dropped} cuadros perdidos</p>}
        {report && (
          <div className="rounded border border-line p-2">
            <p className={report.ok ? 'text-ok' : 'text-down'}>{report.ok ? 'El servidor sí puede leer este canal' : `Falla: ${report.error ?? 'sin respuesta'}`}</p>
            <p className="text-dim">HTTP {report.http ?? '—'} · {report.latency_ms} ms{report.variants.length ? ` · hasta ${Math.max(...report.variants.map((x) => x.height ?? 0))}p` : ''}{report.segment_ok ? ' · el primer segmento descarga' : ''}</p>
            {report.hint && <p className="mt-1 text-warn">{report.hint}</p>}
          </div>
        )}
        <div className="flex gap-2 pt-1">
          <button type="button" onClick={() => setMode('direct')} className="rounded border border-line px-2.5 py-1 hover:bg-ink-3">{mode === 'report' ? 'Ver video' : 'Reintentar'}</button>
          <button type="button" onClick={runReport} disabled={busy} className="rounded border border-line px-2.5 py-1 hover:bg-ink-3 disabled:opacity-60">{busy ? 'Analizando…' : 'Informe del servidor'}</button>
        </div>
      </div>
    </aside>
  );
}
