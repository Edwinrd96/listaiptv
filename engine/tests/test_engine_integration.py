"""Motor REAL <-> PostgREST REAL <-> Postgres REAL (con tus migraciones). Requiere: sh scripts/dev_stack.sh"""
import base64, hashlib, hmac, json, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from iptv_engine.config import Config
from iptv_engine.runner import Engine

SECRET = b"test-secret-test-secret-test-secret-123456"
A, B = "aaaaaaaa-0000-0000-0000-000000000001", "bbbbbbbb-0000-0000-0000-000000000002"
HLS = b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nseg1.ts\n"


def jwt_hs256(claims: dict) -> str:
    b = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=").decode()
    head, body = b(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()), b(json.dumps(claims).encode())
    return f"{head}.{body}.{b(hmac.new(SECRET, f'{head}.{body}'.encode(), hashlib.sha256).digest())}"


def sql(q: str) -> str:
    open("/tmp/qe.sql", "w").write(q)
    r = subprocess.run('su postgres -c "psql -At -q -v ON_ERROR_STOP=1 -d iptvtest -f /tmp/qe.sql"', shell=True, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


hits: dict[str, int] = {}
tg_msgs: list[str] = []


class Origin(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, body=b"", ctype="application/octet-stream"):
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):                                    # Telegram falso
        n = int(self.headers.get("Content-Length", 0)); tg_msgs.append(self.rfile.read(n).decode())
        self.send(200, b'{"ok":true}', "application/json")

    def do_GET(self):
        p = self.path.split("?")[0]; ua = self.headers.get("User-Agent", ""); hits[p] = hits.get(p, 0) + 1
        port = self.server.server_port
        if p == "/meta/xdm01":
            return self.send(200, json.dumps({"qualities": {"auto": [{"url": f"http://127.0.0.1:{port}/ok/playlist.m3u8?dm=1"}]}}).encode(), "application/json")
        if p == "/ext/lista.m3u":
            return self.send(200, (f'#EXTM3U\n#EXTINF:-1 tvg-id="t11" group-title="RD",Telesistema 11 (HD)\n#EXTVLCOPT:http-referrer=https://tel.example/\n'
                                   f'http://127.0.0.1:{port}/rep/playlist.m3u8\n#EXTINF:-1,Otro Canal\nhttp://127.0.0.1:{port}/ok/playlist.m3u8?o=1\n').encode())
        if p.startswith("/slow/"):
            time.sleep(12); return self.send(200, HLS)
        if p.startswith("/prof/") and not ("Tizen" in ua and self.headers.get("Accept-Language", "").startswith("es-DO") and self.headers.get("X-Custom") == "abc"): return self.send(403)
        if p.startswith("/prof/") and p.endswith("playlist.m3u8"): return self.send(200, HLS, "application/vnd.apple.mpegurl")
        if p.startswith("/tv/") and "BRAVIA" not in ua: return self.send(403)
        if p.startswith("/rep/") and self.headers.get("Referer") != "https://tel.example/": return self.send(403)
        if p.endswith("playlist.m3u8") and p.split("/")[1] in ("ok", "tv", "chunk", "dup", "rep", "fresh"): return self.send(200, HLS, "application/vnd.apple.mpegurl")
        if p.endswith(".ts"): return self.send(200, bytes(500))
        return self.send(404)


@pytest.fixture(scope="module")
def origin():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Origin); srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_port}"
    srv.shutdown()


def cfg(origin, vantage="local-rd", **kw) -> Config:
    base = dict(supabase_url="http://127.0.0.1:3100", service_key=jwt_hs256({"role": "service_role"}), engine_id=f"test-{vantage}", vantage=vantage,
                workers=8, timeout=2, channel_budget=6, telegram_token="T", telegram_chat_id="1", tg_api=origin, dm_api=origin + "/meta/{id}", iptv_org_fallback=True)
    base.update(kw); return Config(**base)


def add_channel(pl, tvg, name, url, kind="direct", ref=None, referer=None):
    ref_sql = f"'{ref}'" if ref else "null"; referer_sql = f"'{referer}'" if referer else "null"
    cid = sql(f"insert into public.channels(playlist_id,tvg_id,name) values ('{pl}','{tvg}','{name}') returning id;").split("\n")[0]
    sid = sql(f"insert into public.channel_sources(channel_id,priority,url,kind,resolve_ref,referer) values ('{cid}',0,'{url}','{kind}',{ref_sql},{referer_sql}) returning id;").split("\n")[0]
    return cid, sid


def queue_job(pl, kind="full"):
    return sql(f"insert into public.sync_jobs(playlist_id,owner_id,kind) select id,owner_id,'{kind}' from public.playlists where id='{pl}' returning id;").split("\n")[0]


def health(sid, col):
    return sql(f"select {col} from public.source_health where source_id='{sid}'")


@pytest.fixture(scope="module")
def world(origin):
    sql(f"insert into auth.users(id,email) values ('{A}','a@x.com'),('{B}','b@x.com');")
    plA = sql(f"select id from public.playlists where owner_id='{A}'"); plB = sql(f"select id from public.playlists where owner_id='{B}'")
    sql(f"update public.playlists set settings = '{{\"iptv_org_fallback\": false}}' where id in ('{plA}','{plB}');")
    sql(f"insert into public.external_lists(playlist_id,url) values ('{plA}','{origin}/ext/lista.m3u');")
    w = {"plA": plA, "plB": plB}
    w["ok1"] = add_channel(plA, "ok1", "Canal OK", f"{origin}/ok/playlist.m3u8")
    w["dupA"] = add_channel(plA, "dupA", "Dup A", f"{origin}/dup/playlist.m3u8")
    w["dupB"] = add_channel(plA, "dupB", "Dup B", f"{origin}/dup/playlist.m3u8")
    w["tv"] = add_channel(plA, "tv", "Canal Smart TV", f"{origin}/tv/playlist.m3u8")
    w["chunk"] = add_channel(plA, "chunk", "Con Chunklist", f"{origin}/chunk/chunklist_w123.m3u8")
    w["dm"] = add_channel(plA, "dm", "Dailymotion", "https://live.dmcdn.net/sec2(VIEJO)/dm/3/xdm01/d/live-720.m3u8", "dailymotion", "dm:xdm01")
    w["dead"] = add_channel(plA, "dead", "Telesistema Canal 11", f"{origin}/nada/x.m3u8")
    w["conn"] = add_channel(plA, "conn", "Sin Conexion", "http://127.0.0.1:1/x.m3u8")
    w["slow"] = add_channel(plA, "slow", "Canal Lento", f"{origin}/slow/playlist.m3u8")
    w["jobA"] = queue_job(plA)
    return w


def test_trabajo_completo_con_todas_las_reglas(origin, world):
    t0 = time.time()
    out = Engine(cfg(origin)).run_once()
    el = time.time() - t0
    assert out["jobs"] == 1
    w = world
    assert sql(f"select status from public.sync_jobs where id='{w['jobA']}'") == "succeeded"
    assert sql(f"select engine_id from public.sync_jobs where id='{w['jobA']}'") == "test-local-rd"
    assert health(w["ok1"][1], "state") == "ok"
    # rotación de 3 User-Agents de Smart TV: el origen rechazaba el normal con 403
    assert health(w["tv"][1], "state") == "ok" and "BRAVIA" in health(w["tv"][1], "resolved_ua")
    # chunklist caduca -> el motor usa el maestro de la misma ruta
    assert health(w["chunk"][1], "resolved_url").endswith("/chunk/playlist.m3u8")
    # Dailymotion: token fresco pedido desde la red del motor
    assert health(w["dm"][1], "resolved_url").endswith("/ok/playlist.m3u8?dm=1")
    # fuentes idénticas se sondean UNA vez (1 petición al manifiesto, no 2)
    assert hits["/dup/playlist.m3u8"] == 1 and health(w["dupA"][1], "state") == "ok" and health(w["dupB"][1], "state") == "ok"
    # sin conexión desde el motor 'local-rd' = fallo firme (strike 1/3)
    assert (health(w["conn"][1], "state"), health(w["conn"][1], "strikes")) == ("suspect", "1")
    # timeout estricto: el canal de 12 s no bloquea el trabajo (todo terminó mucho antes de 12 s)
    assert health(w["slow"][1], "strikes") == "1" and el < 11, el
    # auto-reparación desde la lista externa (con el Referer que exige esa lista) + la URL vieja queda de respaldo
    url, ref = sql(f"select url||'|'||coalesce(referer,'') from public.channel_sources where id='{w['dead'][1]}'").split("|")
    assert url.endswith("/rep/playlist.m3u8") and ref == "https://tel.example/"
    assert health(w["dead"][1], "state") == "ok" and health(w["dead"][1], "strikes") == "0"
    assert sql(f"select url from public.channel_sources where channel_id='{w['dead'][0]}' and priority=1").endswith("/nada/x.m3u8")
    logs = sql(f"select message from public.engine_logs where playlist_id='{w['plA']}'")
    assert "Strike 1/3 aplicado a Sin Conexion" in logs and "🔧 Telesistema Canal 11: URL reparada" in logs and "Auditando" in logs
    assert "Sincronización terminada" in logs
    summary = json.loads(sql(f"select summary from public.sync_jobs where id='{w['jobA']}'"))
    assert summary["repaired"] == 1 and summary["rotated"] >= 1 and summary["counts"]["ok"] >= 6
    assert any("Reparados" in m and "Telesistema" in m for m in tg_msgs)
    assert sql("select count(*) from public.engine_heartbeats where engine_id='test-local-rd' and vantage='local-rd'") == "1"
    # el Worker publicaría la URL reparada
    tok = sql(f"select token from public.outputs where playlist_id='{w['plA']}'")
    payload = json.loads(sql(f"select public.get_playlist_payload('{tok}')"))
    ch = next(c for c in payload["channels"] if c["tvg_id"] == "dead")
    assert ch["source"]["url"].endswith("/rep/playlist.m3u8") and ch["source"]["referer"] == "https://tel.example/"
    print(f"\nTrabajo completo en {el:.1f} s")


def test_motor_en_otra_region_solo_cuenta_el_404(origin, world):
    pl = world["plA"]
    conn2 = add_channel(pl, "conn2", "Solo visible en RD", "http://127.0.0.1:1/y.m3u8")
    dead2 = add_channel(pl, "dead2", "Muerto Sin Reemplazo", f"{origin}/nada/y.m3u8")
    queue_job(pl)
    Engine(cfg(origin, vantage="github", engine_id="test-gh")).run_once()
    assert (health(conn2[1], "state"), health(conn2[1], "strikes")) == ("unverified", "0")       # fallo BLANDO: no prueba nada
    assert (health(dead2[1], "state"), health(dead2[1], "strikes")) == ("suspect", "1")          # el 404 sí es firme
    assert sql(f"select vantage from public.source_health where source_id='{conn2[1]}'") == "github"


def test_revision_programada_sin_boton(origin, world):
    pl = world["plA"]
    fresh = add_channel(pl, "fresh1", "Canal Nuevo", f"{origin}/fresh/playlist.m3u8")
    out = Engine(cfg(origin, engine_id="test-sched")).run_once(scheduled=True)
    assert out["jobs"] == 0 and out["scheduled_sources"] >= 1
    assert health(fresh[1], "state") == "ok"
    # lo recién medido NO vuelve a tocarse (intervalo de 3 h)
    n = sql(f"select count(*) from public.due_sources(1000, '{pl}', false) where source_id='{fresh[1]}'")
    assert n == "0"


def test_dos_motores_a_la_vez_no_duplican_trabajos(origin, world):
    a, b = world["plA"], world["plB"]
    add_channel(b, "b1", "Canal B", f"{origin}/ok/playlist.m3u8")
    sql(f"update public.sync_jobs set status='succeeded', finished_at=now() where status in ('queued','running');")
    ja, jb = queue_job(a), queue_job(b)
    res = []
    ts = [threading.Thread(target=lambda n=n: res.append(Engine(cfg(origin, engine_id=f"par-{n}")).run_once()["jobs"])) for n in range(2)]
    [t.start() for t in ts]; [t.join() for t in ts]
    assert sum(res) == 2                                           # cada trabajo lo procesa UN solo motor
    rows = sql(f"select status||':'||engine_id from public.sync_jobs where id in ('{ja}','{jb}') order by id").split("\n")
    assert all(r.startswith("succeeded:par-") for r in rows)


def test_tipo_epg_sin_fuentes_falla_limpio(origin, world):
    sql(f"update public.sync_jobs set status='succeeded', finished_at=now() where status in ('queued','running');")
    j = queue_job(world["plA"], "epg")
    Engine(cfg(origin, engine_id="par-epg")).run_once()
    assert sql(f"select status from public.sync_jobs where id='{j}'") == "failed"
    assert "fuentes de guía" in sql(f"select error from public.sync_jobs where id='{j}'")
