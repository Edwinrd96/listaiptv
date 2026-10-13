"""Pruebas de las herramientas de instalación (asistente y verificador). Uso: python scripts/test_tools.py"""
import base64, hmac, hashlib, json, sys
sys.path.insert(0, __file__.rsplit("/", 1)[0])
import setup_wizard as w, verify_deploy as v

def jwt(c):
    b = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=").decode()
    h, p = b(json.dumps({"alg": "HS256"}).encode()), b(json.dumps(c).encode())
    return f"{h}.{p}.{b(hmac.new(b'x', f'{h}.{p}'.encode(), hashlib.sha256).digest())}"

U = "https://abcd1234.supabase.co"
A, S = jwt({"role": "anon", "ref": "abcd1234"}), jwt({"role": "service_role", "ref": "abcd1234"})
n = 0
def ok(c, m):
    global n; n += 1; assert c, m
def fails(f, *a):
    try: f(*a)
    except ValueError: return True
    return False

w.validate_keys(U, A, S); ok(True, "claves buenas")
ok(fails(w.validate_keys, U, S, A), "intercambiadas")
ok(fails(w.validate_keys, "https://otro9999.supabase.co", A, S), "otro proyecto")
ok(fails(w.validate_keys, U, "sb_publishable_x", S), "clave nueva")
ok(fails(w.validate_keys, U, A, A), "dos anon")
ok(w.validate_url("https://abcd1234.supabase.co/") == U, "recorta /")
ok(fails(w.validate_url, U + "/rest/v1"), "rechaza ruta")
ok(fails(w.validate_url, "abcd1234.supabase.co"), "rechaza sin esquema")
ok(w.project_ref(U) == "abcd1234", "ref")
ok(v.jwt_role(S) == "service_role" and v.jwt_role("basura") == "", "jwt_role")
print(f"{n} comprobaciones de herramientas ✔")
