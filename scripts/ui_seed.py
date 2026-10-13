"""Siembra la base de pruebas con 190 canales y estados de salud variados, y genera un JWT de sesión para el panel."""
import base64, hashlib, hmac, json, subprocess, sys, time, urllib.request
SECRET = b"test-secret-test-secret-test-secret-123456"
U = "aaaaaaaa-0000-0000-0000-00000000a001"
def jwt(c):
    b = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=").decode()
    h, p = b(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()), b(json.dumps(c).encode())
    return f"{h}.{p}.{b(hmac.new(SECRET, f'{h}.{p}'.encode(), hashlib.sha256).digest())}"
def sql(q):
    open("/tmp/ui_seed.sql", "w").write(q)
    r = subprocess.run('su postgres -c "psql -At -q -v ON_ERROR_STOP=1 -d iptvtest -f /tmp/ui_seed.sql"', shell=True, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr; return r.stdout.strip()
sql(f"insert into auth.users(id,email) values ('{U}','edwin@demo.do'); insert into public.manual_grants(user_id,reason,expires_at) values ('{U}','demo', now()+interval '30 days');")
pl = sql(f"select id from public.playlists where owner_id='{U}'")
tok = jwt({"sub": U, "role": "authenticated", "aud": "authenticated", "exp": int(time.time()) + 86400 * 30, "email": "edwin@demo.do"})
seed = json.load(open("/tmp/seed.json"))["items"]
req = urllib.request.Request("http://127.0.0.1:3100/rest/v1/rpc/bulk_upsert_channels", data=json.dumps({"p_playlist": pl, "p_items": seed}).encode(),
                             headers={"Content-Type": "application/json", "apikey": "x", "Authorization": f"Bearer {tok}"})
print(urllib.request.urlopen(req).read().decode())
sql("update public.playlists set settings = settings || '{\"strike_gap_minutes\":0}';")
# estados variados: 70% ok, 8% observación, 7% caído, 10% no verificable, resto sin medir
sql("""
do $$ declare r record; i int := 0; begin
 for r in select id from public.channel_sources where priority = 0 order by id loop
  i := i + 1;
  if i % 10 < 7 then perform public.record_probe(r.id, true, 200, null, 80 + (i*37)%400, 'local-rd', true, null, null, null, jsonb_build_object('height', case when i%3=0 then 1080 when i%3=1 then 720 else 480 end));
  elsif i % 10 = 7 then perform public.record_probe(r.id, false, 404, 'HTTP 404', 90, 'local-rd', true);
  elsif i % 10 = 8 then perform public.record_probe(r.id, false, 404, 'HTTP 404', 90, 'local-rd', true); perform public.record_probe(r.id, false, 404, 'HTTP 404', 90, 'local-rd', true); perform public.record_probe(r.id, false, 404, 'HTTP 404', 90, 'local-rd', true);
  elsif i % 20 = 9 then perform public.record_probe(r.id, false, null, 'Timeout', 5000, 'github', false);
  end if;
 end loop;
end $$;
insert into public.engine_heartbeats(engine_id, vantage, version) values ('demo','local-rd','1.0') on conflict do nothing;
""")
for lvl, msg in [("info", "Auditando 191 fuentes desde «local-rd» (timeout 5 s, rotando 3 User-Agents)"), ("warn", "Strike 2/3 aplicado a Telemicro Canal 5 · HTTP 404"),
                 ("error", "Telesistema Canal 11 marcado como CAÍDO (strike 3/3)"), ("info", "Orbe 21 recuperado"), ("info", "Sincronización terminada · archivo M3U republicado")]:
    sql(f"insert into public.engine_logs(playlist_id, owner_id, level, message) values ('{pl}','{U}','{lvl}',$m${msg}$m$);")
sql(f"insert into public.sync_jobs(playlist_id,owner_id,kind,status,finished_at) values ('{pl}','{U}','full','succeeded', now() - interval '12 minutes');")
json.dump({"token": tok, "user": U, "playlist": pl, "anon": jwt({"role": "anon"})}, open("/tmp/ui_session.json", "w"))
print("sembrado", pl)
