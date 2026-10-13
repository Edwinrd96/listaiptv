// Simula el prefijo /rest/v1 que Supabase pone delante de PostgREST (solo para pruebas locales).
import http from 'node:http';
const TARGET = { host: '127.0.0.1', port: 3000 };
http.createServer((req, res) => {
  const path = req.url.replace(/^\/rest\/v1/, '') || '/';
  const p = http.request({ ...TARGET, path, method: req.method, headers: req.headers }, (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
  p.on('error', (e) => { res.writeHead(502); res.end(String(e)); });
  req.pipe(p);
}).listen(3100, '127.0.0.1', () => console.log('gateway :3100 -> :3000'));
