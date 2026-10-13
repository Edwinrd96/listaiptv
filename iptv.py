#!/usr/bin/env python3
"""
iptv.py v3 (Enterprise) - channels.yaml  ->  M3U + EPG + auto-reparación + reportes + Telegram

  run [--no-epg|--epg always]   TODO en uno: agregar.txt -> check -> repair -> build -> epg  (lo que corre GitHub solo)
  check [--limit N] [--only RE] prueba canales (timeout 5 s, rota 3 User-Agents de Smart TV si el origen rechaza)
  repair [--dry-run] [--only RE] busca la URL nueva en tus listas externas y actualiza el YAML sola
  build                         dist/iptv.m3u, iptv_vlc.m3u, caidos.m3u, ESTADO.md, REPORTE.html
  epg                           dist/epg.xml.gz (solo tus canales, tvg-id asignados automáticamente)
  intake                        procesa agregar.txt (añadir / cambiar / quitar / listas / importar)
  add | import | status | audit | telegram setup|test
"""
import argparse, copy, difflib, gzip, hashlib, html, io, json, os, re, sys, time, unicodedata
import datetime as dt
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import quote, unquote, urljoin, urlparse

import requests, yaml
import urllib3
urllib3.disable_warnings()

ROOT = Path(__file__).parent
YAML, DIST, ENV, INTAKE = ROOT / "channels.yaml", ROOT / "dist", ROOT / ".env", ROOT / "agregar.txt"
STATE_CI, STATE_LOCAL = ROOT / "state.json", ROOT / "state_local.json"
IS_CI = bool(os.getenv("GITHUB_ACTIONS"))             # desde GitHub (EE.UU.) solo el 404 prueba que un canal murió
OWN = STATE_CI if IS_CI else STATE_LOCAL
TG_API = "https://api.telegram.org"
SMART_TV_UAS = [                                       # formatos reales de Smart TV (Samsung Tizen, LG webOS, Sony Android TV)
    "Mozilla/5.0 (SMART-TV; LINUX; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) 85.0.4183.93/6.5 TV Safari/537.36",
    "Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.128 Safari/537.36 WebAppManager",
    "Mozilla/5.0 (Linux; Android 11; BRAVIA 4K GB) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36",
]
HEAD = """# ============================================================
#  FUENTE ÚNICA DE VERDAD - Lista IPTV Edwin RD
#  Una línea por canal. Campos: id, name, group, logo, url, referer
#  Opcionales: ua | alt (respaldos) | epg (id en la guía) | resolve | check:false
#              chno (número) | catchup, catchup_source, catchup_days (TV en diferido)
#  Para agregar/cambiar/quitar sin tocar este archivo: edita agregar.txt
# ============================================================
"""
INTAKE_HEAD = """# ===== AGREGAR / CAMBIAR CANALES DESDE TEXTO =====
# Escribe UNA línea por acción debajo de este bloque y guarda (Commit). El sistema la procesa solo y la borra de aquí.
#   Nombre | URL | grupo | referer(opcional) | logo(opcional)   -> añade un canal   (pon ! delante del nombre para no validarlo)
#   LISTA | URL                                                 -> añade una lista externa (de ahí salen las URLs de reemplazo)
#   IMPORTAR | URL | filtro | grupo                             -> importa canales de otra lista M3U (solo los que funcionan)
#   CAMBIAR | nombre del canal | nueva URL                      -> cambia la URL de un canal
#   QUITAR | nombre del canal                                   -> elimina un canal
#   GRUPO | nombre del canal | nuevo grupo                      -> mueve un canal de grupo
# Ejemplo:  Mi Canal | https://sitio.com/live/playlist.m3u8 | dominicana | https://sitio.com/
# ==================================================
"""

# ---------------------------------------------------------------- utilidades
def load_env():
    if ENV.exists():
        for line in ENV.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip().strip("\"'"))

def load():
    d = yaml.safe_load(YAML.read_text(encoding="utf-8"))
    return d["settings"], d["channels"]

def save_yaml(s, chs):
    out = HEAD + yaml.safe_dump({"settings": s}, allow_unicode=True, sort_keys=False, width=200) + "channels:\n"
    for c in chs:
        out += "  - " + json.dumps({k: v for k, v in c.items() if v not in ("", None, [])}, ensure_ascii=False) + "\n"
    YAML.write_text(out, encoding="utf-8")

def _read(p):
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}

def load_state():
    return _read(OWN)

def save_state(st):
    OWN.write_text(json.dumps(st, indent=1, ensure_ascii=False), encoding="utf-8")

def merged_state(fresh_hours=48):
    """Resultado de verificar desde RD (state_local.json) si es reciente; si no, el de GitHub (state.json)."""
    ci, loc, out = _read(STATE_CI), _read(STATE_LOCAL), {}
    for cid in (set(ci) | set(loc)) - {"_meta"}:
        a, b = ci.get(cid), loc.get(cid)
        try:
            fresh = b and (now() - dt.datetime.fromisoformat(b["checked"])) < dt.timedelta(hours=fresh_hours)
        except Exception:
            fresh = False
        out[cid] = b if fresh else (a or b)
    return out

def now():
    return dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)

def origin(u):
    p = urlparse(u)
    return f"{p.scheme}://{p.netloc}"

def norm(x):
    x = unicodedata.normalize("NFKD", x or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", x)

def slug(name):
    return norm(name) or "canal"

def tokens_name(n):
    n = re.sub(r"[\(\[].*?[\)\]]", " ", n or "")
    n = unicodedata.normalize("NFKD", n).encode("ascii", "ignore").decode().lower()
    return "".join(t for t in re.split(r"[^a-z0-9]+", n) if t and t not in ("canal", "tv", "hd", "television", "channel"))

def same_digits(a, b):
    return re.findall(r"\d+", a) == re.findall(r"\d+", b)

def match_group(s, text):
    t = norm(text)
    if not t:
        return "Importados"
    groups = s.get("group_order", [])
    for g in groups:
        if norm(g) == t:
            return g
    for g in groups:
        if t in norm(g):
            return g
    return text

def is_dead(why):
    return bool(re.search(r"HTTP (404|410)\b", why or ""))

def T(s):
    return s.get("timeout", 5)                      # timeout ESTRICTO por sondeo (segundos)

def rotate_uas(s):
    return s.get("rotate_uas") or SMART_TV_UAS

def urls_of(lst):
    return [x if isinstance(x, str) else x.get("url") for x in (lst or []) if x]

def find_channel(chs, text):
    n = norm(text)
    exact = [c for c in chs if n in (norm(c["name"]), norm(c["id"]))]
    if len(exact) == 1:
        return exact[0]
    part = [c for c in chs if n and n in norm(c["name"])]
    if len(part) == 1:
        return part[0]
    raise ValueError(f"no encuentro un canal único llamado «{text}»" + (f" (coinciden {len(part)})" if part else ""))

# ---------------------------------------------------------------- candidatos y cabeceras
def cand_list(ch):
    items = [{"url": ch["url"]}] + [({"url": a} if isinstance(a, str) else dict(a)) for a in ch.get("alt", [])]
    base, _, last = ch["url"].split("#")[0].split("?")[0].rpartition("/")
    if base and last.startswith("chunklist"):
        items = [{"url": f"{base}/{n}"} for n in ("playlist.m3u8", "index.m3u8", "master.m3u8")] + items
    seen, out = set(), []
    for c in items:
        if c.get("url") and c["url"] not in seen:
            seen.add(c["url"]); out.append(c)
    return out

def cand_headers(ch, c, s):
    h = {"User-Agent": c.get("ua") or ch.get("ua") or s["ua"]}
    ref = c["referer"] if "referer" in c else ch.get("referer")
    if ref:
        h["Referer"] = ref
        h["Origin"] = origin(ref)
    return h

def effective(ch, e, s):
    if e.get("url") and e.get("src") == ch["url"]:
        h = {"User-Agent": e.get("ua") or ch.get("ua") or s["ua"]}
        ref = e.get("referer", ch.get("referer"))
        if ref:
            h["Referer"] = ref
            h["Origin"] = origin(ref)
        return e["url"], h
    return ch["url"], cand_headers(ch, {}, s)

# ---------------------------------------------------------------- volatilidad / resolvedores
VOLATILE = [
    (r"chunklist_w?\d+", "chunklist de sesión (caduca)"),
    (r"/sec\d?\(", "token incrustado en la ruta (Dailymotion/CDN)"),
    (r"[?&;](token|tokenid|auth|sig|signature|hdnts|hdntl|hdnea|expires|exp|e|st|md5|policy|key-pair-id|wmssign|wmsauthsign|startdate|sec)=", "parámetro de token"),
    (r"~hmac=|~exp=", "firma HMAC con expiración"),
]

def volatility(url):
    r = [m for p, m in VOLATILE if re.search(p, url, re.I)]
    m = re.search(r"[?&;](?:expires|exp|e)=(\d{10})\b", url, re.I)
    if m:
        r.append("expira " + dt.datetime.fromtimestamp(int(m.group(1)), dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"))
    return r

DM_API = "https://www.dailymotion.com/player/metadata/video/{id}"

def dm_id(ch):
    for src in (ch.get("resolve", ""), ch.get("url", "")):
        m = (re.match(r"dm:(\w+)$", src) or re.search(r"dailymotion\.com/video/(x\w+)", src)
             or re.search(r"dmcdn\.net/.*?/(x[0-9a-z]{4,8})/", src) or re.search(r"cdn/live/video/(x\w+)", src))
        if m:
            return m.group(1)
    return None

def resolve_dm(vid, ua, timeout=5):
    try:
        r = requests.get(DM_API.format(id=vid), timeout=timeout, verify=False,
                         params={"embedder": "https://www.dailymotion.com/"},
                         headers={"User-Agent": ua, "Referer": "https://www.dailymotion.com/"})
        return r.json()["qualities"]["auto"][0]["url"]
    except Exception:
        return None

def resolve_ytdlp(page):
    import subprocess, shutil
    exe = shutil.which("yt-dlp")
    cmd = [exe] if exe else [sys.executable, "-m", "yt_dlp"]
    try:
        r = subprocess.run(cmd + ["-g", "-f", "best", "--no-warnings", page], capture_output=True, text=True, timeout=45)
        lines = [l for l in r.stdout.splitlines() if l.startswith("http")]
        return lines[0] if lines else None
    except Exception:
        return None

# ---------------------------------------------------------------- sondeo HLS (timeout total estricto)
def _fetch(url, h, timeout, rng=False):
    t_end = time.monotonic() + timeout
    hh = dict(h)
    if rng:
        hh["Range"] = "bytes=0-1023"
    r = requests.get(url, headers=hh, timeout=(min(3.05, timeout), timeout), verify=False, stream=True)
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

def probe(url, h, timeout=5):
    """OK = manifiesto HLS válido y 1er segmento descargable. Tiempo TOTAL máximo = timeout."""
    t_end = time.monotonic() + timeout
    left = lambda: t_end - time.monotonic()
    try:
        code, data, final = _fetch(url.split("#")[0], h, max(0.5, left()))
        if code != 200:
            return False, f"HTTP {code}"
        txt = data.decode("utf-8", "ignore")
        if "#EXTM3U" not in txt[:100]:
            return False, "no es m3u8"
        for _ in range(3):
            if left() <= 0.3:
                return False, "Timeout"
            items = [l.strip() for l in txt.splitlines() if l.strip() and not l.startswith("#")]
            if not items:
                return False, "manifiesto vacío"
            nxt = urljoin(final, items[0])
            if ".m3u8" in nxt.split("?")[0]:
                code, data, final = _fetch(nxt, h, max(0.5, left()))
                if code != 200:
                    return False, f"sub-manifiesto HTTP {code}"
                txt = data.decode("utf-8", "ignore")
                continue
            code, _, _ = _fetch(nxt, h, max(0.5, left()), rng=True)
            return (code in (200, 206)), f"segmento HTTP {code}"
        return True, "ok"
    except Exception as e:
        return False, type(e).__name__

def try_candidate(ch, c, s, t_end):
    """Prueba con el UA normal; si el origen rechaza (no es 404), rota por los 3 User-Agents de Smart TV."""
    h = cand_headers(ch, c, s)
    ok, why = probe(c["url"], h, T(s))
    if ok:
        return True, why, h
    if not is_dead(why):
        for ua in rotate_uas(s):
            if ua == h["User-Agent"]:
                continue
            if time.monotonic() > t_end:
                break
            h2 = dict(h); h2["User-Agent"] = ua
            ok2, _ = probe(c["url"], h2, T(s))
            if ok2:
                return True, "ok (UA rotado)", h2
    return False, why, h

def find_working(url, s, referer=None, ua=None, budget=25):
    t_end = time.monotonic() + budget
    refs = [referer] if referer else [None, origin(url) + "/"]
    uas = [ua] if ua else [s["ua"]] + rotate_uas(s)
    for r in refs:
        for u in uas:
            if time.monotonic() > t_end:
                return None
            h = {"User-Agent": u}
            if r:
                h.update(Referer=r, Origin=origin(r))
            ok, why = probe(url, h, T(s))
            if ok:
                return {"referer": r or "", "ua": None if u == s["ua"] else u}
            if is_dead(why):
                return None
    return None

# ---------------------------------------------------------------- Telegram
def tg_send(text):
    tok, chat = os.getenv("TELEGRAM_TOKEN"), os.getenv("TELEGRAM_CHAT_ID")
    if not (tok and chat):
        return False, "faltan TELEGRAM_TOKEN / TELEGRAM_CHAT_ID"
    try:
        j = requests.post(f"{TG_API}/bot{tok}/sendMessage", data={"chat_id": chat, "text": text[:4000]}, timeout=15).json()
        return bool(j.get("ok")), j.get("description", "ok")
    except Exception as e:
        return False, str(e)

def write_env(vals):
    cur = {}
    if ENV.exists():
        for l in ENV.read_text(encoding="utf-8").splitlines():
            if "=" in l and not l.startswith("#"):
                k, _, v = l.partition("="); cur[k.strip()] = v.strip()
    cur.update(vals)
    ENV.write_text("\n".join(f"{k}={v}" for k, v in cur.items()) + "\n", encoding="utf-8")
    gi = ROOT / ".gitignore"
    txt = gi.read_text(encoding="utf-8") if gi.exists() else ""
    if ".env" not in txt.split():
        gi.write_text(txt.rstrip("\n") + "\n.env\n__pycache__/\n", encoding="utf-8")

def cmd_telegram(a):
    if a.action == "setup":
        tok = a.token or os.getenv("TELEGRAM_TOKEN")
        if not tok:
            sys.exit("Falta el token:  python iptv.py telegram setup --token 123456:ABC...")
        try:
            r = requests.get(f"{TG_API}/bot{tok}/getUpdates", timeout=20).json()
        except Exception as e:
            sys.exit(f"No pude conectar con Telegram: {e}")
        if not r.get("ok"):
            sys.exit(f"Token inválido: {r.get('description')}")
        chats = [u["message"]["chat"] for u in r.get("result", []) if "message" in u]
        if not chats:
            sys.exit("No veo mensajes. Abre tu bot en Telegram, pulsa START, escribe 'hola' y repite.")
        write_env({"TELEGRAM_TOKEN": tok, "TELEGRAM_CHAT_ID": str(chats[-1]["id"])})
        os.environ["TELEGRAM_TOKEN"], os.environ["TELEGRAM_CHAT_ID"] = tok, str(chats[-1]["id"])
        print(f"✔ Chat detectado ({chats[-1].get('first_name', chats[-1]['id'])}). Guardado en .env (no se sube a GitHub).")
    ok, why = tg_send("✅ IPTV Edwin: Telegram conectado. Aquí recibirás avisos de caídos, recuperados y URLs reparadas.")
    print("✔ Mensaje de prueba enviado. Revisa Telegram." if ok else f"✗ No se pudo enviar: {why}")

# ---------------------------------------------------------------- check
def check_channel(ch, s):
    t_end = time.monotonic() + s.get("channel_budget", 20)
    cands, why = cand_list(ch), "sin candidatos"
    if not IS_CI:                                    # un token pedido desde EE.UU. no sirve en RD
        vid = dm_id(ch)
        fresh = resolve_dm(vid, s["ua"], T(s)) if vid else (resolve_ytdlp(ch["resolve"]) if ch.get("resolve") else None)
        if fresh:
            cands.insert(0, {"url": fresh})
        elif vid or ch.get("resolve"):
            why = "no se pudo renovar el token"
    for c in cands:
        ok, why, h = try_candidate(ch, c, s, t_end)
        if ok:
            ua = h["User-Agent"]
            return {"ok": True, "url": c["url"], "referer": h.get("Referer", ""), "ua": "" if ua == s["ua"] else ua}
        if time.monotonic() > t_end:
            why += " (presupuesto agotado)"
            break
    return {"ok": False, "why": why}

def cmd_check(a):
    s, chs = load()
    st = load_state()
    meta = st.setdefault("_meta", {})
    limit = a.limit or (s.get("dead_after", 12) if IS_CI else s.get("dead_after_local", 2))
    pool = [c for c in chs if not a.only or re.search(a.only, c["name"], re.I)]
    prev_down = {c["id"]: st.get(c["id"], {}).get("down", False) for c in chs}
    with ThreadPoolExecutor(s.get("workers", 32)) as ex:
        results = list(ex.map(lambda ch: (ch, None if ch.get("check") is False else check_channel(ch, s)), pool))
    alive = sum(1 for _, r in results if r and r["ok"])
    checked = sum(1 for _, r in results if r)
    if not a.only and checked >= 10 and alive < max(3, int(checked * 0.1)):
        msg = f"⚠ Solo {alive} de {checked} canales respondieron: parece un problema de red. NO se modificó nada."
        print(msg); tg_send(msg); sys.exit(2)
    stamp = now().isoformat(timespec="seconds")
    for ch, r in results:
        e = st.setdefault(ch["id"], {"fails": 0})
        e["checked"] = stamp
        if r is None:
            e.update(status="skipped", fails=0, down=False)
        elif r["ok"]:
            e.update(status="ok", fails=0, down=False, url=r["url"], src=ch["url"], referer=r["referer"], ua=r["ua"],
                     last_ok=stamp, why="ok", volatile=volatility(r["url"]))
            if r["url"] != ch["url"]:
                print(f"  ↻ {ch['name']}: usando {r['url'][:90]}")
        elif IS_CI and not is_dead(r["why"]):
            e.update(status="unreachable", fails=0, why=r["why"], down=False)
        else:
            e["fails"] = e.get("fails", 0) + 1
            e.update(status="dead", why=r["why"], limit=limit, down=e["fails"] >= limit)
            print(f"  ✗ {ch['name']}: {r['why']} ({min(e['fails'], limit)}/{limit})")
    new_down = [c["name"] for c in pool if st[c["id"]].get("down") and not prev_down[c["id"]]]
    back = [c["name"] for c in pool if st[c["id"]].get("status") == "ok" and prev_down[c["id"]]]
    n_ok = sum(1 for c in chs if st.get(c["id"], {}).get("status") == "ok")
    n_down = sum(1 for c in chs if st.get(c["id"], {}).get("down"))
    print(f"\n✅ {n_ok} activos · 🔴 {n_down} caídos · total {len(chs)}")
    today = now().strftime("%Y-%m-%d")
    if new_down or back or meta.get("last_summary") != today:
        lines = [f"📺 IPTV Edwin — {n_ok} activos, {n_down} caídos de {len(chs)}"]
        if new_down:
            lines.append("🔻 Nuevos caídos: " + ", ".join(new_down[:40]) + (" …" if len(new_down) > 40 else ""))
        if back:
            lines.append("🟢 Recuperados: " + ", ".join(back[:40]))
        if not new_down and not back:
            lines.append("Sin cambios.")
        ok, why = tg_send("\n".join(lines))
        if ok:
            meta["last_summary"] = today
        elif os.getenv("TELEGRAM_TOKEN"):
            print(f"  (Telegram: {why})")
    meta["last_check"] = stamp
    save_state(st)

# ---------------------------------------------------------------- listas externas + auto-reparación
def parse_m3u(text):
    out, cur = [], {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#EXTINF"):
            at = dict(re.findall(r'([\w-]+)="([^"]*)"', line))
            cur = {"name": line.rsplit(",", 1)[-1].strip(), "logo": at.get("tvg-logo", ""),
                   "group": at.get("group-title", ""), "epg": at.get("tvg-id", "")}
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

def ext_sources(s):
    srcs = urls_of(s.get("external_lists"))
    if s.get("iptv_org_fallback", True):
        srcs += [f"https://iptv-org.github.io/iptv/countries/{cc}.m3u" for cc in s.get("repair_countries", ["do", "mx", "co", "ar", "es", "cl", "ve", "pe", "ec", "us"])]
    return srcs

def load_pool(sources):
    def get(src):
        try:
            txt = requests.get(src, timeout=45).text if src.startswith("http") else Path(src).read_text(encoding="utf-8")
            items = parse_m3u(txt.replace("\r", ""))
            for i in items:
                i["src"] = src
            return items
        except Exception as e:
            print(f"  (sin acceso a {src[:70]}: {type(e).__name__})")
            return []
    with ThreadPoolExecutor(8) as ex:
        return [i for lst in ex.map(get, sources) for i in lst if i.get("url")]

def log_change(line):
    DIST.mkdir(exist_ok=True)
    f = DIST / "CAMBIOS.md"
    old = f.read_text(encoding="utf-8").splitlines() if f.exists() else ["# Cambios automáticos (URLs reparadas, canales agregados)", ""]
    f.write_text("\n".join(old[:2] + [f"- {now():%Y-%m-%d %H:%M} UTC · {line}"] + old[2:][:150]), encoding="utf-8")

def cmd_repair(a):
    s, chs = load()
    st = load_state()
    meta = st.setdefault("_meta", {})
    mode = getattr(a, "mode", None) or s.get("repair_mode", "promote")

    def failing(c):
        e = st.get(c["id"], {})
        return c.get("check") is not False and (e.get("status") == "dead" or (e.get("status") == "unreachable" and not IS_CI))

    todo = [c for c in chs if failing(c) and (not a.only or re.search(a.only, c["name"], re.I))]
    if not todo:
        print("Reparación: ningún canal caído."); return
    pool = load_pool(a.sources or ext_sources(s))
    index = [(tokens_name(p["name"]), p) for p in pool]
    print(f"Reparación: {len(todo)} canales caídos · {len(index)} streams en tus listas externas")
    jobs = []
    for ch in todo:
        have = set(urls_of(cand_list(ch)))
        mine = tokens_name(ch["name"])
        scored = sorted(((difflib.SequenceMatcher(None, mine, k).ratio(), p) for k, p in index if k and same_digits(mine, k)), key=lambda x: -x[0])
        jobs += [(ch, p, r) for r, p in scored if r >= 0.86 and p["url"] not in have][:4]

    def work(j):
        ch, p, r = j
        return ch, p, r, find_working(p["url"], s, p.get("referer"), p.get("ua"))

    with ThreadPoolExecutor(s.get("workers", 32)) as ex:
        res = list(ex.map(work, jobs))
    best = {}
    for ch, p, r, combo in res:
        if combo and (ch["id"] not in best or r > best[ch["id"]][2]):
            best[ch["id"]] = (ch, p, r, combo)
    fixed = []
    for ch, p, r, combo in best.values():
        old_url = ch["url"]
        if mode == "promote":
            old = {"url": old_url, "referer": ch.get("referer", ""), "from": "anterior"}
            if ch.get("ua"): old["ua"] = ch["ua"]
            ch["alt"] = ([old] + [x for x in ch.get("alt", []) if (x if isinstance(x, str) else x["url"]) != p["url"]])[:5]
            ch["url"] = p["url"]
            ch["referer"] = combo["referer"] or None
            ch["ua"] = combo["ua"]
        else:
            ch.setdefault("alt", []).append({k: v for k, v in {"url": p["url"], "referer": combo["referer"], "ua": combo["ua"], "from": "lista externa"}.items() if v is not None})
        fixed.append(ch["name"])
        if not a.dry_run:
            st[ch["id"]] = {"status": "ok", "fails": 0, "down": False, "url": p["url"], "src": ch["url"], "referer": combo["referer"],
                            "ua": combo["ua"] or "", "last_ok": now().isoformat(timespec="seconds"), "checked": now().isoformat(timespec="seconds"),
                            "why": "ok (URL reparada)", "volatile": volatility(p["url"])}
            log_change(f"🔧 {ch['name']}: {old_url[:55]} → {p['url'][:55]} (de {p['src'][:50]})")
        print(f"  🔧 {ch['name']}  ←  «{p['name']}»  {p['url'][:70]}")
    if fixed and not a.dry_run:
        save_yaml(s, chs)
        tg_send("🔧 URLs reparadas automáticamente: " + ", ".join(fixed))
    print(f"Reparados {len(fixed)} de {len(todo)}" + (" (simulación)" if a.dry_run else ""))
    if not a.dry_run:
        meta["last_repair"] = now().isoformat(timespec="seconds")
        save_state(st)

# ---------------------------------------------------------------- build (M3U avanzado)
def esc(v):
    return (v or "").replace('"', "'")

def stream_url(h, url, s, vlc):
    if vlc:
        return url
    enc = (lambda v: quote(v, safe=":/.-_~")) if s.get("encode_headers", True) else (lambda v: v)
    return url + "|" + "&".join(f"{k}={enc(v)}" for k, v in h.items())

def catchup_of(ch, url, s):
    if ch.get("catchup"):
        return ch["catchup"], ch.get("catchup_source"), ch.get("catchup_days")
    for rule in s.get("catchup_defaults", []):
        if re.search(rule.get("match", "$^"), url):
            return rule.get("catchup"), rule.get("catchup_source"), rule.get("catchup_days")
    return None, None, None

def out_group(ch, s):
    return s.get("group_aliases", {}).get(ch["group"], ch["group"])

def logo_of(ch, s):
    if s.get("logo_base") and (ROOT / "logos" / f"{ch['id']}.png").exists():
        return s["logo_base"].rstrip("/") + f"/{ch['id']}.png"
    return ch.get("logo", "")

def render(chs, s, st, vlc):
    epg = s.get("epg_public_url") or ",".join(urls_of(s.get("epg_sources"))[:1])
    out = [f'#EXTM3U x-tvg-url="{epg}"' if epg else "#EXTM3U", ""]
    for ch in chs:
        url, h = effective(ch, st.get(ch["id"], {}), s)
        shown = url
        if s.get("worker_url") and dm_id(ch):
            shown = f'{s["worker_url"].rstrip("/")}/dm/{dm_id(ch)}.m3u8'
        at = [f'tvg-id="{esc(ch["id"])}"', f'tvg-name="{esc(ch["name"])}"', f'tvg-logo="{esc(logo_of(ch, s))}"']
        if ch.get("chno"): at.append(f'tvg-chno="{ch["chno"]}"')
        if ch.get("lang"): at.append(f'tvg-language="{esc(ch["lang"])}"')
        at.append(f'group-title="{esc(out_group(ch, s))}"')
        cu, cs, cd = catchup_of(ch, shown, s)
        if cu:
            at.append(f'catchup="{cu}"')
            if cs: at.append(f'catchup-source="{esc(cs)}"')
            if cd: at.append(f'catchup-days="{cd}"')
        out.append(f'#EXTINF:-1 {" ".join(at)},{ch["name"]}')
        if vlc:
            for k, key in (("User-Agent", "http-user-agent"), ("Referer", "http-referrer")):
                if k in h:
                    out.append(f"#EXTVLCOPT:{key}={h[k]}")
            out.append("#EXTVLCOPT:http-reconnect=true")
        out.append(stream_url(h, shown, s, vlc))
        out.append("")
    return "\n".join(out)

def icon(c, e):
    if c.get("check") is False or e.get("status") == "skipped":
        return "⚪ sin verificar"
    if e.get("down"):
        return "🔴 caído"
    if e.get("status") == "dead":
        return f"🟠 falló {e.get('fails', 0)}/{e.get('limit', '?')}"
    if e.get("status") == "unreachable":
        return "🌎 no verificable desde GitHub"
    if e.get("status") == "ok":
        return "🔁 activo (token renovado)" if (dm_id(c) or c.get("resolve")) else "🟢 activo"
    return "⚪ sin probar"

def write_reports(chs, s, st):
    n = len(chs)
    n_ok = sum(1 for c in chs if st.get(c["id"], {}).get("status") == "ok")
    n_dn = sum(1 for c in chs if st.get(c["id"], {}).get("down"))
    stamp = now().strftime("%Y-%m-%d %H:%M UTC")
    rows, md = [], [f"# Estado de la lista\nActualizado: {stamp} · 🟢 {n_ok} activos · 🔴 {n_dn} caídos · total {n}\n",
                    "| Canal | Grupo | Estado | Motivo | Último OK |", "|---|---|---|---|---|"]
    for c in chs:
        e = st.get(c["id"], {})
        ic = icon(c, e)
        cls = "dn" if e.get("down") else ("ok" if e.get("status") == "ok" else "mid")
        rows.append(f"<tr class='{cls}'><td>{html.escape(c['name'])}</td><td>{html.escape(out_group(c, s))}</td>"
                    f"<td>{ic}</td><td>{html.escape(str(e.get('why', '')))}</td><td>{e.get('last_ok', '-')}</td></tr>")
        md.append(f"| {c['name']} | {out_group(c, s)} | {ic} | {e.get('why', '')} | {e.get('last_ok', '-')} |")
    page = f"""<!doctype html><meta charset="utf-8"><title>Estado IPTV</title>
<style>body{{font:15px system-ui;margin:20px;max-width:1100px}}table{{border-collapse:collapse;width:100%}}
td,th{{padding:6px 10px;border-bottom:1px solid #ddd;text-align:left}}tr.dn{{background:#fde8e8}}tr.ok{{background:#eefaf0}}
tr.mid{{background:#fff6e5}}button,input{{padding:6px 10px;margin:0 4px 10px 0}}</style>
<h2>📺 Estado de tu lista</h2><p>{stamp} · 🟢 {n_ok} activos · 🔴 {n_dn} caídos · total {n}</p>
<button onclick="f('')">Todos</button><button onclick="f('dn')">Solo caídos</button><button onclick="f('ok')">Solo activos</button>
<button onclick="f('mid')">Dudosos</button><input id=q placeholder="Buscar canal…" oninput="s()">
<table id=t><tr><th>Canal</th><th>Grupo</th><th>Estado</th><th>Motivo</th><th>Último OK</th></tr>{''.join(rows)}</table>
<script>function f(c){{document.querySelectorAll('#t tr[class]').forEach(r=>r.style.display=(!c||r.className==c)?'':'none')}}
function s(){{var v=q.value.toLowerCase();document.querySelectorAll('#t tr[class]').forEach(r=>r.style.display=r.textContent.toLowerCase().includes(v)?'':'none')}}</script>"""
    DIST.mkdir(exist_ok=True)
    (DIST / "REPORTE.html").write_text(page, encoding="utf-8")
    (DIST / "ESTADO.md").write_text("\n".join(md), encoding="utf-8")

def cmd_build(a=None):
    s, chs = load()
    st = merged_state()
    ids, urls = set(), set()
    for ch in chs:
        for k in ("id", "name", "group", "url"):
            if not ch.get(k):
                sys.exit(f"Canal sin campo '{k}': {ch}")
        if ch["id"] in ids: print(f"⚠ id duplicado: {ch['id']}")
        if ch["url"] in urls: print(f"⚠ URL duplicada: {ch['name']}")
        ids.add(ch["id"]); urls.add(ch["url"])
    order = s.get("group_order", [])
    gi = lambda c: order.index(out_group(c, s)) if out_group(c, s) in order else len(order)
    chs = sorted(chs, key=lambda c: (gi(c), c.get("chno") or 99999))
    live = [c for c in chs if not st.get(c["id"], {}).get("down")]
    dead = [c for c in chs if st.get(c["id"], {}).get("down")]
    DIST.mkdir(exist_ok=True)
    (DIST / "iptv.m3u").write_text(render(live, s, st, False), encoding="utf-8")
    (DIST / "iptv_vlc.m3u").write_text(render(live, s, st, True), encoding="utf-8")
    (DIST / "caidos.m3u").write_text(render(dead, s, st, False), encoding="utf-8")
    write_reports(chs, s, st)
    print(f"✔ {len(live)} en la lista · {len(dead)} en caidos.m3u -> {DIST}/")

def cmd_status(a):
    s, chs = load()
    st = merged_state()
    by = {}
    for c in chs:
        e = st.get(c["id"], {})
        k = "dn" if e.get("down") else ("ok" if e.get("status") == "ok" else "otros")
        by.setdefault(out_group(c, s), {"ok": 0, "dn": 0, "otros": 0})[k] += 1
    for g, v in by.items():
        print(f"{g:34} 🟢 {v['ok']:3}  🔴 {v['dn']:3}  ⚪ {v['otros']:3}")
    print("\nCaídos:", ", ".join(c["name"] for c in chs if st.get(c["id"], {}).get("down")) or "ninguno")

def cmd_audit(a):
    s, chs = load()
    n = 0
    for c in chs:
        vol = volatility(c["url"])
        if vol:
            n += 1
            print(f"{'🔁' if (dm_id(c) or c.get('resolve')) else '⏳'} {c['name']}: {'; '.join(vol)}")
    print(f"\n{n} URLs volátiles de {len(chs)}")

# ---------------------------------------------------------------- EPG automático
def epg_signature(chs):
    return hashlib.sha1("|".join(sorted(f"{c['id']}:{c['name']}:{c.get('epg', '')}" for c in chs)).encode()).hexdigest()[:12]

def open_source(src):
    if re.match(r"https?://", src):
        r = requests.get(src, timeout=120, verify=False)
        r.raise_for_status()
        raw = r.content
    else:
        raw = Path(src).read_bytes()
    return io.BytesIO(gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw)

def cmd_epg(a):
    s, chs = load()
    by_tok, by_guide = {}, {}
    for c in chs:
        by_tok.setdefault(tokens_name(c["name"]), []).append(c["id"])
        if c.get("epg"):
            by_guide.setdefault(c["epg"], []).append(c["id"])
    keys = [k for k in by_tok if k]

    def match(gid, names):
        if gid in by_guide:
            return by_guide[gid]
        toks = [tokens_name(n) for n in names if n]
        for t in toks:
            if t in by_tok:
                return by_tok[t]
        for t in toks:
            if len(t) >= 5:
                for m in difflib.get_close_matches(t, keys, n=3, cutoff=0.9):
                    if same_digits(t, m):
                        return by_tok[m]
        return []

    t0 = now()
    lo = (t0 - dt.timedelta(hours=6)).strftime("%Y%m%d%H%M%S")
    hi = (t0 + dt.timedelta(days=s.get("epg_days", 3))).strftime("%Y%m%d%H%M%S")
    keep_desc = s.get("epg_keep_desc", True)
    out, matched, mapping = ET.Element("tv", {"generator-info-name": "iptv.py"}), set(), {}
    for src in a.sources or urls_of(s.get("epg_sources")):
        try:
            f = open_source(src)
        except Exception as e:
            print(f"✗ {src[:70]}: {type(e).__name__}"); continue
        gmap, n_prog = {}, 0
        for _, el in ET.iterparse(f, events=("end",)):
            if el.tag == "channel":
                gid = el.get("id")
                ours = [i for i in match(gid, [d.text for d in el.findall("display-name")]) if i not in matched]
                if ours:
                    for i in ours:
                        node = copy.deepcopy(el); node.set("id", i); out.append(node)
                        matched.add(i); mapping[i] = {"guia": gid, "fuente": src}
                    gmap[gid] = ours
                el.clear()
            elif el.tag == "programme":
                ours = gmap.get(el.get("channel"))
                if ours and el.get("stop", "")[:14] >= lo and el.get("start", "")[:14] <= hi:
                    if not keep_desc:
                        for d in el.findall("desc"):
                            el.remove(d)
                    for i in ours:
                        node = copy.deepcopy(el); node.set("channel", i); out.append(node); n_prog += 1
                el.clear()
        print(f"✔ {src[:70]}: {n_prog} programas · {len(gmap)} canales tuyos encontrados")
    DIST.mkdir(exist_ok=True)
    buf = io.BytesIO()
    ET.ElementTree(out).write(buf, encoding="utf-8", xml_declaration=True)
    with gzip.open(DIST / "epg.xml.gz", "wb", compresslevel=9) as g:
        g.write(buf.getvalue())
    (DIST / "epg_mapping.json").write_text(json.dumps(mapping, indent=1, ensure_ascii=False), encoding="utf-8")
    (DIST / "epg_sin_guia.txt").write_text("\n".join(c["name"] for c in chs if c["id"] not in matched), encoding="utf-8")
    print(f"EPG: {len(matched)}/{len(chs)} canales con guía · {(DIST / 'epg.xml.gz').stat().st_size // 1024} KB")

# ---------------------------------------------------------------- intake: agregar.txt
def import_from(s, chs, source, filt, group, no_check=False):
    have_u, have_i = {c["url"] for c in chs}, {c["id"] for c in chs}
    text = requests.get(source, timeout=60).text if source.startswith("http") else Path(source).read_text(encoding="utf-8")
    found = [c for c in parse_m3u(text.replace("\r", "")) if (not filt or re.search(filt, c["name"], re.I)) and c["url"] not in have_u]
    work = (lambda c: (c, {"referer": c.get("referer", ""), "ua": c.get("ua")})) if no_check else \
           (lambda c: (c, find_working(c["url"], s, c.get("referer"), c.get("ua"))))
    with ThreadPoolExecutor(s.get("workers", 32)) as ex:
        res = list(ex.map(work, found))
    added = []
    for c, combo in res:
        if not combo:
            continue
        cid = slug(c["name"])
        while cid in have_i:
            cid += "2"
        have_i.add(cid)
        chs.append({k: v for k, v in {"id": cid, "name": c["name"], "group": match_group(s, group) if group else (c["group"] or "Importados"),
                                      "logo": c["logo"], "url": c["url"], "epg": c["epg"], **combo}.items() if v not in ("", None)})
        added.append(c["name"])
    return len(found), added

def apply_line(s, chs, parts):
    kw = parts[0].upper().lstrip("!")
    if kw == "LISTA":
        url = parts[1] if len(parts) > 1 else ""
        if not url.startswith("http"):
            raise ValueError("falta la URL de la lista")
        if url in urls_of(s.get("external_lists")):
            raise ValueError("esa lista ya estaba")
        try:
            n = len(parse_m3u(requests.get(url, timeout=45).text.replace("\r", "")))
        except Exception as e:
            raise ValueError(f"no pude descargar la lista ({type(e).__name__})")
        if n == 0:
            raise ValueError("la lista no tiene canales M3U válidos")
        s.setdefault("external_lists", []).append(url)
        return f"Lista externa añadida ({n} canales): {url[:70]}"
    if kw == "IMPORTAR":
        if len(parts) < 2 or not parts[1].startswith("http"):
            raise ValueError("uso: IMPORTAR | URL | filtro | grupo")
        found, added = import_from(s, chs, parts[1], parts[2] if len(parts) > 2 else "", parts[3] if len(parts) > 3 else "")
        return f"Importados {len(added)} de {found} candidatos (solo los que responden)"
    if kw == "QUITAR":
        ch = find_channel(chs, parts[1] if len(parts) > 1 else "")
        chs.remove(ch)
        return f"Quitado: {ch['name']}"
    if kw == "CAMBIAR":
        if len(parts) < 3 or not parts[2].startswith("http"):
            raise ValueError("uso: CAMBIAR | nombre | nueva URL")
        ch = find_channel(chs, parts[1])
        ch["url"] = parts[2]
        return f"URL cambiada: {ch['name']}"
    if kw == "GRUPO":
        if len(parts) < 3:
            raise ValueError("uso: GRUPO | nombre | nuevo grupo")
        ch = find_channel(chs, parts[1])
        ch["group"] = match_group(s, parts[2])
        return f"{ch['name']} → {ch['group']}"
    # canal nuevo: Nombre | URL | grupo | referer | logo
    force = parts[0].startswith("!")
    name = parts[0].lstrip("!").strip()
    url = parts[1] if len(parts) > 1 else ""
    if not name or not url.startswith("http"):
        raise ValueError("formato: Nombre | URL | grupo | referer | logo")
    if any(c["url"] == url for c in chs):
        raise ValueError("esa URL ya existe")
    referer = parts[3] if len(parts) > 3 and parts[3] else None
    note = ""
    combo = {"referer": referer or "", "ua": None} if force else find_working(url, s, referer)
    if not combo:
        if not IS_CI:
            raise ValueError("no responde desde tu red (usa ! delante del nombre para agregarlo igual)")
        combo, note = {"referer": referer or "", "ua": None}, " (sin verificar: GitHub no ve canales solo-RD)"
    cid, ids = slug(name), {c["id"] for c in chs}
    while cid in ids:
        cid += "2"
    chs.append({k: v for k, v in {"id": cid, "name": name, "group": match_group(s, parts[2] if len(parts) > 2 else ""),
                                  "logo": parts[4] if len(parts) > 4 else "", "url": url, **combo}.items() if v not in ("", None)})
    return f"Agregado: {name}{note}"

def intake_process():
    if not INTAKE.exists():
        return []
    s, chs = load()
    report, keep, changed = [], [], False
    for raw in INTAKE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        try:
            msg = apply_line(s, chs, parts)
            report.append("✅ " + msg); changed = True
            log_change(msg)
        except ValueError as e:
            report.append(f"✗ {line[:60]} → {e}")
            keep.append(f"# ✗ {line}    <- {e}")
    if report:
        if changed:
            save_yaml(s, chs)
        INTAKE.write_text(INTAKE_HEAD + "\n" + "\n".join(keep) + ("\n" if keep else ""), encoding="utf-8")
        print("agregar.txt:\n  " + "\n  ".join(report))
        tg_send("📝 agregar.txt procesado:\n" + "\n".join(report))
    return report

def cmd_intake(a):
    if not intake_process():
        print("agregar.txt: nada que procesar.")

# ---------------------------------------------------------------- add / import (línea de comandos)
def cmd_add(a):
    s, chs = load()
    parts = [("!" if a.no_check else "") + a.name, a.url, a.group, a.referer or "", a.logo]
    print("✔ " + apply_line(s, chs, parts))
    save_yaml(s, chs)

def cmd_import(a):
    s, chs = load()
    found, added = import_from(s, chs, a.source, a.filter, a.group, a.no_check)
    save_yaml(s, chs)
    print(f"Añadidos {len(added)} de {found} (solo los que funcionan)")

# ---------------------------------------------------------------- run (todo en uno)
def cmd_run(a):
    ns = argparse.Namespace
    intake_process()
    cmd_check(ns(limit=None, only=None))
    if not a.no_repair:
        cmd_repair(ns(dry_run=False, only=None, sources=None, mode=None))
    cmd_build()
    if not a.no_epg:
        s, chs = load()
        st = load_state()
        meta = st.setdefault("_meta", {})
        sig = epg_signature(chs)
        try:
            age = (now() - dt.datetime.fromisoformat(meta["epg_at"])).total_seconds() / 3600
        except Exception:
            age = 999
        if a.epg == "always" or sig != meta.get("epg_sig") or age > 20 or not (DIST / "epg.xml.gz").exists():
            cmd_epg(ns(sources=None))
            meta.update(epg_sig=sig, epg_at=now().isoformat(timespec="seconds"))
            save_state(st)
        else:
            print(f"EPG vigente ({age:.1f} h): no se regenera.")

# ---------------------------------------------------------------- main
def main():
    load_env()
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run"); r.add_argument("--no-epg", action="store_true"); r.add_argument("--no-repair", action="store_true")
    r.add_argument("--epg", default="auto"); r.set_defaults(f=cmd_run)
    c = sub.add_parser("check"); c.add_argument("--limit", type=int); c.add_argument("--only"); c.set_defaults(f=cmd_check)
    rp = sub.add_parser("repair"); rp.add_argument("--dry-run", action="store_true"); rp.add_argument("--only")
    rp.add_argument("--sources", nargs="*"); rp.add_argument("--mode", choices=["promote", "alt"]); rp.set_defaults(f=cmd_repair)
    for n, f in (("build", cmd_build), ("status", cmd_status), ("audit", cmd_audit), ("intake", cmd_intake)):
        sub.add_parser(n).set_defaults(f=f)
    e = sub.add_parser("epg"); e.add_argument("--sources", nargs="*"); e.set_defaults(f=cmd_epg)
    a = sub.add_parser("add"); a.add_argument("url"); a.add_argument("--name", required=True)
    a.add_argument("--group", default=""); a.add_argument("--referer"); a.add_argument("--logo", default="")
    a.add_argument("--no-check", action="store_true"); a.set_defaults(f=cmd_add)
    i = sub.add_parser("import"); i.add_argument("source"); i.add_argument("--filter"); i.add_argument("--group")
    i.add_argument("--no-check", action="store_true"); i.set_defaults(f=cmd_import)
    t = sub.add_parser("telegram"); t.add_argument("action", choices=["setup", "test"]); t.add_argument("--token"); t.set_defaults(f=cmd_telegram)
    args = p.parse_args(); args.f(args)

if __name__ == "__main__":
    main()
