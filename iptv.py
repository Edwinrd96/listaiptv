#!/usr/bin/env python3
"""
iptv.py - Gestor de lista IPTV (channels.yaml -> M3U + EPG)

  python iptv.py check               # prueba cada canal (con headers), autorepara URL, marca caídos
  python iptv.py audit               # lista URLs con token/sesión y si se auto-renuevan
  python iptv.py build               # genera dist/iptv.m3u, dist/iptv_vlc.m3u, dist/caidos.m3u
  python iptv.py epg                 # genera dist/epg.xml.gz solo con TUS canales (3 días)
  python iptv.py add URL --name "X" --group "🇩🇴 Dominicana" [--referer R] [--logo L] [--epg ID]
  python iptv.py import FUENTE --filter "regex" --group "Candidatos"   # FUENTE = URL o archivo .m3u
"""
import argparse, copy, gzip, io, json, os, re, sys, unicodedata
import datetime as dt
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import quote, unquote, urljoin, urlparse

import requests, yaml
import urllib3
urllib3.disable_warnings()

ROOT = Path(__file__).parent
YAML = ROOT / "channels.yaml"
STATE = ROOT / "state.json"
DIST = ROOT / "dist"
ALT_UAS = [
    "VLC/3.0.20 LibVLC/3.0.20",
    "Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36",
    "okhttp/4.12.0",
]

# ---------------------------------------------------------------- utilidades
def load():
    d = yaml.safe_load(YAML.read_text(encoding="utf-8"))
    return d["settings"], d["channels"]

def load_state():
    return json.loads(STATE.read_text()) if STATE.exists() else {}

def save_state(st):
    STATE.write_text(json.dumps(st, indent=1, ensure_ascii=False))

def origin(u):
    p = urlparse(u)
    return f"{p.scheme}://{p.netloc}"

def headers_for(ch, s):
    h = {"User-Agent": ch.get("ua") or s["ua"]}
    if ch.get("referer"):
        h["Referer"] = ch["referer"]
        h["Origin"] = origin(ch["referer"])
    return h

def candidates(ch):
    """URL original + alternas + variantes 'maestras' (las chunklist_* caducan)."""
    urls = [ch["url"]] + list(ch.get("alt", []))
    base, _, last = ch["url"].split("#")[0].split("?")[0].rpartition("/")
    if base and last.startswith("chunklist"):
        derived = [f"{base}/{n}" for n in ("playlist.m3u8", "index.m3u8", "master.m3u8")]
        urls = derived + urls
    return list(dict.fromkeys(urls))

# ---------------------------------------------------------------- detección de URLs volátiles
VOLATILE = [
    (r"chunklist_w?\d+", "chunklist de sesión (caduca)"),
    (r"/sec\d?\(", "token incrustado en la ruta (Dailymotion/CDN)"),
    (r"[?&;](token|tokenid|auth|sig|signature|hdnts|hdntl|hdnea|expires|exp|e|st|md5|policy|key-pair-id|wmssign|wmsauthsign|startdate)=", "parámetro de token en la URL"),
    (r"~hmac=|~exp=", "firma HMAC con expiración"),
]

def volatility(url):
    """Lista de motivos por los que una URL probablemente caduque ([] = estable)."""
    r = [msg for pat, msg in VOLATILE if re.search(pat, url, re.I)]
    m = re.search(r"[?&;](?:expires|exp|e)=(\d{10})\b", url, re.I)
    if m:
        r.append("expira " + dt.datetime.fromtimestamp(int(m.group(1)), dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"))
    return r

# ---------------------------------------------------------------- Dailymotion (sin yt-dlp)
DM_API = "https://www.dailymotion.com/player/metadata/video/{id}"

def dm_id(ch):
    """ID del video de Dailymotion: de 'resolve: dm:ID', de la página o de la propia URL con token."""
    for src in (ch.get("resolve", ""), ch.get("url", "")):
        m = (re.match(r"dm:(\w+)$", src) or re.search(r"dailymotion\.com/video/(x\w+)", src)
             or re.search(r"dmcdn\.net/.*?/(x[0-9a-z]{4,8})/", src))
        if m:
            return m.group(1)
    return None

def resolve_dm(vid, ua, timeout=10):
    """Pide a Dailymotion el m3u8 con token FRESCO (mismo método del reproductor oficial)."""
    try:
        r = requests.get(DM_API.format(id=vid), timeout=timeout, verify=False,
                         params={"embedder": "https://www.dailymotion.com/"},
                         headers={"User-Agent": ua, "Referer": "https://www.dailymotion.com/"})
        j = r.json()
        return j["qualities"]["auto"][0]["url"]
    except Exception:
        return None

# ---------------------------------------------------------------- resolver (yt-dlp)
def resolve(page):
    """Saca el m3u8 vigente de una página (YouTube Live, Dailymotion, etc.) con yt-dlp."""
    import subprocess, shutil
    exe = shutil.which("yt-dlp") or None
    cmd = [exe, "-g", "-f", "best", "--no-warnings", page] if exe else [sys.executable, "-m", "yt_dlp", "-g", "-f", "best", "--no-warnings", page]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        lines = [l for l in r.stdout.splitlines() if l.startswith("http")]
        return lines[0] if lines else None
    except Exception:
        return None

# ---------------------------------------------------------------- sondeo
def _fetch(url, h, timeout, rng=False):
    hh = dict(h)
    if rng:
        hh["Range"] = "bytes=0-1023"
    r = requests.get(url, headers=hh, timeout=timeout, verify=False, stream=True)
    try:
        data = r.raw.read(1024 if rng else 300_000, decode_content=True)
    finally:
        r.close()
    return r.status_code, data, r.url

def probe(url, h, timeout=8):
    """True si el manifiesto responde, es HLS válido y el primer segmento descarga."""
    try:
        code, data, final = _fetch(url.split("#")[0], h, timeout)
        if code != 200:
            return False, f"HTTP {code}"
        txt = data.decode("utf-8", "ignore")
        if "#EXTM3U" not in txt[:100]:
            return False, "no es m3u8"
        for _ in range(3):
            items = [l.strip() for l in txt.splitlines() if l.strip() and not l.startswith("#")]
            if not items:
                return False, "manifiesto vacío"
            nxt = urljoin(final, items[0])
            if ".m3u8" in nxt.split("?")[0]:
                code, data, final = _fetch(nxt, h, timeout)
                if code != 200:
                    return False, f"sub-manifiesto HTTP {code}"
                txt = data.decode("utf-8", "ignore")
                continue
            code, _, _ = _fetch(nxt, h, timeout, rng=True)
            return (code in (200, 206)), f"segmento HTTP {code}"
        return True, "ok"
    except Exception as e:
        return False, type(e).__name__

def notify(msg):
    tok, chat = os.getenv("TELEGRAM_TOKEN"), os.getenv("TELEGRAM_CHAT_ID")
    if tok and chat:
        try:
            requests.post(f"https://api.telegram.org/bot{tok}/sendMessage",
                          data={"chat_id": chat, "text": msg}, timeout=10)
        except Exception:
            pass

# ---------------------------------------------------------------- check
def dead_after(s):
    return s.get("dead_after", 12)          # 12 revisiones seguidas con 404 (~24 h) antes de retirar un canal

def is_dead(why):
    return bool(re.search(r"HTTP (404|410)\b", why or ""))

def cmd_check(args):
    s, chs = load()
    st = load_state()
    now = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None).isoformat(timespec="seconds")

    def work(ch):
        if ch.get("check") is False:                # canal que no se valida (geobloqueado, etc.)
            return ch, None, None, "omitido"
        h = headers_for(ch, s)
        why = "sin candidatos"
        cands = candidates(ch)
        vid = dm_id(ch)
        if vid:                                     # 1) Dailymotion: token fresco por API
            fresh = resolve_dm(vid, s["ua"], s.get("timeout", 8))
            if fresh:
                cands = [fresh] + cands
            else:
                why = "Dailymotion no devolvió stream (¿offline?)"
        elif ch.get("resolve"):                     # 2) YouTube/otros: yt-dlp
            fresh = resolve(ch["resolve"])
            if fresh:
                cands = [fresh] + cands
            else:
                why = "yt-dlp no resolvió la página"
        for attempt in (1, 2):                      # un reintento por fallos transitorios
            for u in cands:
                ok, why = probe(u, h, s.get("timeout", 8))
                if ok:
                    return ch, u, True, why
        return ch, None, False, why

    with ThreadPoolExecutor(s.get("workers", 16)) as ex:
        results = list(ex.map(work, chs))

    limit = dead_after(s)
    newly_down, alive, unreach, skipped = [], 0, 0, 0
    for ch, url, ok, why in results:
        e = st.setdefault(ch["id"], {"fails": 0})
        if ok is None:                              # omitido (check: false)
            skipped += 1
            e.update(status="skipped", fails=0)
            continue
        was_down = e["fails"] >= limit
        if ok:
            alive += 1
            if url != ch["url"]:
                print(f"  ↻ {ch['name']}: URL reparada -> {url}")
            e.update(fails=0, unreach=0, status="ok", url=url, last_ok=now, why="ok", volatile=volatility(url))
        elif is_dead(why):                          # 404/410: el servidor responde y dice que no existe
            e["fails"] += 1
            e.update(status="dead", why=why)
            print(f"  ✗ {ch['name']}: {why} (fallo {e['fails']}/{limit})")
            if e["fails"] == limit and not was_down:
                newly_down.append(ch["name"])
        else:                                       # sin conexión / 403 / timeout: lo normal en streams solo-RD vistos desde EE.UU.
            unreach += 1
            e.update(fails=0, unreach=e.get("unreach", 0) + 1, status="unreachable", why=why)
            print(f"  🌎 {ch['name']}: {why} (no verificable desde GitHub; se mantiene en la lista)")
    save_state(st)
    print(f"\n{alive} activos · {unreach} no verificables desde GitHub (se conservan) · "
          f"{len(chs) - alive - unreach - skipped} fallando (404) · {skipped} omitidos · total {len(chs)}")
    if newly_down:
        notify("📺 Canales caídos (404 sostenido): " + ", ".join(newly_down))

# ---------------------------------------------------------------- build
def esc(v):
    return (v or "").replace('"', "'")

def stream_url(ch, url, s, vlc):
    if vlc:
        return url
    h = headers_for(ch, s)
    enc = (lambda v: quote(v, safe=":/.-_~")) if s.get("encode_headers", True) else (lambda v: v)
    return url + "|" + "&".join(f"{k}={enc(v)}" for k, v in h.items())

def render(chs, s, st, vlc):
    epg = s.get("epg_public_url") or ",".join(s.get("epg_sources", [])[:1])
    out = [f'#EXTM3U x-tvg-url="{epg}"' if epg else "#EXTM3U", ""]
    for ch in chs:
        url = st.get(ch["id"], {}).get("url") or ch["url"]
        if s.get("worker_url") and dm_id(ch):      # enlace estable: el Worker resuelve el token al reproducir
            url = f'{s["worker_url"].rstrip("/")}/dm/{dm_id(ch)}'
        out.append(f'#EXTINF:-1 tvg-id="{esc(ch["id"])}" tvg-name="{esc(ch["name"])}" '
                   f'tvg-logo="{esc(ch.get("logo"))}" group-title="{esc(ch["group"])}",{ch["name"]}')
        if vlc:
            for k, v in headers_for(ch, s).items():
                key = {"User-Agent": "http-user-agent", "Referer": "http-referrer"}.get(k)
                if key:
                    out.append(f"#EXTVLCOPT:{key}={v}")
            out.append("#EXTVLCOPT:http-reconnect=true")
        out.append(stream_url(ch, url, s, vlc))
        out.append("")
    return "\n".join(out)

def icon(c, e, is_down):
    if c.get("check") is False or e.get("status") == "skipped":
        return "⚪ sin verificar"
    if is_down:
        return "🔴 caído (404 sostenido)"
    if e.get("status") == "unreachable":
        return "🌎 no verificable desde GitHub"
    if e.get("status") == "dead":
        return f"🟠 404 ({e.get('fails', 0)}/{12})"
    return "🟢 activo" if e.get("last_ok") else "⚪ sin probar"

def cmd_build(args):
    s, chs = load()
    st = load_state()
    ids, urls = set(), set()
    for ch in chs:
        for k in ("id", "name", "group", "url"):
            if not ch.get(k):
                sys.exit(f"Canal sin campo '{k}': {ch}")
        if ch["id"] in ids:
            print(f"⚠ id duplicado: {ch['id']}")
        if ch["url"] in urls:
            print(f"⚠ URL duplicada: {ch['name']}")
        ids.add(ch["id"]); urls.add(ch["url"])
    order = s.get("group_order", [])
    key = lambda c: order.index(c["group"]) if c["group"] in order else len(order)
    chs = sorted(chs, key=key)
    down = lambda c: st.get(c["id"], {}).get("fails", 0) >= dead_after(s)
    live, dead = [c for c in chs if not down(c)], [c for c in chs if down(c)]
    DIST.mkdir(exist_ok=True)
    (DIST / "iptv.m3u").write_text(render(live, s, st, vlc=False), encoding="utf-8")
    (DIST / "iptv_vlc.m3u").write_text(render(live, s, st, vlc=True), encoding="utf-8")
    (DIST / "caidos.m3u").write_text(render(dead, s, st, vlc=False), encoding="utf-8")
    rows = ["# Estado de la lista", f"Actualizado: {dt.datetime.now(dt.timezone.utc):%Y-%m-%d %H:%M} UTC",
            f"\n{len(live)} activos · {len(dead)} caídos\n", "| Canal | Grupo | Estado | Tipo de enlace | Último OK |", "|---|---|---|---|---|"]
    for c in chs:
        e = st.get(c["id"], {})
        vol = volatility(e.get("url") or c["url"])
        kind = ("🔁 auto-renovado" if (dm_id(c) or c.get("resolve")) else "⏳ volátil: " + "; ".join(vol)) if vol or dm_id(c) or c.get("resolve") else "✅ estable"
        rows.append(f"| {c['name']} | {c['group']} | {icon(c, e, down(c))} | {kind} | {e.get('last_ok','-')} |")
    (DIST / "ESTADO.md").write_text("\n".join(rows), encoding="utf-8")
    print(f"✔ {len(live)} activos, {len(dead)} caídos -> {DIST}/")

# ---------------------------------------------------------------- EPG
def norm(x):
    x = unicodedata.normalize("NFKD", x or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", x)

def open_source(src):
    if re.match(r"https?://", src):
        r = requests.get(src, timeout=120, verify=False)
        r.raise_for_status()
        raw = r.content
    else:
        raw = Path(src).read_bytes()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return io.BytesIO(raw)

def cmd_epg(args):
    s, chs = load()
    guide_to_ours = {c["epg"]: c["id"] for c in chs if c.get("epg")}
    by_name = {}
    for c in chs:
        by_name[norm(re.sub(r"canal\s*\d+", "", c["name"], flags=re.I))] = c["id"]
        by_name[norm(c["name"])] = c["id"]
    now = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    lo = (now - dt.timedelta(hours=6)).strftime("%Y%m%d%H%M%S")
    hi = (now + dt.timedelta(days=s.get("epg_days", 3))).strftime("%Y%m%d%H%M%S")
    out = ET.Element("tv", {"generator-info-name": "iptv.py"})
    matched, gmap = set(), {}
    for src in args.sources or s["epg_sources"]:
        try:
            f = open_source(src)
        except Exception as e:
            print(f"✗ {src}: {e}")
            continue
        n_prog = 0
        for _, el in ET.iterparse(f, events=("end",)):
            if el.tag == "channel":
                gid = el.get("id")
                names = [d.text for d in el.findall("display-name")]
                ours = guide_to_ours.get(gid) or next((by_name[norm(n)] for n in names if n and norm(n) in by_name), None)
                if ours and ours not in matched:
                    el.set("id", ours)
                    out.append(el); matched.add(ours); gmap[gid] = ours
                    continue
            elif el.tag == "programme":
                ours = gmap.get(el.get("channel"))
                if ours and (el.get("stop", "")[:14] >= lo) and (el.get("start", "")[:14] <= hi):
                    el.set("channel", ours)
                    out.append(el); n_prog += 1
                    continue
            if el.tag in ("channel", "programme"):
                el.clear()
        print(f"✔ {src}: {n_prog} programas")
    DIST.mkdir(exist_ok=True)
    buf = io.BytesIO()
    ET.ElementTree(out).write(buf, encoding="utf-8", xml_declaration=True)
    with gzip.open(DIST / "epg.xml.gz", "wb") as g:
        g.write(buf.getvalue())
    missing = [c["name"] for c in chs if c["id"] not in matched]
    (DIST / "epg_sin_guia.txt").write_text("\n".join(missing), encoding="utf-8")
    print(f"EPG: {len(matched)}/{len(chs)} canales con guía. Sin guía -> dist/epg_sin_guia.txt "
          f"(asígnales 'epg: <id de la guía>' en channels.yaml)")

# ---------------------------------------------------------------- add / import
def slug(name):
    return re.sub(r"[^a-z0-9]+", "", norm(name)) or "canal"

def parse_m3u(text):
    out, cur = [], {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#EXTINF"):
            a = dict(re.findall(r'([\w-]+)="([^"]*)"', line))
            cur = {"name": line.rsplit(",", 1)[-1].strip(), "logo": a.get("tvg-logo", ""),
                   "group": a.get("group-title", ""), "epg": a.get("tvg-id", "")}
        elif line.startswith("#EXTVLCOPT:http-referrer="):
            cur["referer"] = line.split("=", 1)[1]
        elif line.startswith("#EXTVLCOPT:http-user-agent="):
            cur["ua"] = line.split("=", 1)[1]
        elif line and not line.startswith("#") and cur:
            url, _, hdr = line.partition("|")
            for kv in hdr.split("&") if hdr else []:
                k, _, v = kv.partition("=")
                if k.lower() == "referer": cur["referer"] = unquote(v)
                if k.lower() == "user-agent": cur["ua"] = unquote(v)
            cur["url"] = url
            out.append(cur); cur = {}
    return out

def find_working(url, s, referer=None, ua=None):
    """Prueba combinaciones de Referer/UA y devuelve la primera que funciona."""
    refs = [referer] if referer else [None, origin(url) + "/"]
    uas = [ua] if ua else [s["ua"]] + ALT_UAS
    for r in refs:
        for u in uas:
            h = {"User-Agent": u}
            if r:
                h.update(Referer=r, Origin=origin(r))
            ok, why = probe(url, h, s.get("timeout", 8))
            if ok:
                return {"referer": r or "", "ua": None if u == s["ua"] else u}
    return None

def append_channels(new):
    txt = YAML.read_text(encoding="utf-8")
    if not txt.endswith("\n"):
        txt += "\n"
    for c in new:
        c = {k: v for k, v in c.items() if v}
        txt += "  - " + json.dumps(c, ensure_ascii=False) + "\n"
    YAML.write_text(txt, encoding="utf-8")

def cmd_add(args):
    s, chs = load()
    if any(c["url"] == args.url for c in chs):
        sys.exit("Esa URL ya está en la lista.")
    combo = None if args.no_check else find_working(args.url, s, args.referer)
    if not args.no_check and not combo:
        sys.exit("✗ No responde con ninguna combinación de headers (¿caído, geobloqueado, token?). Usa --no-check para forzarlo.")
    combo = combo or {"referer": args.referer or "", "ua": None}
    ch = {"id": args.id or slug(args.name), "name": args.name, "group": args.group,
          "logo": args.logo, "url": args.url, "epg": args.epg, **combo}
    append_channels([ch])
    print(f"✔ Añadido: {ch['name']}  (referer={combo['referer'] or '-'}, ua={'propio' if combo['ua'] else 'por defecto'})")

def cmd_import(args):
    s, chs = load()
    have_u, have_i = {c["url"] for c in chs}, {c["id"] for c in chs}
    text = (requests.get(args.source, timeout=60).text if args.source.startswith("http")
            else Path(args.source).read_text(encoding="utf-8"))
    found = [c for c in parse_m3u(text)
             if (not args.filter or re.search(args.filter, c["name"], re.I)) and c["url"] not in have_u]
    print(f"{len(found)} candidatos nuevos")

    def work(c):
        if args.no_check:
            return c, {"referer": c.get("referer", ""), "ua": c.get("ua")}
        return c, find_working(c["url"], s, c.get("referer"), c.get("ua"))

    with ThreadPoolExecutor(s.get("workers", 16)) as ex:
        res = list(ex.map(work, found))
    new = []
    for c, combo in res:
        if not combo:
            continue
        cid = slug(c["name"])
        while cid in have_i:
            cid += "2"
        have_i.add(cid)
        new.append({"id": cid, "name": c["name"], "group": args.group or c["group"] or "Importados",
                    "logo": c["logo"], "url": c["url"], "epg": c["epg"], **combo})
        print(f"  ✔ {c['name']}")
    append_channels(new)
    print(f"Añadidos {len(new)} de {len(found)}")

def cmd_audit(args):
    s, chs = load()
    n = 0
    for c in chs:
        vol = volatility(c["url"])
        auto = bool(dm_id(c) or c.get("resolve"))
        if vol:
            n += 1
            chunk = any("chunklist" in v for v in vol)
            note = "  -> se auto-renueva" if auto else ("  -> check lo convierte a master (playlist.m3u8) si existe" if chunk else "  -> SIN renovación: añade resolve/alt")
            print(f"{'🔁' if auto else '⏳'} {c['name']}: {'; '.join(vol)}{note}")
    print(f"\n{n} URLs volátiles de {len(chs)}")

# ---------------------------------------------------------------- main
def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check").set_defaults(f=cmd_check)
    sub.add_parser("build").set_defaults(f=cmd_build)
    sub.add_parser("audit").set_defaults(f=cmd_audit)
    e = sub.add_parser("epg"); e.add_argument("--sources", nargs="*"); e.set_defaults(f=cmd_epg)
    a = sub.add_parser("add")
    a.add_argument("url"); a.add_argument("--name", required=True)
    a.add_argument("--group", default="Importados"); a.add_argument("--referer")
    a.add_argument("--logo", default=""); a.add_argument("--epg", default=""); a.add_argument("--id")
    a.add_argument("--no-check", action="store_true"); a.set_defaults(f=cmd_add)
    i = sub.add_parser("import")
    i.add_argument("source"); i.add_argument("--filter"); i.add_argument("--group")
    i.add_argument("--no-check", action="store_true"); i.set_defaults(f=cmd_import)
    args = p.parse_args(); args.f(args)

if __name__ == "__main__":
    main()
