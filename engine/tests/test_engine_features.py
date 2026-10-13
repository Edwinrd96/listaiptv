"""Funciones nuevas del motor contra Postgres/PostgREST reales: perfiles de cabeceras, proxy, vantage_required, pruebas masivas y modo agente (BYON)."""
import json, subprocess, threading, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from iptv_engine.agent import Agent
from iptv_engine.runner import Engine
from test_engine_integration import cfg, jwt_hs256, origin, hits  # noqa: F401  (fixture 'origin' reutilizada)

C, D = "cccccccc-0000-0000-0000-0000000000c3", "dddddddd-0000-0000-0000-0000000000d4"


def sql(q: str) -> str:
    open("/tmp/qe_feat.sql", "w").write(q)
    r = subprocess.run('su postgres -c "psql -At -q -v ON_ERROR_STOP=1 -d iptvtest -f /tmp/qe_feat.sql"', shell=True, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


proxy_log: list[str] = []


class Proxy(BaseHTTPRequestHandler):
    """Proxy HTTP de juguete: reenvía a 127.0.0.1:<puerto> lo pedido para el host falso 'rd-only.test'."""
    target = ""
    def log_message(self, *a): pass
    def do_GET(self):
        proxy_log.append(self.path)
        real = self.path.replace("http://rd-only.test", Proxy.target)
        req = urllib.request.Request(real, headers={k: v for k, v in self.headers.items() if k.lower() not in ("host", "proxy-connection")})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                body = r.read(); self.send_response(r.status); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        except Exception:
            self.send_response(502); self.end_headers()


@pytest.fixture(scope="module")
def proxy(origin):
    Proxy.target = origin
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Proxy); srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv.server_port
    srv.shutdown()


def add_src(pl, tvg, name, url, extra_cols="", extra_vals="", ch_cols="", ch_vals=""):
    cid = sql(f"insert into public.channels(playlist_id,tvg_id,name{ch_cols}) values ('{pl}','{tvg}','{name}'{ch_vals}) returning id;").split("\n")[0]
    sid = sql(f"insert into public.channel_sources(channel_id,priority,url{extra_cols}) values ('{cid}',0,'{url}'{extra_vals}) returning id;").split("\n")[0]
    return cid, sid


def st(sid, col="state"):
    return sql(f"select {col} from public.source_health where source_id='{sid}'")


@pytest.fixture(scope="module")
def world(origin, proxy):
    sql(f"insert into auth.users(id,email) values ('{C}','c@x.com'),('{D}','d@x.com');"
        f"insert into public.manual_grants(user_id,reason,expires_at) values ('{C}','t', now()+interval '1 day');")
    plC = sql(f"select id from public.playlists where owner_id='{C}'"); plD = sql(f"select id from public.playlists where owner_id='{D}'")
    w = {"plC": plC, "plD": plD}
    # 1) perfil Tizen + extra_headers: el origen devuelve 403 si falta algo del conjunto
    w["prof"] = add_src(plC, "prof", "Perfil Tizen", f"{origin}/prof/playlist.m3u8", ",header_profile,extra_headers",
                        ",'smarttv_tizen','{\"X-Custom\":\"abc\"}'")
    w["noprof"] = add_src(plC, "noprof", "Sin perfil", f"{origin}/prof/playlist.m3u8")
    # 2) canal dominicano: host inalcanzable salvo vía el proxy asignado por país
    w["rd"] = add_src(plC, "rd", "Solo por proxy", "http://rd-only.test/ok/playlist.m3u8", "", "", ",country", ",'DO'")
    pid = sql(f"insert into public.proxies(owner_id,name,scheme,host,port,country) values ('{C}','Casa','http','127.0.0.1',{proxy},'DO') returning id;").split("\n")[0]
    sql(f"set session_replication_role = replica; insert into public.proxy_assignments(owner_id,proxy_id,scope,country) values ('{C}','{pid}','country','DO');")
    # 3) vantage_required
    w["vr"] = add_src(plC, "vr", "Solo local-do", f"{origin}/ok/playlist.m3u8", ",vantage_required", ",'local-do'")
    # 4) fuente de otro usuario: el agente de C jamás debe tocarla
    w["other"] = add_src(plD, "other", "Canal de D", f"{origin}/ok/playlist.m3u8")
    return w


def test_perfil_de_cabeceras_extra_y_proxy_por_pais(origin, world):
    Engine(cfg(origin, vantage="github", engine_id="feat-gh")).run_once(scheduled=True)
    assert st(world["prof"][1]) == "ok"                              # conjunto coherente aceptado por el origen
    assert st(world["noprof"][1], "strikes") == "0" and st(world["noprof"][1]) != "ok"   # sin perfil: 403 -> fallo blando desde github
    assert st(world["rd"][1]) == "ok" and any("rd-only.test" in p for p in proxy_log)    # llegó por el proxy del país
    assert st(world["vr"][1]) == ""                                  # vantage_required='local-do': el motor github NO la toca


def test_pruebas_masivas_de_importacion(origin, world):
    sql(f"insert into public.import_batches(id,owner_id,playlist_id,total) values ('99999999-0000-0000-0000-000000000009','{C}','{world['plC']}',3);"
        f"insert into public.import_items(batch_id,owner_id,idx,raw) values "
        f"('99999999-0000-0000-0000-000000000009','{C}',1,'{{\"url\":\"{origin}/ok/playlist.m3u8\"}}'),"
        f"('99999999-0000-0000-0000-000000000009','{C}',2,'{{\"url\":\"{origin}/nada/x.m3u8\"}}'),"
        f"('99999999-0000-0000-0000-000000000009','{C}',3,'{{\"url\":\"{origin}/prof/playlist.m3u8\",\"header_profile\":\"smarttv_tizen\",\"extra_headers\":{{\"X-Custom\":\"abc\"}}}}');")
    out = Engine(cfg(origin, vantage="github", engine_id="feat-gh2")).run_once()
    assert out["import_tests"] == 3
    rows = sql("select idx||':'||test_state||':'||coalesce(test_http::text,'') from public.import_items where batch_id='99999999-0000-0000-0000-000000000009' order by idx").split("\n")
    assert rows == ["1:ok:200", "2:fail:404", "3:ok:200"]
    assert sql("select status from public.import_batches where id='99999999-0000-0000-0000-000000000009'") == "ready"


def test_agente_byon_valida_solo_lo_suyo_y_con_su_vantage(origin, world):
    sql(f"insert into public.agents(owner_id,name,country,vantage,token_hash) values ('{C}','PC casa','DO','local-do', encode(extensions.digest('ag_test_token','sha256'),'hex'));")
    sql(f"insert into public.import_batches(id,owner_id,playlist_id,total) values ('88888888-0000-0000-0000-000000000008','{C}','{world['plC']}',1);"
        f"insert into public.import_items(batch_id,owner_id,idx,raw) values ('88888888-0000-0000-0000-000000000008','{C}',1,'{{\"url\":\"{origin}/ok/playlist.m3u8\"}}');")
    c = cfg(origin, vantage="local-do", engine_id="agent-c", agent_token="ag_test_token", anon_key=jwt_hs256({"role": "anon"}), service_key="")
    out = Agent(c).run_once()
    assert out["import_tests"] == 1 and out["sources"] >= 1
    assert st(world["vr"][1]) == "ok" and st(world["vr"][1], "vantage") == "local-do"     # la fuente que exige local-do SÍ la valida el agente
    assert st(world["other"][1], "vantage") != "local-do"                                  # el agente de C no tocó nada de D (lo midió el motor github antes)
    assert sql("select count(*) from public.engine_heartbeats where engine_id like 'agent:%' and vantage='local-do'") == "1"
    with pytest.raises(Exception):                                                          # token falso rechazado
        Agent(cfg(origin, vantage="local-do", agent_token="ag_malo", anon_key=jwt_hs256({"role": "anon"}), service_key="")).run_once()


def test_proxies_propios_se_prueban_y_el_error_no_filtra_la_clave(origin, world, proxy):
    """BYOP: el motor prueba los proxies sin comprobar; si falla, el mensaje guardado NO contiene la clave."""
    good = sql(f"select id from public.proxies where owner_id='{C}' and name='Casa'")
    bad = sql(f"insert into public.proxies(owner_id,name,scheme,host,port,username) values ('{C}','Roto','http','127.0.0.1',1,'usuario') returning id;").split("\n")[0]
    sql(f"set session_replication_role = replica; insert into public.proxy_secrets(proxy_id,owner_id,password) values ('{bad}','{C}','SECRETO-123') on conflict do nothing;")
    sql(f"update public.proxies set last_test_at = null, last_ok = null where id in ('{good}','{bad}')")      # lo que hace el botón «Probar» del panel
    c = cfg(origin, vantage="github", engine_id="proxy-test", proxy_test_url="http://rd-only.test/ok/playlist.m3u8")
    out = Engine(c).run_once()
    assert out["proxy_tests"] >= 2
    assert sql(f"select last_ok from public.proxies where id='{good}'") == "t"
    assert sql(f"select last_ok from public.proxies where id='{bad}'") == "f"
    err = sql(f"select last_error from public.proxies where id='{bad}'")
    assert err and "SECRETO-123" not in err and "usuario" not in err
    assert Engine(c).run_proxy_tests() == 0                                                                      # ya probados: no se repiten antes de 6 h
