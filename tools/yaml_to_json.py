#!/usr/bin/env python3
"""Convierte tu channels.yaml actual al JSON que entiende la función bulk_upsert_channels().
Uso:  python tools/yaml_to_json.py channels.yaml > seed.json
Luego (SQL editor de Supabase, con tu sesión) o desde la UI "Importar":
  select bulk_upsert_channels('<id de tu lista>', (select items from json_populate...))   -- la UI lo hace por ti
"""
import json, re, sys, yaml

def dm_id(url, resolve=""):
    for src in (resolve or "", url or ""):
        m = (re.match(r"dm:(\w+)$", src) or re.search(r"dailymotion\.com/video/(x\w+)", src)
             or re.search(r"dmcdn\.net/.*?/(x[0-9a-z]{4,8})/", src) or re.search(r"cdn/live/video/(x\w+)", src))
        if m:
            return m.group(1)

def convert(path):
    d = yaml.safe_load(open(path, encoding="utf-8"))
    s, items = d["settings"], []
    order = {g: i for i, g in enumerate(s.get("group_order", []))}
    for n, c in enumerate(d["channels"], 1):
        sources = []
        main = {"url": c["url"], "referer": c.get("referer", ""), "ua": c.get("ua", "")}
        vid = dm_id(c["url"], c.get("resolve", ""))
        if vid:
            main.update(kind="dailymotion", resolve_ref=f"dm:{vid}")
        elif c.get("resolve"):
            main.update(kind="youtube", resolve_ref=c["resolve"])
        sources.append(main)
        for a in c.get("alt", []):
            a = {"url": a} if isinstance(a, str) else a
            sources.append({"url": a["url"], "referer": a.get("referer", c.get("referer", "")), "ua": a.get("ua", "")})
        it = {"tvg_id": c["id"], "name": c["name"], "logo_url": c.get("logo", ""), "group": c.get("group", "General"),
              "epg_id": c.get("epg", ""), "chno": c.get("chno"), "language": c.get("lang", ""), "check": c.get("check", True),
              "sort_order": n, "sources": sources}
        if c.get("catchup"):
            it["catchup"] = {"type": c["catchup"], "source": c.get("catchup_source"), "days": c.get("catchup_days")}
        items.append(it)
    settings = {"ua": s["ua"], "encode_headers": s.get("encode_headers", True), "epg_days": s.get("epg_days", 3),
                "strikes_to_down": 3, "strike_gap_minutes": 30, "worker_url": s.get("worker_url", "")}
    groups = sorted({i["group"] for i in items}, key=lambda g: order.get(g, 999))
    epg = [x if isinstance(x, str) else x["url"] for x in s.get("epg_sources", [])]
    ext = [x if isinstance(x, str) else x["url"] for x in s.get("external_lists", [])]
    return {"settings": settings, "groups": groups, "epg_sources": epg, "external_lists": ext, "items": items}

if __name__ == "__main__":
    data = convert(sys.argv[1])
    if "--sql" in sys.argv:      # genera un script listo para pegar en el SQL Editor de Supabase
        body = json.dumps(data["items"], ensure_ascii=False).replace("$json$", "")
        print("-- Importa tus canales en tu primera lista (ejecútalo UNA vez en el SQL Editor de Supabase)")
        print("select public.bulk_upsert_channels((select id from public.playlists order by created_at limit 1), $json$" + body + "$json$::jsonb);")
        print("update public.playlists set settings = settings || $json$" + json.dumps(data["settings"], ensure_ascii=False) + "$json$::jsonb"
              " where id = (select id from public.playlists order by created_at limit 1);")
        for u in data["epg_sources"]:
            print(f"insert into public.epg_sources(playlist_id, url) select id, '{u}' from public.playlists order by created_at limit 1 on conflict do nothing;")
        for u in data["external_lists"]:
            print(f"insert into public.external_lists(playlist_id, url) select id, '{u}' from public.playlists order by created_at limit 1 on conflict do nothing;")
    else:
        json.dump(data, sys.stdout, ensure_ascii=False, indent=1)
