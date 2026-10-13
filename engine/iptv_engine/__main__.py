import argparse, json, logging, sys

from . import __version__
from .config import load
from .probe import probe_source
from .agent import Agent
from .runner import Engine


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    p = argparse.ArgumentParser(prog="iptv_engine", description=f"IPTV Engine Pro · motor {__version__}")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run-once", help="procesa los trabajos en cola (y opcionalmente la revisión programada) y termina")
    r.add_argument("--scheduled", action="store_true")
    sub.add_parser("loop", help="se queda consultando la cola (modo Docker)")
    pr = sub.add_parser("probe", help="prueba una URL suelta")
    pr.add_argument("url"); pr.add_argument("--referer"); pr.add_argument("--ua")
    sub.add_parser("agent", help="modo agente (BYON): valida TUS canales desde tu PC con AGENT_TOKEN; no necesita la service_role")
    sub.add_parser("doctor", help="comprueba variables y conexión")
    a = p.parse_args()
    cfg = load()
    if a.cmd == "probe":
        print(json.dumps(probe_source(cfg, a.url, a.referer, a.ua), ensure_ascii=False, indent=1)); return
    if a.cmd == "agent":
        if not cfg.supabase_url or not (cfg.anon_key or cfg.service_key):
            sys.exit("Faltan SUPABASE_URL y SUPABASE_ANON_KEY")
        Agent(cfg).loop(); return
    if not cfg.supabase_url or not cfg.service_key:
        sys.exit("Faltan SUPABASE_URL y/o SUPABASE_SERVICE_KEY")
    eng = Engine(cfg)
    if a.cmd == "doctor":
        eng.heartbeat(); print(f"✔ conectado · motor={cfg.engine_id} · vantage={cfg.vantage} · strikes por cualquier fallo={cfg.hard_all}"); return
    if a.cmd == "run-once":
        print(json.dumps(eng.run_once(scheduled=a.scheduled))); return
    eng.loop()


if __name__ == "__main__":
    main()
