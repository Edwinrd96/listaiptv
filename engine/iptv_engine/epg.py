"""Guía EPG: descarga las fuentes XMLTV del usuario, se queda SOLO con los canales de su lista y los próximos días,
la comprime y la deja en el almacén (carpeta local o S3/R2). El Worker la sirve en /p/<token>/epg.xml.gz."""
import gzip, logging, os, re, tempfile, time
from datetime import datetime, timedelta, timezone
from xml.sax.saxutils import escape

import requests
from defusedxml import ElementTree as DET
from xml.etree import ElementTree as ET

from .config import Config
from .supa import Supa

log = logging.getLogger("iptv_engine")
_TS = re.compile(r"^(\d{14})(?:\s*([+-])(\d{2})(\d{2}))?")


def parse_ts(v: str | None) -> datetime | None:
    """Formato XMLTV: 20261011063000 +0000 (la zona es opcional)."""
    m = _TS.match(v or "")
    if not m:
        return None
    t = datetime.strptime(m.group(1), "%Y%m%d%H%M%S")
    off = timedelta(hours=int(m.group(3)), minutes=int(m.group(4))) * (1 if m.group(2) == "+" else -1) if m.group(2) else timedelta(0)
    return (t - off).replace(tzinfo=timezone.utc)


# ---------------------------------------------------------------- almacenes
class FileStorage:
    def __init__(self, cfg: Config):
        self.dir = cfg.epg_dir

    def put(self, key: str, path: str) -> None:
        dest = os.path.join(self.dir, key); os.makedirs(os.path.dirname(dest), exist_ok=True)
        tmp = dest + ".tmp"; open(tmp, "wb").write(open(path, "rb").read()); os.replace(tmp, dest)       # reemplazo atómico: nadie lee un archivo a medias


class S3Storage:
    def __init__(self, cfg: Config):
        import boto3                                        # solo hace falta con EPG_STORAGE=s3
        if not (cfg.s3_bucket and cfg.s3_key_id and cfg.s3_secret):
            raise RuntimeError("EPG_STORAGE=s3 necesita S3_BUCKET, S3_ACCESS_KEY_ID y S3_SECRET_ACCESS_KEY")
        self.bucket = cfg.s3_bucket
        self.c = boto3.client("s3", endpoint_url=cfg.s3_endpoint or None, aws_access_key_id=cfg.s3_key_id, aws_secret_access_key=cfg.s3_secret, region_name=cfg.s3_region)

    def put(self, key: str, path: str) -> None:
        self.c.upload_file(path, self.bucket, key, ExtraArgs={"ContentType": "application/gzip"})


def storage_for(cfg: Config):
    if cfg.epg_storage == "s3":
        return S3Storage(cfg)
    if cfg.epg_storage == "file":
        return FileStorage(cfg)
    raise RuntimeError(f"EPG_STORAGE desconocido: {cfg.epg_storage} (usa file o s3)")


# ---------------------------------------------------------------- descarga
def download(url: str, max_mb: int):
    """Descarga a un archivo temporal con tope de tamaño; devuelve un archivo binario ya descomprimido si venía en gzip."""
    tmp = tempfile.TemporaryFile()
    with requests.get(url, stream=True, timeout=(5, 60), headers={"User-Agent": "Mozilla/5.0 IPTVEnginePro-EPG"}) as r:
        r.raise_for_status()
        total = 0
        for chunk in r.iter_content(65536):
            total += len(chunk)
            if total > max_mb * 1024 * 1024:
                raise ValueError(f"La guía pesa más de {max_mb} MB")
            tmp.write(chunk)
    tmp.seek(0)
    magic = tmp.read(2); tmp.seek(0)
    return gzip.GzipFile(fileobj=tmp) if magic == b"\x1f\x8b" else tmp


# ---------------------------------------------------------------- construcción
def build_epg(sb: Supa, cfg: Config, playlist_id: str, elog=lambda *a, **k: None) -> dict:
    sources = sb.select("epg_sources", {"playlist_id": f"eq.{playlist_id}", "enabled": "eq.true", "order": "sort_order", "select": "id,url"})
    if not sources:
        raise ValueError("No hay fuentes de guía. Agrega la URL de un archivo XMLTV (epg.xml o epg.xml.gz) y vuelve a intentar.")
    chans = sb.select("channels", {"playlist_id": f"eq.{playlist_id}", "enabled": "eq.true", "select": "name,epg_id"})
    wanted = {c["epg_id"]: c["name"] for c in chans if c.get("epg_id")}
    if not wanted:
        raise ValueError("Ningún canal de tu lista tiene ID de guía (EPG). Asígnalos al editar cada canal o al importar.")
    lower = {k.lower(): k for k in wanted}
    now = datetime.now(timezone.utc); lo = now - timedelta(hours=3); hi = now + timedelta(days=cfg.epg_days)

    kept_channels: dict[str, str] = {}                      # id del usuario -> XML del canal
    n_prog = 0; per_source = []
    body = tempfile.TemporaryFile(mode="w+", encoding="utf-8")
    for src in sources:
        st = {"url": src["url"], "channels": 0, "matched": 0, "programmes": 0, "error": None}
        try:
            f = download(src["url"], cfg.epg_max_mb)
            index: list[dict] = []; mapping: dict[str, str] = {}
            for ev, el in DET.iterparse(f, events=("end",)):
                if el.tag == "channel":
                    gid = el.get("id") or ""
                    names = [d.text.strip() for d in el.findall("display-name") if d.text and d.text.strip()]
                    st["channels"] += 1
                    if gid and len(index) < cfg.epg_index_max:
                        index.append({"source_id": src["id"], "playlist_id": playlist_id, "owner_id": None, "guide_id": gid, "display_name": (names[0] if names else gid)[:200]})
                    mine = gid if gid in wanted else lower.get(gid.lower())
                    if mine and mine not in kept_channels:
                        el.set("id", mine); kept_channels[mine] = ET.tostring(el, encoding="unicode"); st["matched"] += 1
                    if mine: mapping[gid] = mine
                    el.clear()
                elif el.tag == "programme":
                    mine = mapping.get(el.get("channel") or "")
                    if mine and mine in kept_channels:
                        a, b = parse_ts(el.get("start")), parse_ts(el.get("stop"))
                        if a and (b or a) >= lo and a <= hi:
                            el.set("channel", mine); body.write(ET.tostring(el, encoding="unicode") + "\n"); st["programmes"] += 1; n_prog += 1
                    el.clear()
            owner = sb.select("playlists", {"id": f"eq.{playlist_id}", "select": "owner_id"})[0]["owner_id"]
            for r in index: r["owner_id"] = owner
            sb.delete("epg_channels", {"source_id": f"eq.{src['id']}"})
            for i in range(0, len(index), 1000):
                sb.insert_many("epg_channels", index[i:i + 1000])
            sb.patch("epg_sources", {"id": f"eq.{src['id']}"}, {"last_fetched_at": now.isoformat(), "last_status": f"ok · {st['channels']} canales", "channel_count": st["channels"]})
        except Exception as e:                              # una fuente caída no tumba las demás
            st["error"] = f"{type(e).__name__}: {str(e)[:160]}"
            sb.patch("epg_sources", {"id": f"eq.{src['id']}"}, {"last_fetched_at": now.isoformat(), "last_status": st["error"]})
            elog("warn", f"Guía: no se pudo leer {src['url'][:80]} ({st['error']})")
        per_source.append(st)
    if not kept_channels:
        raise ValueError("Ninguna fuente de guía trae los canales de tu lista (los IDs de guía no coinciden). Revisa el ID de guía de tus canales.")

    out = tempfile.NamedTemporaryFile(suffix=".xml.gz", delete=False)
    out.close()
    try:
        with gzip.open(out.name, "wt", encoding="utf-8") as z:
            z.write('<?xml version="1.0" encoding="UTF-8"?>\n<tv generator-info-name="IPTV Engine Pro">\n')
            for x in kept_channels.values(): z.write(x + "\n")
            body.seek(0)
            for line in body: z.write(line)
            z.write("</tv>\n")
        key = f"epg/{playlist_id}.xml.gz"
        size = os.path.getsize(out.name)
        storage_for(cfg).put(key, out.name)
    finally:
        os.unlink(out.name); body.close()
    missing = sorted(n for k, n in wanted.items() if k not in kept_channels)
    meta = {"channels": len(kept_channels), "wanted": len(wanted), "programmes": n_prog, "sources": per_source, "days": cfg.epg_days, "missing_sample": missing[:20]}
    sb.rpc("register_artifact", {"p_playlist": playlist_id, "p_kind": "epg_gz", "p_key": key, "p_bytes": size, "p_meta": meta})
    elog("info", f"Guía lista: {len(kept_channels)} de {len(wanted)} canales con programación ({n_prog} programas, {size // 1024} KB)")
    return meta
