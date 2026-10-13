\set ON_ERROR_STOP on
\set QUIET on
create schema t; grant usage on schema t to public;
create function t.ok(c boolean, msg text) returns void language plpgsql as $$ begin if c then raise notice '✔ %', msg; else raise exception '✘ %', msg; end if; end $$;
create function t.fails(q text, msg text) returns void language plpgsql as $$
begin
  begin execute q; exception when others then raise notice '✔ % [%]', msg, left(sqlerrm, 55); return; end;
  raise exception '✘ % — NO falló', msg;
end $$;
grant execute on all functions in schema t to public;
\set seed `cat /tmp/seed.json`

insert into auth.users(id, email) values ('aaaaaaaa-0000-0000-0000-000000000001','a@x.com'), ('bbbbbbbb-0000-0000-0000-000000000002','b@x.com');
insert into public.manual_grants(user_id, reason, expires_at) select id, 'smoke', now() + interval '1 day' from auth.users;   -- plan Pro: la prueba importa 190 canales
select id as pla from public.playlists where owner_id = 'aaaaaaaa-0000-0000-0000-000000000001' \gset
select id as plb from public.playlists where owner_id = 'bbbbbbbb-0000-0000-0000-000000000002' \gset
select id as grb from public.groups where playlist_id = :'plb' \gset
select id as outa from public.outputs where playlist_id = :'pla' \gset
select token as toka from public.outputs where playlist_id = :'pla' \gset
select t.ok((select count(*) from public.playlists) = 2 and (select count(*) from public.outputs) = 2, 'alta de usuario: lista + enlace de salida + categoría creados por trigger');

-- ============ usuario A importa su lista real (190 canales)
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select public.bulk_upsert_channels(:'pla', (:'seed'::jsonb)->'items') as imp \gset
select t.ok((:'imp'::jsonb->>'inserted')::int = 190, 'bulk_upsert_channels: 190 canales importados desde tu channels.yaml');
select t.ok((select count(*) from public.groups where playlist_id = :'pla') >= 18, 'categorías creadas automáticamente');
select t.ok((select count(*) from public.v_channels_table where playlist_id = :'pla') = 190 and (select count(*) from public.v_channels_table where health = 'unknown') = 190, 'vista de la tabla: 190 filas, todas "unknown" (sin medir)');
select t.ok((select count(*) from public.channel_sources where playlist_id = :'pla' and kind = 'dailymotion') = 3, 'fuentes Dailymotion detectadas (3)');
select public.bulk_upsert_channels(:'pla', (:'seed'::jsonb)->'items') as imp2 \gset
select t.ok((:'imp2'::jsonb->>'inserted')::int = 0 and (:'imp2'::jsonb->>'updated')::int = 190, 'reimportar = actualiza, no duplica (idempotente)');
select version as v0 from public.playlists where id = :'pla' \gset
select public.bulk_upsert_channels(:'pla', '[{"tvg_id":"x1","name":"Prueba Uno","group":"General","sources":[{"url":"https://a.test/1.m3u8"},{"url":"https://b.test/alt.m3u8"}]}]'::jsonb);
select t.ok((select version from public.playlists where id = :'pla') = :v0 + 1, 'versión de la lista sube exactamente +1 por operación (ETag/caché)');
select t.ok((select count(*) from public.channel_revisions where playlist_id = :'pla' and table_name = 'channels') >= 190, 'auditoría: cada alta queda en channel_revisions');

-- ============ aislamiento entre usuarios (RLS)
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t.ok((select count(*) from public.channels) = 0 and (select count(*) from public.v_channels_table) = 0 and (select count(*) from public.channel_sources) = 0, 'B no ve NINGÚN canal de A (tabla, vista ni fuentes)');
select t.fails(format('insert into public.channels(playlist_id, tvg_id, name) values (%L, ''hack'', ''Hack'')', :'pla'), 'B no puede insertar canales en la lista de A');
update public.channels set name = 'HACK'; select t.ok((select count(*) from public.channels where name = 'HACK') = 0, 'B no puede modificar canales de A (0 filas)');
select t.ok((select count(*) from public.outputs where id = :'outa') = 0 and public.rotate_output_token(:'outa') is null, 'B no ve ni puede rotar el enlace de A');
select t.fails(format('select * from public.request_sync(%L)', :'pla'), 'B no puede pedir sincronización de la lista de A');
select t.fails('insert into public.source_health(source_id, channel_id, playlist_id, owner_id) select id, channel_id, playlist_id, owner_id from public.channel_sources limit 1', 'el cliente no puede escribir salud');

-- ============ A: permisos y validaciones
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.fails('update public.sync_jobs set status = ''succeeded''', 'el cliente no puede tocar sync_jobs directamente');
select t.fails('select public.record_probe(gen_random_uuid(), true)', 'el cliente no puede ejecutar record_probe (solo el motor)');
select t.fails('select public.get_playlist_payload(''x'')', 'el cliente no puede ejecutar get_playlist_payload');
select t.fails(format('insert into public.channels(playlist_id, tvg_id, name, catchup_enabled) values (%L, ''cu'', ''Cu'', true)', :'pla'), 'catchup activado exige tipo (constraint)');
insert into public.channels(playlist_id, owner_id, tvg_id, name) values (:'pla', 'bbbbbbbb-0000-0000-0000-000000000002', 'spoof', 'Spoof');
select t.ok((select owner_id from public.channels where tvg_id = 'spoof') = 'aaaaaaaa-0000-0000-0000-000000000001', 'owner_id enviado por el cliente se IGNORA (se hereda de la lista)');
select t.fails(format('update public.channels set group_id = %L where tvg_id = ''spoof''', :'grb'), 'no se puede usar la categoría de otro usuario');
select t.ok((select count(*) from public.channels where search_text like '%telemicro%') >= 1, 'búsqueda: columna search_text sin acentos');
select t.ok((select count(*) from public.channels where extensions.similarity(search_text, 'telemikro canal') > 0.2) >= 1, 'búsqueda difusa (trigram): "telemikro" encuentra Telemicro');

-- ============ sincronización: dedupe + cola
select * from public.request_sync(:'pla') \gset s1_
select t.ok(not :'s1_deduped'::boolean and :'s1_status' = 'queued', 'Forzar sincronización: crea un trabajo en cola');
select * from public.request_sync(:'pla') \gset s2_
select t.ok(:'s2_deduped'::boolean and :'s2_job_id' = :'s1_job_id', '50 clics seguidos = el MISMO trabajo (deduped)');
reset role;

-- ============ motor (service_role)
set role service_role;
select * from public.claim_job('motor-rd', 'local-rd') \gset c1_
select t.ok(:'c1_status' = 'running' and :'c1_engine_id' = 'motor-rd', 'claim_job: el motor toma el trabajo');
select t.ok((select (public.claim_job('motor-2', 'github')).id is null), 'segundo motor NO recibe el mismo trabajo (SKIP LOCKED)');
select t.ok((select (public.playlist_status(:'pla')->'engine'->>'online')::boolean) is not null, 'playlist_status responde');

select s.id as src_t5, c.id as ch_t5 from public.channel_sources s join public.channels c on c.id = s.channel_id where c.name = 'Telemicro Canal 5' and s.priority = 0 \gset
select (public.record_probe(:'src_t5', true, 200, null, 120, 'local-rd', true, 'https://m.test/master.m3u8', null, null, '{"height":720}'::jsonb, :'c1_id')->>'state') as r1 \gset
select t.ok(:'r1' = 'ok', 'record_probe OK -> estado ok');
select public.record_probe(:'src_t5', false, 404, 'HTTP 404', null, 'local-rd', true, null, null, null, null, :'c1_id')::jsonb as p1 \gset
select t.ok(:'p1'::jsonb->>'state' = 'suspect' and (:'p1'::jsonb->>'strikes')::int = 1 and (:'p1'::jsonb->>'strike_applied')::boolean, 'fallo firme #1 -> strike 1/3 (amarillo)');
select public.record_probe(:'src_t5', false, 404, 'HTTP 404', null, 'local-rd', true)::jsonb as p2 \gset
select t.ok((:'p2'::jsonb->>'strikes')::int = 1 and not (:'p2'::jsonb->>'strike_applied')::boolean, 'segundo fallo INMEDIATO no suma strike (espaciado de 30 min)');
reset role; update public.source_health set last_strike_at = now() - interval '2 hours' where source_id = :'src_t5'; set role service_role;
select public.record_probe(:'src_t5', false, 404, 'HTTP 404')::jsonb as p3 \gset
select t.ok((:'p3'::jsonb->>'strikes')::int = 2 and :'p3'::jsonb->>'state' = 'suspect', 'strike 2/3 tras esperar el espaciado');
reset role; update public.source_health set last_strike_at = now() - interval '2 hours' where source_id = :'src_t5'; set role service_role;
select public.record_probe(:'src_t5', false, 404, 'HTTP 404')::jsonb as p4 \gset
select t.ok((:'p4'::jsonb->>'strikes')::int = 3 and :'p4'::jsonb->>'state' = 'down', 'strike 3/3 -> CAÍDO (rojo)');
select public.record_probe(:'src_t5', false, null, 'ConnectionError', null, 'github', false)::jsonb as p5 \gset
select t.ok(:'p5'::jsonb->>'state' = 'down' and (:'p5'::jsonb->>'strikes')::int = 3, 'fallo BLANDO (otra región) no cambia el estado');
reset role;

set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok((select health from public.v_channels_table where id = :'ch_t5') = 'down', 'semáforo del canal = down (rojo)');
reset role; set role service_role;
select public.record_probe(:'src_t5', true, 200, null, 90, 'local-rd', true, null, null, null, null)::jsonb as p6 \gset
select t.ok(:'p6'::jsonb->>'state' = 'ok' and (:'p6'::jsonb->>'strikes')::int = 0, 'recuperación: vuelve a ok y strikes = 0');
select t.ok((select count(*) from public.engine_logs where message like 'Strike 1/3 aplicado a Telemicro Canal 5%') = 1
        and (select count(*) from public.engine_logs where message like 'Telemicro Canal 5 marcado como CAÍDO%') = 1
        and (select count(*) from public.engine_logs where message = 'Telemicro Canal 5 recuperado') = 1, 'consola: "Strike 1/3 aplicado a Telemicro…", "marcado como CAÍDO", "recuperado"');

-- ============ failover con URL alternativa + payload del Worker
select s.id as xp, c.id as xc from public.channel_sources s join public.channels c on c.id = s.channel_id where c.tvg_id = 'x1' and s.priority = 0 \gset
select s.id as xa from public.channel_sources s join public.channels c on c.id = s.channel_id where c.tvg_id = 'x1' and s.priority = 1 \gset
select public.record_probe(:'xa', true, 200, null, 80, 'local-rd', true) \gset
insert into public.source_health(source_id, channel_id, playlist_id, owner_id, state, strikes) select id, channel_id, playlist_id, owner_id, 'down', 3 from public.channel_sources where id = :'xp' on conflict (source_id) do update set state = 'down', strikes = 3;
select public.get_playlist_payload(:'toka') as payload \gset
select t.ok((select (j->'source'->>'url') from jsonb_array_elements(:'payload'::jsonb->'channels') j where j->>'tvg_id' = 'x1') = 'https://b.test/alt.m3u8', 'payload: principal caída + alterna ok -> el Worker recibe la ALTERNA (failover)');
select t.ok(jsonb_array_length(:'payload'::jsonb->'channels') = 191, 'payload: 190 + x1 = 191 (un canal SIN fuentes no se publica)');
update public.source_health set state = 'down', strikes = 3 where source_id = :'xa';
select public.get_playlist_payload(:'toka') as payload2 \gset
select t.ok((select count(*) from jsonb_array_elements(:'payload2'::jsonb->'channels') j where j->>'tvg_id' = 'x1') = 0, 'payload: todas las fuentes caídas + only_healthy -> el canal se EXCLUYE');
select s.id as src_ctn from public.channel_sources s join public.channels c on c.id = s.channel_id where c.tvg_id = 'ctn35.do' and s.priority = 0 \gset
select public.record_probe(:'src_ctn', true, 200, null, 70, 'local-rd', true, 'https://fresh.test/master.m3u8', 'https://ref.test/', 'UA-SmartTV') \gset
select public.get_playlist_payload(:'toka') as payload3 \gset
select t.ok((select j->'source' from jsonb_array_elements(:'payload3'::jsonb->'channels') j where j->>'tvg_id' = 'ctn35.do') @> '{"url":"https://fresh.test/master.m3u8","kind":"direct","state":"ok","referer":"https://ref.test/","ua":"UA-SmartTV"}'::jsonb, 'payload usa la URL RENOVADA + referer/UA que sí funcionaron (token fresco, master en vez de chunklist)');
select t.ok((select j->'source'->>'url' from jsonb_array_elements(:'payload3'::jsonb->'channels') j where j->>'tvg_id' = 'telemicro5.do') = 'https://live4.telemicro.com.do/live/55/playlist.m3u8', 'sin renovación, usa la URL original');
select t.ok(public.get_playlist_payload('token-invalido') is null, 'token inválido -> null (404 en el Worker)');
select count(*) as n_due from public.due_sources(1000, :'pla', false) \gset
select t.ok(:n_due >= 150, 'due_sources: lista lo que toca verificar (' || :n_due || ')');
select public.finish_job(:'c1_id', 'succeeded', '{"ok":170,"warn":3,"down":17}'::jsonb);
select t.ok((select count(*) from public.engine_logs where message like 'Sincronización terminada%') = 1, 'finish_job deja el log final y republica');
select public.purge_old_data();
reset role;

-- ============ nueva sync tras terminar la anterior; rotación de token; realtime
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select * from public.request_sync(:'pla') \gset s3_
select t.ok(not :'s3_deduped'::boolean and :'s3_job_id' <> :'s1_job_id', 'tras terminar, un nuevo clic crea un trabajo nuevo');
select public.rotate_output_token(:'outa') as newtok \gset
select t.ok(:'newtok' <> :'toka' and length(:'newtok') = 64, 'rotar token genera uno nuevo de 256 bits');
select t.ok(public.playlist_status(:'pla') ? 'counts', 'playlist_status: counts/last_job/engine');
reset role;
select t.ok((select count(*) from pg_publication_tables where pubname = 'supabase_realtime') = 7, 'Realtime: motor (4) + importación masiva y agentes (3) publicadas');

-- ============ intercambiar principal <-> alterna
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select public.set_source_priorities(:'xc', array[:'xa'::uuid, :'xp'::uuid]);
select t.ok((select url from public.channel_sources where channel_id = :'xc' and priority = 0) = 'https://b.test/alt.m3u8'
        and (select url from public.channel_sources where channel_id = :'xc' and priority = 1) = 'https://a.test/1.m3u8', 'set_source_priorities: la alterna pasa a ser principal');
reset role;
\echo
\echo ====== TODAS LAS PRUEBAS PASARON ======
