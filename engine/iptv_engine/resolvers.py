import re
import requests

from .config import DEFAULT_UA, Config


def dm_id(kind: str | None, resolve_ref: str | None):
    m = re.match(r"dm:(\w+)$", resolve_ref or "")
    return m.group(1) if kind == "dailymotion" and m else None


def resolve_dailymotion(cfg: Config, vid: str):
    """URL con token FRESCO, pedida desde la red del motor (si el motor está en RD, el token sirve en RD)."""
    try:
        r = requests.get(cfg.dm_api.format(id=vid), timeout=cfg.timeout, verify=False, params={"embedder": "https://www.dailymotion.com/"},
                         headers={"User-Agent": DEFAULT_UA, "Referer": "https://www.dailymotion.com/"})
        return r.json()["qualities"]["auto"][0]["url"]
    except Exception:
        return None


_M3U8 = re.compile(r"""(?:https?:)?//[^\s"'<>\\)]+?\.m3u8(?:\?[^\s"'<>\\)]*)?|["'(]((?:\.{0,2}/)?[A-Za-z0-9_\-./]+\.m3u8(?:\?[^\s"'<>\\)]*)?)["')]""", re.I)


def find_m3u8(text: str, base: str):
    """Primer .m3u8 de una página (HTML o JSON, incluso con barras escapadas). Igual que el extractor del Worker."""
    from urllib.parse import urljoin
    t = text.replace("\\u0026", "&").replace("\\/", "/").replace("&amp;", "&")
    for m in _M3U8.finditer(t):
        raw = m.group(1) or m.group(0)
        u = urljoin(base, "https:" + raw if raw.startswith("//") else raw)
        if u.startswith(("http://", "https://")):
            return u
    return None


def resolve_generic(cfg: Config, page: str, referer: str | None, ua: str | None, proxy: str | None = None):
    """Abre la página desde ESTA red y devuelve el .m3u8 fresco que contiene (o None)."""
    try:
        h = {"User-Agent": ua or DEFAULT_UA, "Accept": "text/html,application/json,*/*"}
        if referer: h["Referer"] = referer
        r = requests.get(page, headers=h, timeout=cfg.timeout, verify=False, stream=True,
                         proxies={"http": proxy, "https": proxy} if proxy else None)
        body = r.raw.read(1_000_000, decode_content=True)
        r.close()
        return find_m3u8(body.decode("utf-8", "ignore"), r.url) if r.status_code < 400 else None
    except Exception:
        return None
