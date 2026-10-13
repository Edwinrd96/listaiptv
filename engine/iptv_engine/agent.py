"""Modo AGENTE (BYON): un Pro instala esto en SU PC (IP residencial) para validar los canales de su país.
Usa solo la clave pública (anon) + un AGENT_TOKEN propio; nunca la service_role. El token solo da acceso a las fuentes de su dueño."""
import logging, signal, threading, time
from concurrent.futures import ThreadPoolExecutor

from . import __version__
from .config import Config
from .probe import is_dead, probe_source, quality_of
from .runner import Engine
from .supa import Supa

log = logging.getLogger("iptv_engine.agent")


class Agent(Engine):
    def __init__(self, cfg: Config, sb: Supa | None = None):
        if not cfg.agent_token:
            raise SystemExit("Falta AGENT_TOKEN (créalo en el panel: Ajustes → Agentes)")
        super().__init__(cfg, sb or Supa(cfg.supabase_url, cfg.anon_key or cfg.service_key))

    def heartbeat(self):
        self.sb.rpc("agent_heartbeat", {"p_token": self.cfg.agent_token, "p_version": __version__, "p_info": {"workers": self.cfg.workers}})

    def record(self, src, r, job_id):
        hard = True if r["ok"] else (self.cfg.hard_all or is_dead(r["error"]))
        return self.sb.rpc("agent_record_probe", {
            "p_token": self.cfg.agent_token, "p_source": src["source_id"], "p_ok": r["ok"], "p_http": r["http"], "p_error": r["error"],
            "p_latency_ms": r["ms"], "p_hard": hard,
            "p_resolved_url": r["url_used"] if r["ok"] and r["url_used"] != src["url"] else None, "p_quality": quality_of(r)})

    def profile(self, key):
        return None if not key else super().profile(key)

    def run_import_tests(self, limit: int = 100) -> int:
        items = self.sb.rpc("agent_claim_import_tests", {"p_token": self.cfg.agent_token, "p_limit": limit})
        if not items:
            return 0

        def one(it):
            return it, probe_source(self.cfg, it["url"], it.get("referer"), it.get("user_agent"), None, self.profile(it.get("header_profile")), it.get("extra_headers"))
        with ThreadPoolExecutor(self.cfg.workers) as ex:
            for it, r in ex.map(one, items):
                self.sb.rpc("agent_record_import_test", {"p_token": self.cfg.agent_token, "p_item": it["item_id"], "p_ok": r["ok"],
                                                         "p_http": r["http"], "p_error": r["error"], "p_latency_ms": r["ms"]})
        return len(items)

    def run_once(self, scheduled: bool = False) -> dict:
        self.heartbeat()
        tested = 0
        while (n := self.run_import_tests()):
            tested += n
        sources = self.sb.rpc("agent_due_sources", {"p_token": self.cfg.agent_token, "p_limit": 1000, "p_force": False})
        for s in sources:                                       # el agente no recibe estos campos; valores neutros
            s.setdefault("default_ua", None)
        st = self.process_sources(sources) if sources else {"probed": 0}
        return {"import_tests": tested, "sources": len(sources), **{k: v for k, v in st.items() if not isinstance(v, list)}}

    def loop(self):
        signal.signal(signal.SIGTERM, lambda *_: self._stop.set())
        signal.signal(signal.SIGINT, lambda *_: self._stop.set())
        log.info("agente %s (%s) listo", self.cfg.engine_id, self.cfg.vantage)
        while not self._stop.is_set():
            try:
                self.run_once()
            except Exception:
                log.exception("ciclo fallido")
            self._stop.wait(max(self.cfg.poll_seconds, 30))
