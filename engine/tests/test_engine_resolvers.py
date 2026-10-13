"""Resolvedor genérico en el motor: busca el .m3u8 dentro de una página y sondea ESE enlace; due_sources entrega la columna `resolver`."""
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from iptv_engine.resolvers import find_m3u8
from iptv_engine.runner import Engine
from test_engine_integration import cfg, sql, origin  # noqa: F401

HLS = b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nseg1.ts\n"
mode = {"page": "ok"}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/page":
            body = b"<html>nada</html>" if mode["page"] == "empty" else b'<script>{"src":"\\/live\\/index.m3u8?tk=1\\u0026e=2"}</script>'
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        elif self.path.startswith("/live/index.m3u8"):
            self.send_response(200); self.send_header("Content-Length", str(len(HLS))); self.end_headers(); self.wfile.write(HLS)
        elif self.path == "/live/seg1.ts":
            self.send_response(200); self.send_header("Content-Length", "4"); self.end_headers(); self.wfile.write(b"\x47\0\0\0")
        else:
            self.send_response(404); self.end_headers()


@pytest.fixture(scope="module")
def site():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H); srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_port}"
    srv.shutdown()


def test_find_m3u8_json_html_y_relativos():
    assert find_m3u8('{"u":"https:\\/\\/a.test\\/x\\/i.m3u8?t=1\\u0026e=2"}', "https://p.test/") == "https://a.test/x/i.m3u8?t=1&e=2"
    assert find_m3u8('<source src="//cdn.test/a.m3u8">', "https://p.test/") == "https://cdn.test/a.m3u8"
    assert find_m3u8('<video src="/live/b.m3u8"></video>', "https://p.test/page") == "https://p.test/live/b.m3u8"
    assert find_m3u8("nada", "https://p.test/") is None


def src(url, resolver="generic"):
    return {"source_id": "x", "url": url, "referer": None, "user_agent": None, "kind": "direct", "resolve_ref": None, "default_ua": None,
            "header_profile": None, "extra_headers": None, "proxy_url": None, "resolver": resolver}


def test_probe_generic_sondea_el_m3u8_encontrado(origin, site):
    mode["page"] = "ok"
    r = Engine(cfg(origin)).probe_task(src(site + "/page"))
    assert r["ok"] is True and r["url_used"].startswith(site + "/live/index.m3u8")


def test_probe_generic_sin_m3u8_falla_claro(origin, site):
    mode["page"] = "empty"
    r = Engine(cfg(origin)).probe_task(src(site + "/page"))
    assert r["ok"] is False and ".m3u8" in (r["error"] or "")


def test_due_sources_trae_resolver(origin, site):
    U = "99999999-0000-0000-0000-0000000000e9"
    sql(f"insert into auth.users(id,email) values ('{U}','res@x.com');")
    pl = sql(f"select id from public.playlists where owner_id='{U}'")
    sql(f"insert into public.channels(playlist_id,tvg_id,name) values ('{pl}','gen','Gen');"
        f"insert into public.channel_sources(channel_id,priority,url,resolver) select id,0,'{site}/page','generic' from public.channels where tvg_id='gen' and playlist_id='{pl}';")
    rows = Engine(cfg(origin)).sb.rpc("due_sources", {"p_limit": 5000, "p_playlist": pl, "p_force": True, "p_vantage": "local-rd"})
    assert [r["resolver"] for r in rows] == ["generic"]
