import json, logging, re, signal, threading, time
from datetime import datetime, timedelta, timezone
from urllib.parse import quote
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

from . import __version__
from .config import Config
from .epg import build_epg
from .notify import telegram
from .probe import is_dead, probe_source, quality_of
from .repair import repair_playlist
from .resolvers import dm_id, resolve_dailymotion, resolve_generic
from .supa import Supa

log = logging.getLogger("iptv_engine")


class Engine:
    def __init__(self, cfg: Config, sb: Supa | None = None):
        self.cfg = cfg
        self.sb = sb or Supa(cfg.supabase_url, cfg.service_key)
        self._last_sched = 0.0
        self._last_epg = -1e9
        self._stop = threading.Event()
        self._profiles: dict | None = None

    # ---------------------------------------------------------------- utilidades
    def heartbeat(self):
        self.sb.rpc("engine_heartbeat", {"p_engine": self.cfg.engine_id, "p_vantage": self.cfg.vantage, "p_version": __version__,
                                         "p_info": {"workers": self.cfg.workers, "hard_all": self.cfg.hard_all}})

    def elog(self, playlist, level, msg, job=None, channel=None, data=None):
        self.sb.rpc("engine_log", {"p_playlist": playlist, "p_level": level, "p_message": msg, "p_job": job, "p_channel": channel, "p_data": data})

    def profile(self, key: str | None) -> dict | None:
        """Perfiles de cabeceras (header_profiles): se leen una vez y se reutilizan."""
        if not key:
            return None
        if self._profiles is None:
            try:
                self._profiles = {p["key"]: p for p in self.sb.select("header_profiles", {"select": "key,user_agent,headers"})}
            except Exception:
                self._profiles = {}
        return self._profiles.get(key)

    # ---------------------------------------------------------------- una fuente
    def probe_task(self, src: dict) -> dict:
        url, vid, pre = src["url"], dm_id(src["kind"], src["resolve_ref"]), None
        cands = []
        if vid:                                               # Dailymotion: token fresco desde ESTA red
            fresh = resolve_dailymotion(self.cfg, vid)
            if fresh: cands.append(fresh)
            else: pre = "no se pudo renovar el token"
        if src.get("resolver") == "generic":                  # extractor genérico: busca el .m3u8 dentro de la página
            fresh = resolve_generic(self.cfg, src.get("resolve_ref") or url, src["referer"], src["user_agent"], src.get("proxy_url"))
            if fresh: cands.append(fresh)
            else: pre = "no se encontró ningún .m3u8 en la página"
        base, _, last = url.split("#")[0].split("?")[0].rpartition("/")
        if base and last.startswith("chunklist"):             # las chunklist caducan: se intenta el maestro de la misma ruta
            cands += [f"{base}/{n}" for n in ("playlist.m3u8", "index.m3u8", "master.m3u8")]
        if src.get("resolver") != "generic":                  # una página web no es un video: no se sondea tal cual
            cands.append(url)
        r = {"ok": False, "error": pre, "http": None, "ms": 0, "variants": [], "ua_used": None}
        for u in cands:
            r = probe_source(self.cfg, u, src["referer"], src["user_agent"], src.get("default_ua"), self.profile(src.get("header_profile")),
                             src.get("extra_headers"), src.get("proxy_url"))
            r["url_used"] = u
            if r["ok"]:
                break
        return r

    def record(self, src: dict, r: dict, job_id):
        hard = True if r["ok"] else (self.cfg.hard_all or is_dead(r["error"]))
        return self.sb.rpc("record_probe", {
            "p_source": src["source_id"], "p_ok": r["ok"], "p_http": r["http"], "p_error": r["error"], "p_latency_ms": r["ms"],
            "p_vantage": self.cfg.vantage, "p_hard": hard,
            "p_resolved_url": r["url_used"] if r["ok"] and r["url_used"] != src["url"] else None,
            "p_resolved_ua": r.get("ua_used"), "p_quality": quality_of(r), "p_job": job_id})

    # ---------------------------------------------------------------- un lote de fuentes
    @staticmethod
    def key_of(s: dict):
        return (s["url"], s["referer"], s["user_agent"], s["kind"], s["resolve_ref"], s.get("default_ua"), s.get("header_profile"),
                json.dumps(s.get("extra_headers"), sort_keys=True), s.get("proxy_url"), s.get("resolver"))

    def process_sources(self, sources: list[dict], job_id=None) -> dict:
        keys = {}                                              # fuentes idénticas (misma url/referer/ua/kind) se sondean UNA vez
        for s in sources:
            keys.setdefault(self.key_of(s), s)
        with ThreadPoolExecutor(self.cfg.workers) as ex:
            futs = {k: ex.submit(self.probe_task, s) for k, s in keys.items()}
            results = {k: f.result() for k, f in futs.items()}
        st = {"probed": len(sources), "ok": 0, "failed": 0, "rotated": 0, "new_down": [], "recovered": [], "strikes": 0}
        for s in sources:
            r = results[self.key_of(s)]
            out = self.record(s, r, job_id)
            st["ok" if r["ok"] else "failed"] += 1
            st["rotated"] += 1 if r.get("ua_used") else 0
            st["strikes"] += 1 if out.get("strike_applied") else 0
            if out["state"] == "down" and s["state"] != "down": st["new_down"].append(s["channel_name"])
            if out["state"] == "ok" and s["state"] in ("suspect", "down"): st["recovered"].append(s["channel_name"])
        return st

    def counts(self, playlist_id: str) -> dict:
        c = defaultdict(int)
        for row in self.sb.select("v_channels_table", {"playlist_id": f"eq.{playlist_id}", "select": "health"}):
            c[row["health"]] += 1
        return dict(c)

    def notify(self, title: str, st: dict, repaired: list, counts: dict):
        if not (st["new_down"] or st["recovered"] or repaired):
            return
        lines = [f"📺 {title} — 🟢 {counts.get('ok', 0)} · 🟡 {counts.get('warn', 0)} · 🔴 {counts.get('down', 0)} · ⚪ {counts.get('unverified', 0) + counts.get('unknown', 0)}"]
        if st["new_down"]: lines.append("🔻 Caídos: " + ", ".join(st["new_down"][:40]))
        if st["recovered"]: lines.append("🟢 Recuperados: " + ", ".join(st["recovered"][:40]))
        if repaired: lines.append("🔧 Reparados: " + ", ".join(r["channel"] for r in repaired[:40]))
        telegram(self.cfg, "\n".join(lines))

    # ---------------------------------------------------------------- pruebas de importación masiva (antes de importar)
    def run_import_tests(self, limit: int = 100) -> int:
        """Prueba en vivo las URLs de un lote M3U gigante; la UI ve el progreso por Realtime. Solo HTTP/HLS, sin guardar nada en las listas."""
        items = self.sb.rpc("claim_import_tests", {"p_limit": limit, "p_vantage": self.cfg.vantage})
        if not items:
            return 0

        def one(it):
            r = probe_source(self.cfg, it["url"], it.get("referer"), it.get("user_agent"), None, self.profile(it.get("header_profile")), it.get("extra_headers"))
            return it, r
        with ThreadPoolExecutor(self.cfg.workers) as ex:
            for it, r in ex.map(one, items):
                self.sb.rpc("record_import_test", {"p_item": it["item_id"], "p_ok": r["ok"], "p_http": r["http"], "p_error": r["error"], "p_latency_ms": r["ms"]})
        return len(items)

    # ---------------------------------------------------------------- proxies propios (BYOP): prueba los nuevos y los que el usuario pidió re-probar
    def run_proxy_tests(self, limit: int = 50) -> int:
        """Prueba cada proxy sin comprobar (last_test_at nulo) o viejo, y guarda latencia y país de salida. El usuario pide una prueba poniendo last_test_at en nulo desde el panel."""
        import requests
        old = (datetime.now(timezone.utc) - timedelta(hours=self.cfg.proxy_retest_hours)).isoformat()
        rows = self.sb.select("proxies", {"select": "id,scheme,host,port,username,proxy_secrets(password)", "enabled": "eq.true",
                                          "or": f"(last_test_at.is.null,last_test_at.lt.{old})", "limit": str(limit)})
        for p in rows:
            sec = p.get("proxy_secrets"); pw = (sec[0] if isinstance(sec, list) and sec else sec or {}).get("password") or ""
            auth = f"{quote(p['username'], safe='')}:{quote(pw, safe='')}@" if p.get("username") else ""
            url = f"{p['scheme']}://{auth}{p['host']}:{p['port']}"
            t0 = time.monotonic()
            try:
                r = requests.get(self.cfg.proxy_test_url, proxies={"http": url, "https": url}, timeout=(5, 10))
                ms = int((time.monotonic() - t0) * 1000)
                if not r.ok:
                    self.sb.rpc("record_proxy_test", {"p_proxy": p["id"], "p_ok": False, "p_latency": ms, "p_error": f"El destino de prueba respondió HTTP {r.status_code}"})
                    continue
                try: country = (r.json().get("country") or r.json().get("countryCode") or "")[:2].upper() or None
                except ValueError: country = None
                self.sb.rpc("record_proxy_test", {"p_proxy": p["id"], "p_ok": True, "p_latency": ms, "p_exit_country": country})
            except Exception as e:                          # nunca incluir la URL (lleva la clave) en el mensaje
                msg = type(e).__name__ + (": proxy rechazó usuario/clave" if "407" in str(e) else ": no se pudo conectar con el proxy")
                self.sb.rpc("record_proxy_test", {"p_proxy": p["id"], "p_ok": False, "p_error": msg})
        return len(rows)

    # ---------------------------------------------------------------- guía EPG programada
    def run_epg_due(self) -> int:
        """Rehace la guía de las listas con fuentes activas cuyo archivo tenga más de EPG_EVERY_HOURS (o no exista)."""
        self._last_epg = time.monotonic()
        pls = {r["playlist_id"] for r in self.sb.select("epg_sources", {"enabled": "eq.true", "select": "playlist_id"})}
        built = {r["playlist_id"]: r["built_at"] for r in self.sb.select("playlist_artifacts", {"kind": "eq.epg_gz", "select": "playlist_id,built_at"})}
        old = datetime.now(timezone.utc) - timedelta(hours=self.cfg.epg_every_hours); n = 0
        for pl in pls:
            if pl in built and datetime.fromisoformat(built[pl].replace("Z", "+00:00")) > old:
                continue
            try:
                build_epg(self.sb, self.cfg, pl, lambda lv, m, pl=pl: self.elog(pl, lv, m)); n += 1
            except Exception as e:                          # p. ej. canales sin ID de guía: se avisa en la consola y se sigue
                self.elog(pl, "warn", f"Guía automática: {str(e)[:200]}")
        return n

    # ---------------------------------------------------------------- trabajo del botón
    def process_job(self, job: dict):
        pl, kind, jid = job["playlist_id"], job["kind"], job["id"]
        try:
            if kind == "epg":
                self.elog(pl, "info", "Generando la guía EPG…", jid)
                meta = build_epg(self.sb, self.cfg, pl, lambda lv, m: self.elog(pl, lv, m, jid))
                self.sb.rpc("finish_job", {"p_job": jid, "p_status": "succeeded", "p_summary": {k: meta[k] for k in ("channels", "wanted", "programmes")}})
                return
            st = {"probed": 0, "ok": 0, "failed": 0, "rotated": 0, "new_down": [], "recovered": [], "strikes": 0}
            if kind in ("full", "probe"):
                sources = self.sb.rpc("due_sources", {"p_limit": 5000, "p_playlist": pl, "p_force": True, "p_vantage": self.cfg.vantage})
                self.elog(pl, "info", f"Auditando {len(sources)} fuentes desde «{self.cfg.vantage}» (timeout {self.cfg.timeout:g} s, rotando 3 User-Agents)", jid)
                st = self.process_sources(sources, jid)
            repaired = repair_playlist(self.sb, self.cfg, pl) if kind in ("full", "repair") else []
            counts = self.counts(pl)
            summary = {**{k: v for k, v in st.items() if not isinstance(v, list)}, "new_down": len(st["new_down"]), "recovered": len(st["recovered"]),
                       "repaired": len(repaired), "counts": counts}
            self.sb.rpc("finish_job", {"p_job": jid, "p_status": "succeeded", "p_summary": summary})
            self.notify("Sincronización", st, repaired, counts)
        except Exception as e:                                # nunca dejar un trabajo colgado en "running"
            log.exception("trabajo fallido")
            self.sb.rpc("finish_job", {"p_job": jid, "p_status": "failed", "p_error": f"{type(e).__name__}: {str(e)[:200]}"})

    # ---------------------------------------------------------------- revisión programada (sin botón)
    def run_scheduled(self):
        self._last_sched = time.monotonic()
        due = self.sb.rpc("due_sources", {"p_limit": 3000, "p_force": False, "p_vantage": self.cfg.vantage})
        by_pl = defaultdict(list)
        for s in due:
            by_pl[s["playlist_id"]].append(s)
        for pl, sources in by_pl.items():
            st = self.process_sources(sources)
            repaired = repair_playlist(self.sb, self.cfg, pl) if st["failed"] else []
            counts = self.counts(pl)
            if st["new_down"] or st["recovered"] or repaired:
                self.elog(pl, "info", f"Revisión programada: {st['ok']} ok, {st['failed']} fallos, {len(repaired)} reparados")
            self.notify("Revisión programada", st, repaired, counts)
        return len(due)

    def run_once(self, scheduled: bool = False) -> dict:
        self.heartbeat()
        jobs = 0
        while True:
            job = self.sb.rpc("claim_job", {"p_engine": self.cfg.engine_id, "p_vantage": self.cfg.vantage})
            if not job or not job.get("id"):
                break
            self.process_job(job); jobs += 1
        tested = 0
        while True:                                            # pruebas de importación: prioridad sobre la revisión programada
            n = self.run_import_tests()
            tested += n
            if n == 0:
                break
        proxies = self.run_proxy_tests()
        epgs = 0
        if self.cfg.epg_every_hours and time.monotonic() - self._last_epg >= 3600:
            epgs = self.run_epg_due()
        due = 0
        every = self.cfg.schedule_every_min * 60
        if scheduled or (every and time.monotonic() - self._last_sched >= every):
            due = self.run_scheduled()
        return {"jobs": jobs, "scheduled_sources": due, "import_tests": tested, "proxy_tests": proxies, "epg_built": epgs}

    def loop(self):
        signal.signal(signal.SIGTERM, lambda *_: self._stop.set())
        signal.signal(signal.SIGINT, lambda *_: self._stop.set())
        log.info("motor %s (%s) listo; consultando cada %s s", self.cfg.engine_id, self.cfg.vantage, self.cfg.poll_seconds)
        while not self._stop.is_set():
            try:
                self.run_once()
            except Exception:
                log.exception("ciclo fallido")
            self._stop.wait(self.cfg.poll_seconds)
