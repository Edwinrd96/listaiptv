import json, sys
from playwright.sync_api import sync_playwright
s = json.load(open("/tmp/ui_session.json"))
session = {"access_token": s["token"], "refresh_token": "x", "token_type": "bearer", "expires_in": 2592000, "expires_at": 4102444800,
           "user": {"id": s["user"], "aud": "authenticated", "role": "authenticated", "email": "edwin@demo.do", "app_metadata": {}, "user_metadata": {}, "created_at": "2026-01-01T00:00:00Z"}}
with sync_playwright() as p:
    b = p.chromium.launch()
    for name, vp in [("desktop", {"width": 1366, "height": 860}), ("mobile", {"width": 390, "height": 800})]:
        ctx = b.new_context(viewport=vp)
        ctx.add_init_script(f"localStorage.setItem('sb-127-auth-token', {json.dumps(json.dumps(session))});")
        pg = ctx.new_page(); errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))
        pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
        pg.goto("http://127.0.0.1:5180/"); pg.wait_for_selector("[role=cell]", timeout=15000); pg.wait_for_timeout(1200)
        pg.screenshot(path=f"/tmp/ui_{name}.png")
        if name == "desktop":
            pg.click("text=Consola"); pg.click("button[title^='Caído']"); pg.wait_for_timeout(500); pg.screenshot(path="/tmp/ui_desktop_filtered.png")
            print("filas tras filtrar caídos:", pg.locator("[role=row]").count() - 1)
        print(name, "errores:", [e for e in errs if "WebSocket" not in e and "realtime" not in e.lower()][:5])
        ctx.close()
    b.close()
