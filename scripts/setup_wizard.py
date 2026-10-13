#!/usr/bin/env python3
"""Asistente de configuración de IPTV Engine Pro (funciona igual en Windows, Mac y Linux; solo usa la librería estándar de Python).

Qué evita:
  · pegar la clave equivocada (el asistente DECODIFICA las claves y comprueba que la anon sea 'anon' y la service_role sea 'service_role'),
  · poner la service_role en el panel (el archivo del panel solo recibe la anon),
  · inventar mal el SIGNING_SECRET (lo genera él, con aleatoriedad criptográfica),
  · olvidarte algún archivo .env o algún secreto del Worker.

Uso:
  python scripts/setup_wizard.py check                 # ¿tienes los programas necesarios?
  python scripts/setup_wizard.py init                  # pregunta datos y escribe ui/.env, engine/.env y worker/.dev.vars
  python scripts/setup_wizard.py init --apply-worker   # además carga los secretos en Cloudflare (necesita 'wrangler login')
  python scripts/setup_wizard.py init --non-interactive   # toma los datos de variables de entorno (para pruebas/automatización)
"""
import argparse, base64, getpass, json, os, re, secrets, shutil, subprocess, sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
OK, BAD, WARN = "✔", "✘", "!"


def say(mark: str, msg: str): print(f" {mark} {msg}")


# ---------------------------------------------------------------- utilidades
def jwt_claims(token: str) -> dict:
    try:
        part = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    except Exception:
        return {}


def project_ref(url: str) -> str:
    host = urlparse(url).hostname or ""
    return host.split(".")[0] if host.endswith(".supabase.co") else ""


def validate_url(u: str) -> str:
    u = u.strip().rstrip("/")
    p = urlparse(u)
    if p.scheme not in ("https", "http") or not p.hostname:
        raise ValueError("Debe ser una dirección completa, por ejemplo https://abcd1234.supabase.co")
    if p.path not in ("", "/"):
        raise ValueError("Pega solo la dirección base (sin /rest/v1 ni nada después de .supabase.co)")
    return u


def validate_keys(url: str, anon: str, service: str):
    ca, cs = jwt_claims(anon), jwt_claims(service)
    if not ca or not cs:
        raise ValueError("Las claves deben ser las «Legacy API keys» de Supabase (empiezan con eyJ…). Las nuevas sb_publishable_/sb_secret_ no sirven en esta versión.")
    if ca.get("role") == "service_role" and cs.get("role") == "anon":
        raise ValueError("Pegaste las claves INTERCAMBIADAS: la que pusiste como anon es la service_role. Corrígelo.")
    if ca.get("role") != "anon":
        raise ValueError(f"La clave anon debe tener role=anon (la tuya dice role={ca.get('role')!r}).")
    if cs.get("role") != "service_role":
        raise ValueError(f"La clave service_role debe tener role=service_role (la tuya dice role={cs.get('role')!r}).")
    ref = project_ref(url)
    if ref and (ca.get("ref") not in (None, ref) or cs.get("ref") not in (None, ref)):
        raise ValueError("Las claves pertenecen a OTRO proyecto de Supabase distinto de la URL que diste.")


def ask(prompt: str, default: str = "", secret: bool = False, env: str | None = None, nonint: bool = False) -> str:
    if nonint:
        return os.environ.get(env or "", default)
    suffix = f" [{default}]" if default else ""
    fn = getpass.getpass if secret else input
    v = fn(f"  {prompt}{suffix}: ").strip()
    return v or default


def write_env(path: Path, lines: dict[str, str], base: Path | None = None):
    """Escribe un .env a partir de la plantilla, sustituyendo solo las claves dadas (conserva comentarios y el resto)."""
    text = base.read_text(encoding="utf-8") if base and base.exists() else ""
    done = set()
    out = []
    for ln in text.splitlines():
        m = re.match(r"^([A-Z0-9_]+)=", ln)
        if m and m.group(1) in lines:
            comment = ""
            c = re.search(r"\s+#.*$", ln)
            if c and "=" in ln.split("#")[0]:
                comment = c.group(0)
            out.append(f"{m.group(1)}={lines[m.group(1)]}{comment}")
            done.add(m.group(1))
        else:
            out.append(ln)
    for k, v in lines.items():
        if k not in done:
            out.append(f"{k}={v}")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def set_toml_var(path: Path, key: str, value: str):
    t = path.read_text(encoding="utf-8")
    new = f'{key} = "{value}"'
    if re.search(rf"^{key}\s*=", t, re.M):
        t = re.sub(rf"^{key}\s*=.*$", new, t, flags=re.M)
    else:
        t = t.replace("[vars]\n", f"[vars]\n{new}\n", 1)
    path.write_text(t, encoding="utf-8")


# ---------------------------------------------------------------- check
def version_of(cmd: list[str]) -> str | None:
    exe = shutil.which(cmd[0])
    if not exe:
        return None
    try:
        r = subprocess.run([exe] + cmd[1:], capture_output=True, text=True, timeout=20)
        return (r.stdout or r.stderr).strip().splitlines()[0]
    except Exception:
        return None


def cmd_check(_a) -> int:
    print("\nComprobando programas necesarios…\n")
    bad = 0
    v = sys.version_info
    if v >= (3, 11):
        say(OK, f"Python {v.major}.{v.minor}.{v.micro}")
    else:
        say(BAD, f"Python {v.major}.{v.minor} — se recomienda 3.12 (mínimo 3.11)"); bad += 1
    g = version_of(["git", "--version"])
    say(OK if g else BAD, g or "Git no encontrado → https://git-scm.com"); bad += 0 if g else 1
    n = version_of(["node", "--version"])
    if n and int(n.lstrip("v").split(".")[0]) >= 20:
        say(OK, f"Node {n}")
    else:
        say(BAD, f"Node {n or 'no encontrado'} — necesitas la versión 20 o 22 LTS → https://nodejs.org"); bad += 1
    npm = version_of(["npm", "--version"]) if os.name != "nt" else version_of(["npm.cmd", "--version"])
    say(OK if npm else BAD, f"npm {npm}" if npm else "npm no encontrado (viene con Node)"); bad += 0 if npm else 1
    d = version_of(["docker", "--version"])
    say(OK if d else WARN, d or "Docker no encontrado (solo lo necesitas si el motor correrá en tu PC) → https://docker.com")
    print()
    print(" Todo listo." if not bad else f" Faltan {bad} cosa(s) obligatoria(s). Instálalas y vuelve a ejecutar este comando.")
    return 1 if bad else 0


# ---------------------------------------------------------------- init
def cmd_init(a) -> int:
    ni = a.non_interactive
    print("\n== IPTV Engine Pro · asistente de configuración ==\n")
    print(" Tus claves NO se guardan en ningún sitio salvo los archivos .env locales (ignorados por git).\n")
    while True:
        try:
            url = validate_url(ask("URL del proyecto Supabase (https://xxxx.supabase.co)", env="SUPABASE_URL", nonint=ni)); break
        except ValueError as e:
            if ni: sys.exit(f"{BAD} {e}")
            say(BAD, str(e))
    while True:
        anon = ask("Clave anon (Legacy API keys → anon public)", secret=True, env="SUPABASE_ANON_KEY", nonint=ni)
        service = ask("Clave service_role (Legacy API keys → service_role)  — SECRETA", secret=True, env="SUPABASE_SERVICE_KEY", nonint=ni)
        try:
            validate_keys(url, anon, service); break
        except ValueError as e:
            if ni: sys.exit(f"{BAD} {e}")
            say(BAD, str(e)); print()
    say(OK, "Claves verificadas (anon y service_role correctas y del mismo proyecto)")
    jwt_secret = ask("Legacy JWT secret (solo si tu proyecto usa HS256; deja vacío si no estás seguro)", secret=True, env="SUPABASE_JWT_SECRET", nonint=ni)
    worker = ask("Dirección del Worker (https://play.TUDOMINIO.com o la .workers.dev; puedes dejarla vacía y repetir luego)", env="WORKER_URL", nonint=ni)
    panel = ask("Dirección del panel (https://panel.TUDOMINIO.com o la .pages.dev; vacío = solo local)", env="PANEL_URL", nonint=ni)
    engine_id = ask("Nombre de este motor", default="motor-casa", env="ENGINE_ID", nonint=ni)
    vantage = ask("Dónde está este motor (local-do = en RD / github / vps-eeuu)", default="local-do", env="VANTAGE", nonint=ni)
    if worker:
        worker = validate_url(worker)
    if panel:
        panel = validate_url(panel)
    signing = os.environ.get("SIGNING_SECRET") or ""
    dv = ROOT / "worker" / ".dev.vars"
    if not signing and dv.exists():                      # al repetir el asistente se conserva el mismo secreto (las sesiones activas siguen válidas)
        m = re.search(r"^SIGNING_SECRET=(\S+)", dv.read_text(encoding="utf-8"), re.M)
        signing = m.group(1) if m else ""
    signing = signing or secrets.token_hex(32)

    # --- panel: SOLO la anon
    write_env(ROOT / "ui" / ".env", {"VITE_SUPABASE_URL": url, "VITE_SUPABASE_ANON_KEY": anon, "VITE_WORKER_URL": worker or "http://127.0.0.1:8787"}, ROOT / "ui" / ".env.example")
    say(OK, "ui/.env escrito (solo contiene la clave anon)")
    # --- motor
    write_env(ROOT / "engine" / ".env", {"SUPABASE_URL": url, "SUPABASE_SERVICE_KEY": service, "ENGINE_ID": engine_id, "VANTAGE": vantage}, ROOT / "engine" / ".env.example")
    say(OK, "engine/.env escrito")
    # --- worker (desarrollo local) y wrangler.toml
    dev = {"SUPABASE_URL": url, "SUPABASE_ANON_KEY": anon, "SUPABASE_SERVICE_KEY": service, "SIGNING_SECRET": signing}
    if jwt_secret:
        dev["SUPABASE_JWT_SECRET"] = jwt_secret
    write_env(ROOT / "worker" / ".dev.vars", dev)
    say(OK, "worker/.dev.vars escrito (solo para probar el Worker en tu PC)")
    origins = ["http://localhost:5173"] + ([panel] if panel else [])
    set_toml_var(ROOT / "worker" / "wrangler.toml", "ALLOWED_ORIGINS", ",".join(origins))
    say(OK, f"worker/wrangler.toml → ALLOWED_ORIGINS = {','.join(origins)}")

    # --- secretos de Cloudflare
    secrets_for_cf = dict(dev)
    if a.apply_worker:
        print("\n Cargando secretos en Cloudflare (necesitas haber hecho «npx wrangler login»)…")
        npx = "npx.cmd" if os.name == "nt" else "npx"
        for k, v in secrets_for_cf.items():
            r = subprocess.run([npx, "wrangler", "secret", "put", k], cwd=ROOT / "worker", input=v, text=True, capture_output=True)
            say(OK if r.returncode == 0 else BAD, f"secreto {k}" + ("" if r.returncode == 0 else f" — {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'falló'}"))
            if r.returncode != 0:
                print("  Si es la primera vez, ejecuta antes: cd worker && npx wrangler login"); return 1
        print("\n Siguiente: cd worker && npx wrangler deploy")
    else:
        print("\n Para cargar los secretos en Cloudflare, ejecuta (una vez que hayas hecho «npx wrangler login»):")
        print("    python scripts/setup_wizard.py init --apply-worker      (repite las mismas respuestas)")
        print("  o a mano, uno por uno:  cd worker && npx wrangler secret put SUPABASE_URL   (y SUPABASE_ANON_KEY, SUPABASE_SERVICE_KEY, SIGNING_SECRET)")
        print("  Tu SIGNING_SECRET generado está en worker/.dev.vars (úsalo también en Cloudflare para que coincidan).")

    print("\n Hecho. Archivos escritos y protegidos por .gitignore. NUNCA subas ningún .env ni .dev.vars a GitHub.\n")
    return 0


def main():
    p = argparse.ArgumentParser(description="Asistente de configuración de IPTV Engine Pro")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    i = sub.add_parser("init")
    i.add_argument("--apply-worker", action="store_true", help="carga los secretos en Cloudflare con wrangler")
    i.add_argument("--non-interactive", action="store_true", help="lee los datos de variables de entorno")
    a = p.parse_args()
    sys.exit(cmd_check(a) if a.cmd == "check" else cmd_init(a))


if __name__ == "__main__":
    main()
