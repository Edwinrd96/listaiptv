\set ON_ERROR_STOP on
\set QUIET on
create schema t; grant usage on schema t to public;
create function t.ok(c boolean, msg text) returns void language plpgsql as $$ begin if c then raise notice '✔ %', msg; else raise exception '✘ %', msg; end if; end $$;
create function t.fails(q text, msg text) returns void language plpgsql as $$
begin
  begin execute q; exception when others then raise notice '✔ % [%]', msg, left(sqlerrm, 60); return; end;
  raise exception '✘ % — NO falló', msg;
end $$;
grant execute on all functions in schema t to public;

insert into auth.users(id, email) values ('aaaaaaaa-0000-0000-0000-000000000001','a@x.com'), ('bbbbbbbb-0000-0000-0000-000000000002','b@x.com'),
                                         ('cccccccc-0000-0000-0000-000000000003','admin@x.com');
update public.profiles set role = 'admin' where id = 'cccccccc-0000-0000-0000-000000000003';
insert into public.manual_grants(user_id, reason, expires_at) values ('aaaaaaaa-0000-0000-0000-000000000001', 'test pro', now() + interval '30 days');
select id as pla from public.playlists where owner_id = 'aaaaaaaa-0000-0000-0000-000000000001' \gset
select id as plb from public.playlists where owner_id = 'bbbbbbbb-0000-0000-0000-000000000002' \gset
select id as plc from public.playlists where owner_id = 'cccccccc-0000-0000-0000-000000000003' \gset

-- ===================== funciones puras
select t.ok(public.normalize_channel_name('ESPN 2 HD') = 'espn 2' and public.normalize_channel_name('US: Fox Sports (1080p) [Backup]') = 'fox sports'
        and public.normalize_channel_name('Telemicro  FHD') = 'telemicro' and public.normalize_channel_name('CNN en Español 4K') = 'cnn en espanol', 'normalize_channel_name: quita calidad, prefijos y corchetes; conserva el número');
select t.ok(public.detect_quality('ESPN 2 HD') = 'hd' and public.detect_quality('Canal 4K') = '4k' and public.detect_quality('Canal') is null, 'detect_quality');
select t.ok(public.is_shareable_url('https://cdn.example.com/live/espn/index.m3u8')
        and not public.is_shareable_url('http://u:p@host.com/a.m3u8')
        and not public.is_shareable_url('http://prov.com:8080/live/user1/pass1/123.m3u8')
        and not public.is_shareable_url('http://prov.com/get.php?username=a&password=b')
        and not public.is_shareable_url('https://x.com/a.m3u8?token=abc')
        and not public.is_shareable_url('http://192.168.1.10/a.m3u8') and not public.is_shareable_url('http://localhost:8080/a')
        and not public.is_shareable_url('https://x.com/0123456789abcdef0123456789abcdef/a.m3u8'), 'is_shareable_url: público sí; credenciales/token/IP privada no');
select t.ok(public.url_fingerprint('https://a.com/x.m3u8?t=1') = public.url_fingerprint('https://A.com/x.m3u8?t=2'), 'fingerprint ignora query y mayúsculas del host');
select t.ok(public.urlenc('p@ss:w/rd ñ') = 'p%40ss%3Aw%2Frd%20%C3%B1', 'urlenc escapa credenciales de proxy');
select t.ok((select count(*) from public.header_profiles) = 7 and (select count(*) from public.resolvers where capability = 'engine_only') = 1, 'perfiles de cabeceras y resolvedores sembrados');

-- ===================== A (Pro) importa canales: DRM, cabeceras, fallbacks, enlaces públicos/personales
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select public.accept_tos();
update public.profiles set country = 'DO' where id = auth.uid();
select public.bulk_upsert_channels(:'pla', $j$[
 {"tvg_id":"espn2","name":"ESPN 2 HD","group":"Deportes","country":"US","sources":[
    {"url":"https://cdn.test/espn2/index.m3u8","referer":"https://espn.test/","header_profile":"smarttv_tizen"},
    {"url":"https://backup.test/espn2/index.m3u8"}]},
 {"tvg_id":"personal1","name":"Mi canal IPTV","sources":[{"url":"http://prov.test:8080/live/user1/pass1/123.m3u8"}]},
 {"tvg_id":"drm1","name":"Canal DRM","sources":[{"url":"https://drm.test/a.mpd","stream_format":"dash","drm":{"type":"clearkey","keys":"00112233445566778899aabbccddeeff:ffeeddccbbaa99887766554433221100"}}]},
 {"tvg_id":"local1","name":"Telemicro","country":"DO","sources":[{"url":"https://rd.test/telemicro.m3u8","vantage_required":"local-do"}]}
]$j$::jsonb) as imp \gset
select t.ok((:'imp'::jsonb->>'inserted')::int = 4, 'bulk_upsert v2: 4 canales (fallbacks, DRM, vantage_required, header_profile)');
select t.ok((select count(*) from public.channel_sources where channel_id = (select id from public.channels where tvg_id = 'espn2' and playlist_id = :'pla')) = 2, 'ESPN 2 tiene principal + backup (fallback)');
select t.fails(format($q$select public.bulk_upsert_channels(%L, '[{"tvg_id":"bad1","name":"Mal","sources":[{"url":"https://a.test/x.mpd","drm":{"type":"clearkey","keys":"zzz"}}]}]')$q$, :'pla'), 'ClearKey con claves inválidas rechazado');
select t.fails(format($q$select public.bulk_upsert_channels(%L, '[{"tvg_id":"bad2","name":"Mal","sources":[{"url":"https://a.test/x.m3u8","referer":"https://a.test/\nX-Evil: 1"}]}]')$q$, :'pla'), 'salto de línea en Referer rechazado (inyección de cabeceras)');
select t.fails(format($q$select public.bulk_upsert_channels(%L, '[{"tvg_id":"bad3","name":"Mal","sources":[{"url":"https://a.test/x.m3u8","extra_headers":{"Bad Header":"x"}}]}]')$q$, :'pla'), 'extra_headers con nombre inválido rechazado');

-- ===================== contribución automática (enlaces públicos pasan directo; personales/DRM no)
reset role;
select t.ok((select count(*) from public.channel_suggestions where status = 'pending') = 3
        and not exists (select 1 from public.channel_suggestions where url like '%/live/user1%' or url like '%drm.test%'), 'solo 3 enlaces públicos sugeridos; el personal (Xtream) y el DRM NO');
select t.ok((select count(*) from public.suggestion_submitters where user_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 3, 'A figura como aportante de los 3');
-- B no aceptó ToS: no comparte nada
set role authenticated; select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select public.bulk_upsert_channels(:'plb', '[{"tvg_id":"e2","name":"ESPN 2","sources":[{"url":"https://cdn.test/espn2/index.m3u8"}]}]');
reset role;
select t.ok((select count(*) from public.suggestion_submitters where user_id = 'bbbbbbbb-0000-0000-0000-000000000002') = 0, 'sin aceptar ToS no se comparte nada');
set role authenticated; select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select public.accept_tos();
update public.channel_sources set url = 'https://cdn.test/espn2/index.m3u8?x=1' where playlist_id = :'plb';
reset role;
select t.ok((select count(*) from public.suggestion_submitters where user_id = 'bbbbbbbb-0000-0000-0000-000000000002') = 1
        and (select count(*) from public.channel_suggestions where status = 'pending') = 3, 'misma URL de otro usuario = 2.º aportante de la MISMA sugerencia (sin duplicar)');
set role authenticated; select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
update public.profiles set share_contributions = false where id = auth.uid();
select public.bulk_upsert_channels(:'plb', '[{"tvg_id":"cnn","name":"CNN","sources":[{"url":"https://cnn.test/live.m3u8"}]}]');
reset role;
select t.ok(not exists (select 1 from public.channel_suggestions where name = 'CNN'), 'con el interruptor apagado no se comparte');
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok((select count(*) from public.channel_suggestions) = 3, 'A solo ve sus aportes (no ve los de otros)') ;
select t.ok((select count(*) from public.contribution_preview(:'pla') where not shareable) = 2, 'contribution_preview marca 2 canales como personales/no compartibles (Xtream y DRM)');
select public.suggest_channel_meta((select id from public.channels where tvg_id = 'personal1' and playlist_id = :'pla')) as meta \gset
select t.ok(:'meta' is not null and (select url from public.channel_suggestions where id = :'meta') is null, 'enlace personal: se puede sugerir SOLO nombre + logo (sin URL)');

-- ===================== bandeja de aportes: el admin acepta / rechaza
select t.fails($q$select public.admin_accept_suggestion((select id from public.channel_suggestions limit 1))$q$, 'A (no admin) no puede aceptar aportes');
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false);
select id as sug_espn from public.channel_suggestions where url like 'https://cdn.test/espn2%' and status = 'pending' \gset
select public.admin_accept_suggestion(:'sug_espn') as cat_espn \gset
select t.ok((select count(*) from public.catalog_channels where id = :'cat_espn') = 1 and (select count(*) from public.catalog_sources where catalog_id = :'cat_espn') = 1, 'aporte aceptado: nace el canal del catálogo con su fuente');
select id as sug_tm from public.channel_suggestions where name = 'Telemicro' and status = 'pending' \gset
select public.admin_reject_suggestion(:'sug_tm', 'duplicado') ;
select t.ok((select status from public.channel_suggestions where id = :'sug_tm') = 'rejected', 'aporte rechazado');
reset role;
select t.ok((select xp from public.user_stats where user_id = 'aaaaaaaa-0000-0000-0000-000000000001') >= 50
        and (select xp from public.user_stats where user_id = 'bbbbbbbb-0000-0000-0000-000000000002') = 10, 'XP: primer aportante +50, segundo +10');
select t.ok(exists (select 1 from public.user_badges where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and badge_key = 'contributor'), 'insignia Colaborador concedida');
select t.ok((select progress from public.user_missions where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and mission_key = 'contrib_3') = 1, 'misión "3 aportes aceptados" avanza');
-- el enlace rechazado no se vuelve a sugerir
update public.channel_sources set url = 'https://rd.test/telemicro.m3u8' where url = 'https://rd.test/telemicro.m3u8';
select t.ok((select count(*) from public.channel_suggestions where fingerprint = public.url_fingerprint('https://rd.test/telemicro.m3u8') and status = 'pending') = 0, 'un enlace rechazado no vuelve a la bandeja');

-- ===================== catálogo + auto-clasificación
set role authenticated; select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false);
insert into public.catalog_channels(slug, name, country, category, logo_url, epg_id) values
  ('espn-3-us', 'ESPN 3', 'US', 'Deportes', 'https://logos.test/espn3.png', 'ESPN3.us'),
  ('hbo-us', 'HBO', 'US', 'Películas y Series', 'https://logos.test/hbo.png', 'HBO.us');
insert into public.catalog_aliases(catalog_id, alias) select id, 'HBO Latinoamérica' from public.catalog_channels where slug = 'hbo-us';
select t.ok((select name from public.match_catalog('ESPN 2 HD', 'US', 1)) = 'ESPN 2 HD', 'match_catalog: "ESPN 2 HD" -> canal aceptado (nombre exacto normalizado)');
select t.ok((select count(*) from public.match_catalog('ESPN 3 FHD', 'US', 3) where name = 'ESPN 3') = 1, 'match_catalog: ESPN 3 FHD -> ESPN 3');
select t.ok(not exists (select 1 from public.match_catalog('ESPN 4', null, 5) where name in ('ESPN 3','ESPN 2 HD') and score >= 0.8), 'ESPN 4 NO se confunde con ESPN 2/3 (los números cuentan)');
select t.ok((select name from public.match_catalog('HBO LATINOAMERICA FHD', null, 1)) = 'HBO', 'match por alias');
select t.ok(public.guess_category('espn deportes') = 'Deportes' and public.guess_category('cnn noticias') = 'Noticias' and public.guess_category('zzz') is null, 'guess_category por reglas');

-- ===================== importación masiva con enriquecimiento y pruebas en vivo
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select public.create_import_batch(:'pla', $j$[
  {"name":"US: ESPN 3 HD","url":"https://m1.test/espn3.m3u8","group":"Sports"},
  {"name":"ESPN 3 FHD","url":"https://m2.test/espn3.m3u8"},
  {"name":"ESPN 3 SD","url":"https://m3.test/espn3.m3u8"},
  {"name":"HBO LATINOAMERICA HD","url":"https://m4.test/hbo.m3u8"},
  {"name":"Canal Desconocido Noticias","url":"https://m5.test/x.m3u8"},
  {"name":"Sin URL","url":""},
  {"name":"Muerto","url":"https://m6.test/dead.m3u8"}
]$j$::jsonb, 'prueba') as bt \gset
select (:'bt'::jsonb->>'batch_id') as bid \gset
select t.ok((:'bt'::jsonb->>'total')::int = 7 and (select count(*) from public.import_items where batch_id = :'bid' and test_state = 'skipped') = 1, 'lote creado: 7 ítems, 1 descartado por URL inválida');
select t.ok((select enriched->>'name' from public.import_items where batch_id = :'bid' and idx = 1) = 'ESPN 3'
        and (select enriched->>'logo_url' from public.import_items where batch_id = :'bid' and idx = 1) = 'https://logos.test/espn3.png'
        and (select enriched->>'epg_id' from public.import_items where batch_id = :'bid' and idx = 1) = 'ESPN3.us'
        and (select enriched->>'origin' from public.import_items where batch_id = :'bid' and idx = 1) = 'catalog'
        and (select enriched->>'quality' from public.import_items where batch_id = :'bid' and idx = 1) = 'hd', 'enriquecimiento: nombre limpio, logo oficial, EPG ID y calidad detectados');
select t.ok((select enriched->>'group' from public.import_items where batch_id = :'bid' and idx = 5) = 'Noticias' and (select enriched->>'origin' from public.import_items where batch_id = :'bid' and idx = 5) = 'rules', 'canal desconocido: categoría por reglas');
select t.fails($q$select public.claim_import_tests(10)$q$, 'usuarios no pueden reclamar pruebas (solo motores)');
select t.fails(format($q$select public.create_import_batch(%L, (select jsonb_agg(jsonb_build_object('name', 'c' || g, 'url', 'https://a.test/' || g)) from generate_series(1, 5001) g))$q$, :'pla'), 'importar >5000 rechazado (límite del plan Pro)');
reset role;
-- el motor (service_role) prueba el lote
select count(*) as claimed from public.claim_import_tests(50, 'github') \gset
select t.ok(:claimed = 6, 'el motor reclama los 6 ítems probables');
select public.record_import_test(id, idx <> 7, case when idx = 7 then 404 else 200 end, case when idx = 7 then 'HTTP 404' end, 100 * idx) from public.import_items where batch_id = :'bid' and test_state = 'testing';
select t.ok((select status from public.import_batches where id = :'bid') = 'ready', 'al terminar las pruebas el lote pasa a "ready"');
set role authenticated; select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t.ok((select count(*) from public.import_items) = 0, 'B no ve el lote de A');
select t.fails(format($q$select public.commit_import_batch(%L)$q$, :'bid'), 'B no puede importar el lote de A');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select public.import_batch_summary(:'bid') as sm \gset
select t.ok((:'sm'::jsonb#>>'{counts,ok}')::int = 5 and (:'sm'::jsonb#>>'{counts,fail}')::int = 1, 'resumen del lote: 5 ok, 1 fallo');
select public.commit_import_batch(:'bid', true, true) as cm \gset
select t.ok((:'cm'::jsonb->>'channels')::int = 3, 'importados 3 canales (3 ESPN 3 fusionados en 1, HBO, Desconocido; el muerto queda fuera)');
select t.ok((select count(*) from public.channel_sources s join public.channels c on c.id = s.channel_id where c.playlist_id = :'pla' and c.name = 'ESPN 3') = 3, 'las 3 URLs de ESPN 3 se fusionan como fallbacks (principal + 2 alternas)');
select t.ok((select s.url from public.channel_sources s join public.channels c on c.id = s.channel_id where c.playlist_id = :'pla' and c.name = 'ESPN 3' and s.priority = 0) = 'https://m1.test/espn3.m3u8', 'la fuente más rápida queda como principal');
select t.ok((select logo_url from public.channels where playlist_id = :'pla' and name = 'ESPN 3') = 'https://logos.test/espn3.png' and (select epg_id from public.channels where playlist_id = :'pla' and name = 'ESPN 3') = 'ESPN3.us' and (select catalog_id from public.channels where playlist_id = :'pla' and name = 'ESPN 3') is not null, 'canal importado trae logo, EPG y vínculo al catálogo');
select t.fails(format($q$select public.commit_import_batch(%L)$q$, :'bid'), 'un lote no se importa dos veces');
reset role;
select t.ok((select count(*) from public.user_badges where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and badge_key = 'first_import') = 1, 'insignia "Primer paso"');

-- ===================== HOSPITAL DE CANALES
select id as src_hosp from public.channel_sources where url = 'https://backup.test/espn2/index.m3u8' \gset
select channel_id as ch_hosp from public.channel_sources where id = :'src_hosp' \gset
update public.playlists set settings = settings || '{"strike_gap_minutes":0}' where id = :'pla';
select public.record_probe(:'src_hosp', false, 404, 'HTTP 404', 50, 'local-do', true);
select public.record_probe(:'src_hosp', false, 404, 'HTTP 404', 50, 'local-do', true);
select t.ok((select hospital_since from public.source_health where source_id = :'src_hosp') is null, '2 strikes: todavía no está en el Hospital');
select public.record_probe(:'src_hosp', false, 404, 'HTTP 404', 50, 'local-do', true);
select t.ok((select state from public.source_health where source_id = :'src_hosp') = 'down' and (select hospital_since from public.source_health where source_id = :'src_hosp') is not null, '3 strikes -> caído y entra al Hospital (no se borra)');
select t.ok((select days_left from public.v_hospital where source_id = :'src_hosp') = 7 and (select status from public.v_hospital where source_id = :'src_hosp') = 'in_hospital', 'v_hospital: 7 días restantes');
select t.ok((select count(*) from public.channel_sources where id = :'src_hosp') = 1, 'el canal sigue existiendo');
select t.ok(public.hospital_sweep() = 0, 'recién ingresado: hospital_sweep no lo declara muerto');
update public.source_health set hospital_since = now() - interval '8 days' where source_id = :'src_hosp';
select public.hospital_sweep() as swept \gset
select t.ok(:swept = 1 and (select dead_at from public.source_health where source_id = :'src_hosp') is not null, 'tras 7 días sin recuperarse: declarado muerto');
select t.ok((select status from public.v_hospital where source_id = :'src_hosp') = 'dead', 'v_hospital: estado muerto');
select owner_id as hosp_owner from public.channel_sources where id = :'src_hosp' \gset
set role authenticated; select set_config('request.jwt.claim.sub', :'hosp_owner', false);
select t.ok((select count(*) from public.v_hospital where source_id = :'src_hosp') = 1 and (select days_left from public.v_hospital where source_id = :'src_hosp') = 0, 'v_hospital: el DUEÑO la lee con su rol (sin permisos de admin)');
reset role;
select t.ok(not exists (select 1 from public.due_sources(100, :'pla', false) where source_id = :'src_hosp'), 'muerto: no entra en la cola normal (se revisa 1 vez por semana)');
update public.source_health set last_checked_at = now() - interval '8 days' where source_id = :'src_hosp';
select t.ok(exists (select 1 from public.due_sources(100, :'pla', false) where source_id = :'src_hosp'), 'muerto: tras 7 días vuelve a la cola (puede resucitar)');
select public.record_probe(:'src_hosp', true, 200, null, 80, 'local-do', true);
select t.ok((select state from public.source_health where source_id = :'src_hosp') = 'ok' and (select hospital_since from public.source_health where source_id = :'src_hosp') is null and not exists (select 1 from public.v_hospital where source_id = :'src_hosp'), 'recuperado: sale del Hospital');

-- ===================== get_play_candidates + entrega inteligente (fallback sin cortar el reproductor)
select token as toka from public.outputs where playlist_id = :'pla' limit 1 \gset
select public.record_probe(id, false, 404, 'HTTP 404', 40, 'local-do', true) from public.channel_sources where url = 'https://cdn.test/espn2/index.m3u8';
select public.record_probe(id, false, 404, 'HTTP 404', 40, 'local-do', true) from public.channel_sources where url = 'https://cdn.test/espn2/index.m3u8';
select public.record_probe(id, false, 404, 'HTTP 404', 40, 'local-do', true) from public.channel_sources where url = 'https://cdn.test/espn2/index.m3u8';
select public.get_play_candidates(:'toka', 'espn2') as pc \gset
select t.ok(:'pc'::jsonb#>>'{candidates,0,url}' = 'https://backup.test/espn2/index.m3u8' and :'pc'::jsonb#>>'{candidates,1,state}' = 'down', 'candidatos: la alterna sana va PRIMERO; la caída al final');
select t.ok(public.get_play_candidates(:'toka', 'noexiste') is null and public.get_play_candidates('x', 'espn2') is null, 'tvg_id o token inexistente -> null');
update public.source_health set dead_at = now() where source_id = (select id from public.channel_sources where url = 'https://cdn.test/espn2/index.m3u8');
select t.ok(jsonb_array_length(public.get_play_candidates(:'toka', 'espn2')->'candidates') = 1, 'las fuentes muertas se excluyen de los candidatos');
select public.get_playlist_payload(:'toka') as pay \gset
select t.ok((select (c->'source'->'drm'->>'type') from jsonb_array_elements(:'pay'::jsonb->'channels') c where c->>'tvg_id' = 'drm1') = 'clearkey'
        and (select (c->'source'->>'stream_format') from jsonb_array_elements(:'pay'::jsonb->'channels') c where c->>'tvg_id' = 'drm1') = 'dash', 'payload lleva DRM y formato dash');
select t.ok((select (c->>'fallbacks')::int from jsonb_array_elements(:'pay'::jsonb->'channels') c where c->>'tvg_id' = 'espn2') = 1, 'payload informa cuántos fallbacks tiene cada canal');
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
update public.outputs set delivery = 'smart', format = 'txt' where id = (select id from public.outputs where playlist_id = :'pla' limit 1);
select t.ok((select delivery from public.outputs where playlist_id = :'pla' limit 1) = 'smart', 'A (Pro) activa entrega inteligente y formato TXT');
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t.fails(format($q$update public.outputs set delivery = 'smart' where playlist_id = %L$q$, :'plb'), 'B (free) NO puede activar entrega inteligente (función con coste)');
select t.fails($q$select public.get_play_candidates('x','y')$q$, 'get_play_candidates solo para el Worker');

-- ===================== vantage_required (canal local de RD solo lo valida un motor/agente de RD)
reset role;
select t.ok(not exists (select 1 from public.due_sources(100, :'pla', true, 'github') where channel_name = 'Telemicro')
        and exists (select 1 from public.due_sources(100, :'pla', true, 'local-do') where channel_name = 'Telemicro'), 'GitHub NO ve Telemicro; el motor local-do sí');

-- ===================== BYOP: proxies propios
set role authenticated; select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t.fails($q$insert into public.proxies(name, scheme, host, port) values ('Mío', 'socks5', 'p.test', 1080)$q$, 'free: 0 proxies (limit_reached:max_proxies)');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
insert into public.proxies(name, scheme, host, port, username, country) values ('Casa RD', 'socks5', 'rd.proxy.test', 1080, 'usr@x', 'DO') returning id as px_rd \gset
insert into public.proxies(name, scheme, host, port) values ('Canal', 'http', 'ch.proxy.test', 8080) returning id as px_ch \gset
insert into public.proxy_secrets(proxy_id, password) values (:'px_rd', 'p@ss:w/rd');
select t.fails($q$select password from public.proxy_secrets$q$, 'la clave del proxy NO se puede leer desde el navegador');
select t.fails($q$insert into public.proxies(name, scheme, host, port) values ('X', 'ftp', 'h', 1)$q$, 'esquema de proxy inválido rechazado');
insert into public.proxy_assignments(proxy_id, scope, country) values (:'px_rd', 'country', 'DO');
reset role;
select source_id as src_tm from public.due_sources(100, :'pla', true, 'local-do') where channel_name = 'Telemicro' \gset
select t.ok(public.proxy_url_for_source(:'src_tm') = 'socks5://usr%40x:p%40ss%3Aw%2Frd@rd.proxy.test:1080', 'proxy por PAÍS aplicado al canal dominicano (credenciales escapadas)');
select t.ok((select proxy_url from public.due_sources(100, :'pla', true, 'local-do') where channel_name = 'Telemicro') like 'socks5://%', 'due_sources entrega proxy_url al motor');
select t.ok(public.proxy_url_for_source((select id from public.channel_sources where url = 'https://backup.test/espn2/index.m3u8')) is null, 'canal sin país ni asignación: sin proxy');
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
insert into public.proxy_assignments(proxy_id, scope, channel_id) select :'px_ch', 'channel', channel_id from public.channel_sources where id = :'src_tm';
reset role;
select t.ok(public.proxy_url_for_source(:'src_tm') = 'http://ch.proxy.test:8080', 'prioridad: proxy por CANAL gana al de país');
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
insert into public.proxy_assignments(proxy_id, scope, source_id) values (:'px_rd', 'source', :'src_tm');
reset role;
select t.ok(public.proxy_url_for_source(:'src_tm') like 'socks5://%', 'prioridad: proxy por FUENTE gana al de canal');
set role authenticated; select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t.fails(format($q$insert into public.proxy_assignments(proxy_id, scope, source_id) values (%L, 'source', %L)$q$, :'px_rd', :'src_tm'), 'B no puede usar proxy ni fuente de A');
select t.ok((select count(*) from public.proxies) = 0, 'B no ve los proxies de A');
reset role;

-- ===================== BYON: agentes propios
set role authenticated; select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t.fails($q$select public.create_agent('Mi PC', 'DO')$q$, 'free: 0 agentes (limit_reached:max_agents)');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select public.create_agent('PC de casa', 'do') as ag \gset
select (:'ag'::jsonb->>'token') as tok \gset
select t.ok(:'tok' like 'ag\_%' and (select vantage from public.agents where owner_id = auth.uid()) = 'local-do', 'agente creado, vantage local-do');
select t.fails($q$select token_hash from public.agents$q$, 'el hash del token no es legible por el navegador');
reset role;
set role anon;
select public.agent_heartbeat(:'tok', '1.0.0', '{"os":"win"}');
select t.ok((select count(*) from public.agent_due_sources(:'tok', 50, true)) >= 3, 'el agente (rol anon + token) recibe SUS fuentes, incluida la de local-do');
select t.ok(exists (select 1 from public.agent_due_sources(:'tok', 50, true) where channel_name = 'Telemicro' and proxy_url is not null), 'el agente recibe el proxy configurado para su canal');
select t.fails($q$select * from public.agent_due_sources('ag_falso', 10, false)$q$, 'token falso rechazado');
select t.fails($q$select * from public.due_sources(10)$q$, 'anon no puede llamar due_sources (solo service_role)');
select t.fails($q$select * from public.proxy_secrets$q$, 'anon no lee secretos');
reset role;
select public.agent_record_probe(:'tok', :'src_tm', true, 200, null, 90, true) ->> 'state' as st \gset
select t.ok(:'st' = 'ok' and (select vantage from public.source_health where source_id = :'src_tm') = 'local-do', 'agent_record_probe registra la salud con el vantage del agente');
select id as src_b from public.channel_sources where owner_id = 'bbbbbbbb-0000-0000-0000-000000000002' limit 1 \gset
select t.fails(format($q$select public.agent_record_probe(%L, %L, true)$q$, :'tok', :'src_b'), 'el agente no puede escribir salud de fuentes ajenas');
select t.ok((select count(*) from public.engine_heartbeats where engine_id like 'agent:%' and owner_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 1, 'latido del agente registrado');

-- agente: pruebas de importación masiva desde la IP residencial
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select (public.create_import_batch(:'pla', '[{"name":"Uno","url":"https://z1.test/a.m3u8"},{"name":"Dos","url":"https://z2.test/a.m3u8"}]'::jsonb, 'agente')->>'batch_id') as bid2 \gset
reset role; set role anon;
select count(*) as n_claim from public.agent_claim_import_tests(:'tok', 10) \gset
select t.ok(:n_claim = 2, 'el agente reclama las 2 pruebas de SU lote');
reset role;
select public.agent_record_import_test(:'tok', id, true, 200, null, 120) from public.import_items where batch_id = :'bid2';
select t.ok((select status from public.import_batches where id = :'bid2') = 'ready' and (select count(*) from public.import_items where batch_id = :'bid2' and test_vantage = 'local-do') = 2, 'lote probado por el agente (vantage local-do) queda listo');

-- ===================== REPORTES colaborativos
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select id as ch_espn from public.channels where tvg_id = 'espn2' and playlist_id = :'pla' \gset
select public.report_channel(:'ch_espn', 'no_video', 'pantalla negra') as rp \gset
select t.ok(:'rp'::jsonb->>'duplicate' = 'false' and :'rp'::jsonb->>'recheck_queued' = 'true', 'reporte registrado y revisión prioritaria en cola');
select t.ok((public.report_channel(:'ch_espn', 'no_video')) ->> 'duplicate' = 'true', 'mismo reporte el mismo día = duplicado (anti-spam)');
select t.fails($q$select public.report_channel('00000000-0000-0000-0000-000000000000', 'no_video')$q$, 'no se puede reportar un canal inexistente/ajeno');
select t.fails(format($q$select public.report_channel(%L, 'inventado')$q$, :'ch_espn'), 'tipo de reporte inválido rechazado');
reset role;
select t.ok((select count(*) from public.source_health where channel_id = :'ch_espn' and last_checked_at is null) >= 1, 'el reporte pone al canal al frente de la cola del motor');
select t.ok(exists (select 1 from public.xp_events where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and kind = 'report'), 'reportar da XP');
select t.ok((select progress from public.user_missions where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and mission_key = 'report_5') = 1, 'misión de reportes avanza');
select t.ok((select count(*) from public.channel_reports where fingerprint is not null) = 1, 'el reporte guarda la huella de la URL pública (para el catálogo)');

-- ===================== MULTIVISTA
set role authenticated; select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select id as b1 from public.channels where tvg_id = 'e2' and playlist_id = :'plb' \gset
select id as b2 from public.channels where tvg_id = 'cnn' and playlist_id = :'plb' \gset
insert into public.multiview_layouts(name, layout, slots) values ('Mi mosaico', '1x2', jsonb_build_array(jsonb_build_object('channel_id', :'b1'), jsonb_build_object('channel_id', :'b2')));
select t.ok((select count(*) from public.multiview_layouts) = 1, 'free: multivista de 2 canales permitida');
select t.fails(format($q$insert into public.multiview_layouts(name, layout, slots) values ('x', '2x2', jsonb_build_array(jsonb_build_object('channel_id', %L), jsonb_build_object('channel_id', %L), jsonb_build_object('channel_id', %L)))$q$, :'b1', :'b2', :'ch_espn'), 'free: 3 canales rechazados (y uno es ajeno)');
select t.fails(format($q$insert into public.multiview_layouts(name, layout, slots) values ('x', '1x2', jsonb_build_array(jsonb_build_object('channel_id', %L)))$q$, :'ch_espn'), 'multivista con canal ajeno rechazada');
insert into public.user_prefs(data) values ('{"theme":"dark","pip":true}');
select t.ok((select data->>'theme' from public.user_prefs) = 'dark', 'preferencias de usuario guardadas');

-- ===================== UPTIME 90 días y PUNTAJE
select t.ok((select count(*) from public.channel_uptime(:'b1', 90)) = 7, 'free: el historial se recorta a 7 días');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok((select count(*) from public.channel_uptime(:'ch_espn', 90)) = 90 and (select sum(checks) from public.channel_uptime(:'ch_espn', 90)) >= 3, 'Pro: 90 días de heatmap con los chequeos del día');
select t.fails(format($q$select * from public.channel_uptime(%L, 90)$q$, :'b1'), 'no se ve el uptime de canales ajenos');
select public.playlist_score(:'pla') as sc \gset
select t.ok((:'sc'::jsonb->>'score')::int between 0 and 100 and (:'sc'::jsonb->>'channels')::int = 7 and (:'sc'::jsonb->>'fallbacks')::int >= 14, 'puntaje de la lista con desglose (canales, logos, EPG, fallbacks...)');
update public.profiles set handle = 'edwin_rd' where id = auth.uid();
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t.ok((select count(*) from public.v_leaderboard where handle = 'edwin_rd') = 1 and (select count(*) from information_schema.columns where table_name = 'v_leaderboard') = 3, 'ranking público: solo alias, nivel y XP');

-- ===================== permisos: lo sensible NO está al alcance del navegador
select t.fails($q$select public.record_probe(gen_random_uuid(), true)$q$, 'record_probe solo service_role');
select t.fails($q$select public.hospital_sweep()$q$, 'hospital_sweep solo service_role');
select t.fails($q$select public.award_xp(auth.uid(), 'x', 'y', 999999)$q$, 'award_xp solo service_role');
select t.fails($q$select public.record_import_test(1, true)$q$, 'record_import_test solo service_role');
select t.fails($q$select public.accept_suggestion_internal(gen_random_uuid(), null, null)$q$, 'accept_suggestion_internal no expuesta');
select t.fails($q$select * from public.v_report_hotspots$q$, 'hotspots de reportes no visibles para usuarios');
select t.fails($q$insert into public.catalog_channels(slug, name) values ('hack', 'Hack')$q$, 'usuarios no escriben el catálogo');
select t.fails($q$update public.channel_suggestions set status = 'accepted'$q$, 'usuarios no cambian estado de aportes');
reset role;
\echo OK_0004
