// Service worker mínimo: guarda SOLO el cascarón estático del panel (mismo origen) para abrir rápido y sin conexión.
// Nunca toca Supabase, el Worker ni nada de otro origen: datos, sesión y video siempre van a la red.
const CACHE = 'iptv-shell-v1';
self.addEventListener('install', (e) => { e.waitUntil(caches.open(CACHE).then((c) => c.addAll(['/', '/icon.svg', '/manifest.webmanifest'])).then(() => self.skipWaiting())); });
self.addEventListener('activate', (e) => { e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', (e) => {
  const r = e.request; const u = new URL(r.url);
  if (r.method !== 'GET' || u.origin !== self.location.origin) return;
  if (r.mode === 'navigate') { e.respondWith(fetch(r).then((res) => { const cp = res.clone(); caches.open(CACHE).then((c) => c.put('/', cp)); return res; }).catch(() => caches.match('/'))); return; }
  if (u.pathname.startsWith('/assets/')) {   // archivos con hash: cache primero
    e.respondWith(caches.match(r).then((hit) => hit || fetch(r).then((res) => { if (res.ok) { const cp = res.clone(); caches.open(CACHE).then((c) => c.put(r, cp)); } return res; })));
  }
});
