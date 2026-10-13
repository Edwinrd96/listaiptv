"""Guía EPG de punta a punta: fuentes XMLTV reales (plano y gz) -> motor -> Postgres/PostgREST reales -> archivo en carpeta local y en S3 (moto)."""
import gzip, io, threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from iptv_engine.epg import build_epg, parse_ts
from iptv_engine.runner import Engine
from test_engine_integration import cfg, sql

E = "eeeeeeee-0000-0000-0000-0000000000e5"
NOW = datetime.now(timezone.utc)
fmt = lambda d: d.strftime("%Y%m%d%H%M%S +0000")


def prog(ch, start, mins, title):
    return f'<programme start="{fmt(start)}" stop="{fmt(start + timedelta(minutes=mins))}" channel="{ch}"><title lang="es">{title}</title><desc>x</desc></programme>'


XML1 = ('<?xml version="1.0"?><tv><channel id="cnn.us"><display-name>CNN</display-name></channel><channel id="otro.x"><display-name>Otro canal</display-name></channel>'
        + prog("cnn.us", NOW, 60, "Ahora") + prog("cnn.us", NOW + timedelta(days=1), 60, "Mañana") + prog("cnn.us", NOW + timedelta(days=10), 60, "Muy lejos")
        + prog("cnn.us", NOW - timedelta(days=1), 60, "Ayer") + prog("otro.x", NOW, 30, "No lo quiero") + "</tv>").encode()
XML2 = ('<?xml version="1.0"?><tv><channel id="ESPN.us"><display-name>ESPN</display-name></channel>' + prog("ESPN.us", NOW, 90, "Partido") + "</tv>").encode()


class Guide(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body, code = {"/g1.xml": (XML1, 200), "/g2.xml.gz": (gzip.compress(XML2), 200)}.get(self.path, (b"no", 404))
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)


@pytest.fixture(scope="module")
def guide():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Guide); srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_port}"
    srv.shutdown()


@pytest.fixture(scope="module")
def pl(guide):
    sql(f"insert into auth.users(id,email) values ('{E}','e5@x.com');")
    p = sql(f"select id from public.playlists where owner_id='{E}'")
    sql(f"insert into public.channels(playlist_id,tvg_id,name,epg_id) values ('{p}','cnn','CNN en Español','CNN.us'),('{p}','espn','ESPN','ESPN.us'),('{p}','miss','Canal sin guía','Missing.xx'),('{p}','noepg','Sin ID',null);")
    return p


def xml_of(path) -> str:
    return gzip.open(path, "rt", encoding="utf-8").read()


def test_parse_ts_con_y_sin_zona():
    assert parse_ts("20261011063000 +0000") == datetime(2026, 10, 11, 6, 30, tzinfo=timezone.utc)
    assert parse_ts("20261011063000 -0400") == datetime(2026, 10, 11, 10, 30, tzinfo=timezone.utc)
    assert parse_ts("20261011063000") == datetime(2026, 10, 11, 6, 30, tzinfo=timezone.utc) and parse_ts("basura") is None


def test_error_claro_si_no_hay_fuentes_ni_ids(guide, pl, tmp_path):
    c = cfg(guide, epg_dir=str(tmp_path))
    with pytest.raises(ValueError, match="No hay fuentes de guía"):
        build_epg(Engine(c).sb, c, pl)


def test_construye_filtra_indexa_y_registra(guide, pl, tmp_path):
    for i, u in enumerate(["/g1.xml", "/g2.xml.gz", "/caida.xml"]):
        sql(f"insert into public.epg_sources(playlist_id,owner_id,url,sort_order) values ('{pl}','{E}','{guide}{u}',{i});")
    c = cfg(guide, epg_dir=str(tmp_path)); logs = []
    meta = build_epg(Engine(c).sb, c, pl, lambda lv, m: logs.append((lv, m)))
    xml = xml_of(tmp_path / "epg" / f"{pl}.xml.gz")
    assert meta["channels"] == 2 and meta["wanted"] == 3 and meta["programmes"] == 3                   # Ahora + Mañana (CNN) y Partido (ESPN)
    assert 'channel id="CNN.us"' in xml and 'channel="CNN.us"' in xml and "cnn.us" not in xml          # el id se reescribe al del usuario
    assert "Ayer" not in xml and "Muy lejos" not in xml and "No lo quiero" not in xml and "otro.x" not in xml
    assert "Partido" in xml and "Mañana" in xml
    assert meta["missing_sample"] == ["Canal sin guía"]
    assert sql(f"select count(*) from public.epg_channels where playlist_id='{pl}'") == "3"            # cnn.us, otro.x, ESPN.us (autocompletar)
    assert sql(f"select last_status from public.epg_sources where url like '%/g1.xml'").startswith("ok · 2 canales")
    assert "404" in sql(f"select last_status from public.epg_sources where url like '%/caida.xml'")    # la fuente caída no tumbó el resto
    assert any(lv == "warn" and "caida.xml" in m for lv, m in logs)
    art = sql(f"select storage_key||'|'||bytes||'|'||(meta->>'channels') from public.playlist_artifacts where playlist_id='{pl}' and kind='epg_gz'")
    assert art.startswith(f"epg/{pl}.xml.gz|") and art.endswith("|2")
    build_epg(Engine(c).sb, c, pl)                                                                      # repetirlo no duplica el índice
    assert sql(f"select count(*) from public.epg_channels where playlist_id='{pl}'") == "3"


def test_el_boton_epg_corre_como_trabajo(guide, pl, tmp_path):
    sql(f"insert into public.sync_jobs(playlist_id,owner_id,kind) values ('{pl}','{E}','epg');")
    out = Engine(cfg(guide, epg_dir=str(tmp_path), epg_every_hours=0, engine_id="epg-job")).run_once()
    assert out["jobs"] >= 1
    assert sql(f"select status from public.sync_jobs where playlist_id='{pl}' and kind='epg' order by requested_at desc limit 1") == "succeeded"
    assert (tmp_path / "epg" / f"{pl}.xml.gz").exists()


def test_programada_solo_si_el_archivo_es_viejo(guide, pl, tmp_path):
    e = Engine(cfg(guide, epg_dir=str(tmp_path), engine_id="epg-sched"))
    assert e.run_epg_due() == 0                                                                         # recién hecha: no se repite
    sql(f"update public.playlist_artifacts set built_at = now() - interval '13 hours' where playlist_id='{pl}'")
    assert e.run_epg_due() == 1


def test_s3_compatible_r2_minio(guide, pl):
    from moto.server import ThreadedMotoServer
    import boto3
    srv = ThreadedMotoServer(port=0, verbose=False); srv.start(); host, port = srv.get_host_and_port(); ep = f"http://{host}:{port}"
    try:
        boto3.client("s3", endpoint_url=ep, aws_access_key_id="k", aws_secret_access_key="s", region_name="us-east-1").create_bucket(Bucket="epg")
        c = cfg(guide, epg_storage="s3", s3_endpoint=ep, s3_bucket="epg", s3_key_id="k", s3_secret="s", s3_region="us-east-1")
        build_epg(Engine(c).sb, c, pl)
        obj = boto3.client("s3", endpoint_url=ep, aws_access_key_id="k", aws_secret_access_key="s", region_name="us-east-1").get_object(Bucket="epg", Key=f"epg/{pl}.xml.gz")
        assert "Partido" in gzip.decompress(obj["Body"].read()).decode() and obj["ContentType"] == "application/gzip"
        with pytest.raises(RuntimeError, match="S3_BUCKET"):
            build_epg(Engine(c).sb, cfg(guide, epg_storage="s3"), pl)
    finally:
        srv.stop()
