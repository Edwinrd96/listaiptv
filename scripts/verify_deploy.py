#!/usr/bin/env python3
"""Verificador de despliegue: comprueba desde FUERA (como lo vería un visitante) que todo quedó bien y seguro.
Solo usa la librería estándar de Python. No necesita la service_role.

Uso:
  python scripts/verify_deploy.py --supabase-url https://xxxx.supabase.co --anon-key eyJ... \\
        --worker-url https://play.TUDOMINIO.com --panel-url https://panel.TUDOMINIO.com [--token <token de tu lista>]
(Si ya corriste el asistente, lee los valores de ui/.env y no necesitas pasar --supabase-url ni --anon-key.)
"""
import argparse, base64, json, re, ssl, sys, urllib.error, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
rows: list[tuple[str, str, str]] = []


def add(state: str, name: str, detail: str = ""):
    rows.append((state, name, detail))
    mark = {"OK": "✔", "FALLA": "✘", "AVISO": "!"}[state]
    print(f" {mark} {name}" + (f"  — {detail}" if detail else ""))


def http(method: str, url: str, headers: dict | None = None, body: bytes | None = None, timeout: int = 20):
    req = urllib.request.Request(url, data=body, method=method, headers={"User-Agent": "iptv-verify/1.0", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl.create_default_context()) as r:
            return r.status, dict(r.headers), r.read(2_000_000)
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read(200_000)
    except Exception as e:
        return 0, {}, str(e).encode()


def jwt_role(tok: str) -> str:
    try:
        p = tok.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))).get("role", "")
    except Exception:
        return ""


def env_from_ui() -> dict:
    out = {}
    f = ROOT / "ui" / ".env"
    if f.exists():
        for ln in f.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^(VITE_[A-Z_]+)=(.*)$", ln)
            if m: out[m.group(1)] = m.group(2).strip()
    return out


def check_supabase(url: str, anon: str):
    print("\nSupabase")
    h = {"apikey": anon, "Authorization": f"Bearer {anon}"}
    s, _, b = http("GET", f"{url}/rest/v1/", h)
    add("OK" if s == 200 else "FALLA", "La API responde con tu clave anon", f"HTTP {s}" if s != 200 else "")
    if s != 200:
        return
    # un visitante NO debe poder leer tablas privadas
    for t in ("channels", "outputs", "profiles", "proxy_secrets", "agents"):
        s, _, b = http("GET", f"{url}/rest/v1/{t}?select=*&limit=1", h)
        leaked = s == 200 and b.strip() not in (b"[]", b"")
        add("FALLA" if leaked else "OK", f"Visitante sin sesión no lee «{t}»", "¡FILTRA DATOS! revisa RLS y los permisos de anon" if leaked else f"HTTP {s}")
    # ni ejecutar funciones de administración
    for fn in ("admin_overview", "due_sources", "purge_old_data"):
        s, _, _ = http("POST", f"{url}/rest/v1/rpc/{fn}", {**h, "Content-Type": "application/json"}, b"{}")
        add("FALLA" if s == 200 else "OK", f"Visitante sin sesión no ejecuta «{fn}»", f"HTTP {s}")


def check_worker(worker: str, panel: str | None, token: str | None):
    print("\nWorker (API pública)")
    s, _, b = http("GET", f"{worker}/health")
    ok = s == 200 and b'"ok":true' in b.replace(b" ", b"")
    add("OK" if ok else "FALLA", "/health responde ok", "" if ok else f"HTTP {s} {b[:80].decode('utf-8', 'ignore')}")
    if not ok:
        return
    if "worker" in b.decode("utf-8", "ignore") and '"db":false' in b.decode().replace(" ", ""):
        add("FALLA", "El Worker NO alcanza la base de datos", "revisa SUPABASE_URL y SUPABASE_SERVICE_KEY en los secretos del Worker")
    s, _, _ = http("GET", f"{worker}/api/status")
    add("OK" if s == 401 else "FALLA", "Las rutas privadas piden sesión", f"HTTP {s} (debía ser 401)" if s != 401 else "")
    if panel:
        s, h, _ = http("OPTIONS", f"{worker}/api/probe", {"Origin": panel, "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "authorization,content-type"})
        allow = {k.lower(): v for k, v in h.items()}.get("access-control-allow-origin", "")
        add("OK" if allow == panel else "FALLA", "El panel está permitido (CORS)", f"el Worker contestó «{allow or 'nada'}»; añade {panel} a ALLOWED_ORIGINS y vuelve a desplegar" if allow != panel else "")
    s, h, _ = http("OPTIONS", f"{worker}/api/probe", {"Origin": "https://sitio-malicioso.example", "Access-Control-Request-Method": "POST"})
    allow = {k.lower(): v for k, v in h.items()}.get("access-control-allow-origin", "")
    add("OK" if allow not in ("*", "https://sitio-malicioso.example") else "FALLA", "Un sitio ajeno NO está permitido (CORS)", f"contestó «{allow}»" if allow else "")
    if token:
        if not re.fullmatch(r"[0-9a-f]{64}", token):
            add("FALLA", "El token de lista tiene formato inválido", "debe ser de 64 caracteres hexadecimales")
        else:
            s, _, b = http("GET", f"{worker}/p/{token}.m3u")
            add("OK" if s == 200 and b.lstrip().startswith(b"#EXTM3U") else "FALLA", "Tu lista M3U descarga", f"HTTP {s}" if s != 200 else "")
            s, h, _ = http("GET", f"{worker}/p/{token}/epg.xml.gz")
            add("OK" if s == 200 else "AVISO", "La guía EPG descarga", {404: "aún no se ha generado (normal si no la configuraste)", 501: "falta el almacén EPG en el Worker"}.get(s, f"HTTP {s}") if s != 200 else "")


def check_panel(panel: str):
    print("\nPanel web")
    s, _, b = http("GET", panel)
    add("OK" if s == 200 and b"<div id=\"root\">" in b else "FALLA", "El panel carga", f"HTTP {s}" if s != 200 else "")
    if s != 200:
        return
    html = b.decode("utf-8", "ignore")
    s2, _, _ = http("GET", f"{panel}/manifest.webmanifest")
    add("OK" if s2 == 200 else "AVISO", "Es instalable como app (manifest)", f"HTTP {s2}" if s2 != 200 else "")
    # SEGURIDAD: ningún JWT de rol service_role dentro de los archivos públicos del panel
    scripts = re.findall(r'src="(/assets/[^"]+\.js)"', html)
    leaked, seen = False, 0
    for sc in scripts[:6]:
        _, _, js = http("GET", panel + sc)
        for tok in set(re.findall(rb"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}", js)):
            seen += 1
            if jwt_role(tok.decode()) == "service_role":
                leaked = True
    add("FALLA" if leaked else "OK", "El panel NO contiene la clave service_role",
        "¡¡ALERTA!! La service_role está publicada. Cámbiala YA en Supabase (Settings → API → regenerar), quítala de las variables de Pages y vuelve a publicar" if leaked else f"revisados {len(scripts)} archivo(s) JS, {seen} clave(s) JWT (todas públicas)")


def main():
    ui = env_from_ui()
    p = argparse.ArgumentParser(description="Verificador de despliegue de IPTV Engine Pro")
    p.add_argument("--supabase-url", default=ui.get("VITE_SUPABASE_URL"))
    p.add_argument("--anon-key", default=ui.get("VITE_SUPABASE_ANON_KEY"))
    p.add_argument("--worker-url", default=ui.get("VITE_WORKER_URL"))
    p.add_argument("--panel-url")
    p.add_argument("--token", help="token de tu lista (el texto largo de tu enlace /p/<token>.m3u)")
    a = p.parse_args()
    print("== Verificación de despliegue ==")
    if a.supabase_url and a.anon_key:
        if jwt_role(a.anon_key) == "service_role":
            add("FALLA", "Diste la service_role como anon", "usa la anon; la service_role nunca debe salir de tu servidor")
        else:
            check_supabase(a.supabase_url.rstrip("/"), a.anon_key)
    else:
        add("AVISO", "Se omitió Supabase", "falta --supabase-url / --anon-key")
    if a.worker_url and "127.0.0.1" not in a.worker_url:
        check_worker(a.worker_url.rstrip("/"), a.panel_url.rstrip("/") if a.panel_url else None, a.token)
    elif a.worker_url:
        check_worker(a.worker_url.rstrip("/"), a.panel_url.rstrip("/") if a.panel_url else None, a.token)
    else:
        add("AVISO", "Se omitió el Worker", "falta --worker-url")
    if a.panel_url:
        check_panel(a.panel_url.rstrip("/"))
    else:
        add("AVISO", "Se omitió el panel", "falta --panel-url")
    bad = [r for r in rows if r[0] == "FALLA"]
    warn = [r for r in rows if r[0] == "AVISO"]
    print(f"\nResultado: {len(rows) - len(bad) - len(warn)} OK · {len(warn)} avisos · {len(bad)} FALLAS")
    if bad:
        print("Corrige las FALLAS antes de continuar (la guía, sección «Problemas comunes», explica cada una).")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
