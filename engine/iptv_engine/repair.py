"""Auto-reparación: si un canal falla, busca su nombre en tus listas externas, valida la URL nueva y la pone como principal."""
import difflib, re, unicodedata
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import unquote

import requests

from .config import Config
from .probe import probe_source
from .supa import Supa

DEFAULT_COUNTRIES = ["do", "mx", "co", "ar", "es", "cl", "ve", "pe", "ec", "us"]


def tokens_name(n: str) -> str:
    n = re.sub(r"[\(\[].*?[\)\]]", " ", n or "")
    n = unicodedata.normalize("NFKD", n).encode("ascii", "ignore").decode().lower()
    return "".join(t for t in re.split(r"[^a-z0-9]+", n) if t and t not in ("canal", "tv", "hd", "television", "channel"))


def same_digits(a: str, b: str) -> bool:
    return re.findall(r"\d+", a) == re.findall(r"\d+", b)


def parse_m3u(text: str):
    out, cur = [], {}
    for line in text.replace("\r", "").splitlines():
        line = line.strip()
        if line.startswith("#EXTINF"):
            at = dict(re.findall(r'([\w-]+)="([^"]*)"', line))
            cur = {"name": line.rsplit(",", 1)[-1].strip(), "group": at.get("group-title", ""), "epg": at.get("tvg-id", "")}
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


def load_pool(sources: list[str]):
    def get(src):
        try:
            txt = requests.get(src, timeout=45).text
            items = parse_m3u(txt)
            for i in items:
                i["src"] = src
            return items
        except Exception:
            return []
    with ThreadPoolExecutor(8) as ex:
        return [i for lst in ex.map(get, sources) for i in lst if i.get("url")]


def find_working(cfg: Config, url: str, referer=None, ua=None):
    """Prueba referers [dado | ninguno, origen]; el sondeo ya rota los 3 User-Agents de Smart TV."""
    m = re.match(r"(https?://[^/]+)", url)
    refs = [referer] if referer else [None, (m.group(1) + "/") if m else None]
    for ref in refs:
        r = probe_source(cfg, url, ref, ua)
        if r["ok"]:
            return {"referer": ref or "", "ua": r.get("ua_used") or ua, "probe": r}
    return None


def repair_playlist(sb: Supa, cfg: Config, playlist_id: str, only_channels: list[str] | None = None) -> list[dict]:
    rows = sb.select("v_channels_table", {"playlist_id": f"eq.{playlist_id}", "primary_state": "in.(suspect,down)", "select": "id,name,primary_url"})
    if only_channels:
        rows = [r for r in rows if r["id"] in only_channels]
    if not rows:
        return []
    st = sb.select("playlists", {"id": f"eq.{playlist_id}", "select": "settings"})[0]["settings"] or {}
    sources = [x["url"] for x in sb.select("external_lists", {"playlist_id": f"eq.{playlist_id}", "enabled": "eq.true", "select": "url"})]
    if cfg.iptv_org_fallback and st.get("iptv_org_fallback", True):
        sources += [f"https://iptv-org.github.io/iptv/countries/{cc}.m3u" for cc in st.get("repair_countries", DEFAULT_COUNTRIES)]
    pool = load_pool(sources)
    index = [(tokens_name(p["name"]), p) for p in pool]

    jobs = []
    for ch in rows:
        mine = tokens_name(ch["name"])
        scored = sorted(((difflib.SequenceMatcher(None, mine, k).ratio(), p) for k, p in index if k and same_digits(mine, k)), key=lambda x: -x[0])
        jobs += [(ch, p, r) for r, p in scored if r >= 0.86 and p["url"] != ch["primary_url"]][:4]

    def work(j):
        ch, p, score = j
        return ch, p, score, find_working(cfg, p["url"], p.get("referer"), p.get("ua"))

    with ThreadPoolExecutor(cfg.workers) as ex:
        res = list(ex.map(work, jobs))
    best = {}
    for ch, p, score, found in res:
        if found and (ch["id"] not in best or score > best[ch["id"]][2]):
            best[ch["id"]] = (ch, p, score, found)

    repaired = []
    for ch, p, score, found in best.values():
        prim = sb.select("channel_sources", {"channel_id": f"eq.{ch['id']}", "priority": "eq.0", "select": "id,url,referer,user_agent"})[0]
        has_alt = bool(sb.select("channel_sources", {"channel_id": f"eq.{ch['id']}", "priority": "eq.1", "select": "id"}))
        sb.patch("channel_sources", {"id": f"eq.{prim['id']}"}, {"url": p["url"], "referer": found["referer"] or None, "user_agent": found["ua"] or None})
        if not has_alt:                                   # la URL anterior queda como respaldo
            sb.insert("channel_sources", {"channel_id": ch["id"], "priority": 1, "url": prim["url"], "referer": prim["referer"], "user_agent": prim["user_agent"]})
        pr = found["probe"]
        sb.rpc("record_probe", {"p_source": prim["id"], "p_ok": True, "p_http": pr["http"], "p_latency_ms": pr["ms"], "p_vantage": cfg.vantage,
                                "p_hard": True, "p_resolved_ua": pr.get("ua_used")})
        sb.rpc("engine_log", {"p_playlist": playlist_id, "p_level": "info", "p_channel": ch["id"],
                              "p_message": f"🔧 {ch['name']}: URL reparada desde «{p['name']}» ({p['src'][:60]})"})
        repaired.append({"channel": ch["name"], "new_url": p["url"], "from": p["src"]})
    return repaired
