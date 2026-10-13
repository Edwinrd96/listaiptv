"""Sondeo HLS con timeout TOTAL estricto y rotación de 3 User-Agents de Smart TV."""
import re, time
from urllib.parse import urljoin

import requests
import urllib3

from .config import DEFAULT_UA, SMART_TV_UAS, Config

urllib3.disable_warnings()


def is_dead(why: str | None) -> bool:
    return bool(why and re.search(r"HTTP (404|410)\b", why))


def _proxies(proxy: str | None):
    return {"http": proxy, "https": proxy} if proxy else None


def _fetch(url: str, headers: dict, timeout: float, rng: bool = False, proxy: str | None = None):
    t_end = time.monotonic() + timeout
    h = dict(headers)
    if rng:
        h["Range"] = "bytes=0-1023"
    r = requests.get(url, headers=h, timeout=(min(3.05, timeout), timeout), verify=False, stream=True, proxies=_proxies(proxy))
    try:
        buf = bytearray()
        if r.status_code in (200, 206):
            limit = 1024 if rng else 300_000
            while len(buf) < limit:
                if time.monotonic() > t_end:
                    raise requests.exceptions.Timeout("deadline")
                chunk = r.raw.read(8192, decode_content=True)
                if not chunk:
                    break
                buf += chunk
    finally:
        r.close()
    return r.status_code, bytes(buf), r.url


def parse_variants(txt: str):
    lines = [l.strip() for l in txt.splitlines()]
    variants, uris = [], []
    for i, l in enumerate(lines):
        if not l.startswith("#EXT-X-STREAM-INF"):
            continue
        res, bw, cd = re.search(r"RESOLUTION=(\d+)x(\d+)", l), re.search(r"BANDWIDTH=(\d+)", l), re.search(r'CODECS="([^"]+)"', l)
        variants.append({"height": int(res.group(2)) if res else None, "bandwidth": int(bw.group(1)) if bw else None, "codecs": cd.group(1) if cd else None})
        nxt = next((x for x in lines[i + 1:] if x and not x.startswith("#")), None)
        if nxt:
            uris.append(nxt)
    return variants, uris


def probe_once(url: str, headers: dict, timeout: float, proxy: str | None = None) -> dict:
    t0 = time.monotonic()
    left = lambda: max(0.3, timeout - (time.monotonic() - t0))
    out = {"ok": False, "http": None, "error": None, "variants": [], "ms": 0}
    try:
        code, data, final = _fetch(url.split("#")[0], headers, left(), proxy=proxy)
        out["http"] = code
        if code != 200:
            out["error"] = f"HTTP {code}"; return out
        txt = data.decode("utf-8", "ignore")
        if "#EXTM3U" not in txt[:100]:
            out["error"] = "no es m3u8"; return out
        for _ in range(3):
            if time.monotonic() - t0 > timeout:
                out["error"] = "Timeout"; return out
            variants, uris = parse_variants(txt)
            if variants and not out["variants"]:
                out["variants"] = variants
            items = [l.strip() for l in txt.splitlines() if l.strip() and not l.startswith("#")]
            if not items:
                out["error"] = "manifiesto vacío"; return out
            nxt = urljoin(final, uris[0] if uris else items[0])
            if ".m3u8" in nxt.split("?")[0]:
                code, data, final = _fetch(nxt, headers, left(), proxy=proxy)
                if code != 200:
                    out["http"], out["error"] = code, f"sub-manifiesto HTTP {code}"; return out
                txt = data.decode("utf-8", "ignore")
                continue
            code, _, _ = _fetch(nxt, headers, left(), rng=True, proxy=proxy)
            out["http"], out["ok"] = code, code in (200, 206)
            out["error"] = None if out["ok"] else f"segmento HTTP {code}"
            return out
        out["ok"] = True
        return out
    except Exception as e:
        out["error"] = "Timeout" if isinstance(e, requests.exceptions.Timeout) else type(e).__name__
        return out
    finally:
        out["ms"] = int((time.monotonic() - t0) * 1000)


def headers_for(referer: str | None, ua: str | None, default_ua: str | None = None, profile: dict | None = None,
                extra: dict | None = None) -> dict:
    """UA explícito > perfil > UA de la lista. El perfil aporta un conjunto COHERENTE (Accept-Language, sec-ch-ua...)."""
    h = {"User-Agent": ua or (profile or {}).get("user_agent") or default_ua or DEFAULT_UA}
    for k, v in ((profile or {}).get("headers") or {}).items():
        if k.lower() != "user-agent":
            h[k] = v
    if referer:
        h["Referer"] = referer
        m = re.match(r"(https?://[^/]+)", referer)
        if m:
            h["Origin"] = m.group(1)
    for k, v in (extra or {}).items():
        if isinstance(v, str) and "\n" not in v and "\r" not in v:
            h[k] = v
    return h


def probe_source(cfg: Config, url: str, referer: str | None, ua: str | None, default_ua: str | None = None,
                 profile: dict | None = None, extra: dict | None = None, proxy: str | None = None) -> dict:
    """Prueba la URL con el UA normal; si el origen rechaza (no es 404/410) rota por los 3 UA de Smart TV. Con proxy opcional (HTTP/SOCKS5)."""
    t_end = time.monotonic() + cfg.channel_budget
    base = headers_for(referer, ua, default_ua, profile, extra)
    r = probe_once(url, base, cfg.timeout, proxy)
    r["ua_used"] = None
    if not r["ok"] and not is_dead(r["error"]):
        for sua in SMART_TV_UAS:
            if time.monotonic() > t_end:
                break
            h2 = dict(base); h2["User-Agent"] = sua
            r2 = probe_once(url, h2, cfg.timeout, proxy)
            if r2["ok"]:
                r2["ua_used"] = sua
                return r2
    return r


def quality_of(r: dict):
    v = r.get("variants") or []
    if not v:
        return None
    hs = [x["height"] for x in v if x["height"]]
    return {"height": max(hs) if hs else None, "bandwidth": max((x["bandwidth"] or 0) for x in v) or None,
            "codecs": next((x["codecs"] for x in v if x["codecs"]), None), "variants": len(v)}
