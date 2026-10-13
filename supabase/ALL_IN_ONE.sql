-- IPTV Engine Pro · instalación completa (0001 → 0006) generada por scripts/build_all_sql.sh
-- Pégalo ENTERO en Supabase → SQL Editor → Run, UNA sola vez, en un proyecto NUEVO. Luego ejecuta supabase/check_db.sql.

-- =================================================================== 0001_init.sql
-- =====================================================================================
--  IPTV Engine Pro · 0001_init.sql
--  Postgres estándar + convenciones de Supabase (auth.users, auth.uid(), roles anon /
--  authenticated / service_role).  Multi-tenant desde el día 1: owner_id + RLS en todo.
--  Principio: "motores delgados, base de datos inteligente" -> las reglas de negocio
--  (strikes, selección de URL, dedupe de sync) viven aquí, no en el motor Python ni en el Worker.
-- =====================================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm  with schema extensions;
create extension if not exists unaccent with schema extensions;

-- unaccent() no es IMMUTABLE; este envoltorio permite usarla en columnas generadas / índices.
create or replace function public.f_unaccent(t text) returns text
language sql immutable parallel safe strict set search_path = extensions, public
as $$ select extensions.unaccent('extensions.unaccent', t) $$;

-- ------------------------------------------------------------------ tablas de negocio
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  plan         text not null default 'free' check (plan in ('free','pro','admin')),
  created_at   timestamptz not null default now()
);

create table public.playlists (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references auth.users(id) on delete cascade default auth.uid(),
  name       text not null check (length(name) between 1 and 80),
  -- ua, strikes_to_down(3), strike_gap_minutes(30), epg_days(3), encode_headers(true), worker_url, ...
  settings   jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object'),
  version    bigint not null default 1,                 -- sube con cada cambio publicable (ETag / caché del Worker)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.groups (                             -- "Categoría" del dropdown
  id          uuid primary key default gen_random_uuid(),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  owner_id    uuid not null references auth.users(id) on delete cascade,
  name        text not null check (length(name) between 1 and 80),
  icon        text,
  sort_order  int  not null default 0,
  unique (playlist_id, name)
);

create table public.channels (
  id               uuid primary key default gen_random_uuid(),
  playlist_id      uuid not null references public.playlists(id) on delete cascade,
  owner_id         uuid not null references auth.users(id) on delete cascade,
  tvg_id           text not null check (length(tvg_id) between 1 and 120),   -- id estable que viaja en la M3U
  name             text not null check (length(name) between 1 and 120),
  logo_url         text check (logo_url is null or logo_url ~* '^https?://'),
  logo_status      text not null default 'unknown' check (logo_status in ('unknown','ok','broken','mixed_content')),
  group_id         uuid references public.groups(id) on delete set null,
  epg_id           text,
  chno             int,
  language         text,
  enabled          boolean not null default true,       -- false = fuera de la lista
  check_enabled    boolean not null default true,       -- false = no validar (p. ej. solo visible en RD)
  catchup_enabled  boolean not null default false,
  catchup_type     text check (catchup_type in ('append','default','shift','flussonic','xc')),
  catchup_source   text,
  catchup_days     int  check (catchup_days between 1 and 30),
  sort_order       int  not null default 0,
  notes            text,
  search_text      text generated always as (lower(public.f_unaccent(name || ' ' || tvg_id || ' ' || coalesce(epg_id, '')))) stored,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (playlist_id, tvg_id),
  check (not catchup_enabled or catchup_type is not null)
);
create index channels_playlist_idx on public.channels (playlist_id, sort_order);
create index channels_group_idx    on public.channels (group_id);
create index channels_search_trgm  on public.channels using gin (search_text extensions.gin_trgm_ops);

-- URL principal (priority 0), alternativa (1), ... + cabeceras propias de cada fuente
create table public.channel_sources (
  id          uuid primary key default gen_random_uuid(),
  channel_id  uuid not null references public.channels(id) on delete cascade,
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  owner_id    uuid not null references auth.users(id) on delete cascade,
  priority    smallint not null default 0 check (priority between 0 and 99),
  url         text not null check (url ~* '^https?://'),
  referer     text,
  user_agent  text,
  kind        text not null default 'direct' check (kind in ('direct','dailymotion','youtube')),
  resolve_ref text,                                      -- dm:<id> | https://youtube.com/...
  enabled     boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (channel_id, priority)
);
create index channel_sources_playlist_idx on public.channel_sources (playlist_id);

-- Estado ACTUAL de salud por fuente (lo escribe solo el motor/Worker vía record_probe)
create table public.source_health (
  source_id        uuid primary key references public.channel_sources(id) on delete cascade,
  channel_id       uuid not null references public.channels(id) on delete cascade,
  playlist_id      uuid not null references public.playlists(id) on delete cascade,
  owner_id         uuid not null references auth.users(id) on delete cascade,
  state            text not null default 'unknown' check (state in ('unknown','ok','suspect','down','unverified')),
  strikes          smallint not null default 0,
  last_strike_at   timestamptz,
  last_checked_at  timestamptz,
  last_ok_at       timestamptz,
  last_http        int,
  last_error       text,
  latency_ms       int,
  vantage          text,                                  -- desde dónde se midió: local-rd | github | worker | ...
  resolved_url     text,                                  -- URL fresca (token renovado, master en vez de chunklist)
  resolved_referer text,
  resolved_ua      text,
  quality          jsonb,                                 -- {"height":720,"bandwidth":2500000,"codecs":"avc1..."}
  updated_at       timestamptz not null default now()
);
create index source_health_channel_idx  on public.source_health (channel_id);
create index source_health_playlist_idx on public.source_health (playlist_id, state);

create table public.health_events (                      -- historial corto (sparklines); se purga a los 14 días
  id           bigint generated always as identity primary key,
  source_id    uuid not null references public.channel_sources(id) on delete cascade,
  playlist_id  uuid not null references public.playlists(id) on delete cascade,
  owner_id     uuid not null references auth.users(id) on delete cascade,
  at           timestamptz not null default now(),
  ok           boolean not null,
  http         int,
  error        text,
  latency_ms   int,
  vantage      text,
  strike_applied boolean not null default false
);
create index health_events_source_idx on public.health_events (source_id, at desc);

create table public.sync_jobs (                          -- botón "Forzar sincronización"
  id           uuid primary key default gen_random_uuid(),
  playlist_id  uuid not null references public.playlists(id) on delete cascade,
  owner_id     uuid not null references auth.users(id) on delete cascade,
  kind         text not null default 'full' check (kind in ('full','probe','repair','epg')),
  status       text not null default 'queued' check (status in ('queued','running','succeeded','failed','cancelled')),
  requested_by uuid,
  requested_at timestamptz not null default now(),
  started_at   timestamptz,
  finished_at  timestamptz,
  engine_id    text,
  summary      jsonb,
  error        text
);
-- como máximo UN trabajo activo por (lista, tipo): 50 clics = 1 trabajo
create unique index sync_jobs_one_active on public.sync_jobs (playlist_id, kind) where status in ('queued','running');
create index sync_jobs_queue_idx on public.sync_jobs (status, requested_at);

create table public.engine_heartbeats (                  -- "punto" de estado del motor en la barra superior
  engine_id    text primary key,
  owner_id     uuid references auth.users(id) on delete cascade,   -- null = motor compartido
  vantage      text not null default 'unknown',
  version      text,
  last_seen_at timestamptz not null default now(),
  info         jsonb
);

create table public.engine_logs (                        -- consola inferior (Realtime)
  id          bigint generated always as identity primary key,
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  owner_id    uuid not null references auth.users(id) on delete cascade,
  job_id      uuid references public.sync_jobs(id) on delete set null,
  at          timestamptz not null default now(),
  level       text not null default 'info' check (level in ('debug','info','warn','error')),
  channel_id  uuid references public.channels(id) on delete set null,
  message     text not null,
  data        jsonb
);
create index engine_logs_playlist_idx on public.engine_logs (playlist_id, id desc);

create table public.epg_sources (
  id              uuid primary key default gen_random_uuid(),
  playlist_id     uuid not null references public.playlists(id) on delete cascade,
  owner_id        uuid not null references auth.users(id) on delete cascade,
  url             text not null check (url ~* '^https?://'),
  enabled         boolean not null default true,
  sort_order      int not null default 0,
  last_fetched_at timestamptz,
  last_status     text,
  channel_count   int,
  unique (playlist_id, url)
);
create table public.epg_channels (                       -- índice de la guía para autocompletar "EPG ID"
  source_id    uuid not null references public.epg_sources(id) on delete cascade,
  playlist_id  uuid not null references public.playlists(id) on delete cascade,
  owner_id     uuid not null references auth.users(id) on delete cascade,
  guide_id     text not null,
  display_name text not null,
  primary key (source_id, guide_id)
);
create index epg_channels_trgm on public.epg_channels using gin (lower(public.f_unaccent(display_name)) extensions.gin_trgm_ops);

create table public.external_lists (                     -- listas M3U externas para la auto-reparación de URLs
  id              uuid primary key default gen_random_uuid(),
  playlist_id     uuid not null references public.playlists(id) on delete cascade,
  owner_id        uuid not null references auth.users(id) on delete cascade,
  url             text not null check (url ~* '^https?://'),
  enabled         boolean not null default true,
  last_fetched_at timestamptz,
  channel_count   int,
  unique (playlist_id, url)
);

create table public.outputs (                            -- cada enlace público (token) = un "perfil de salida"
  id           uuid primary key default gen_random_uuid(),
  playlist_id  uuid not null references public.playlists(id) on delete cascade,
  owner_id     uuid not null references auth.users(id) on delete cascade,
  name         text not null default 'Principal',
  token        text not null unique default encode(extensions.gen_random_bytes(32), 'hex'),
  format       text not null default 'm3u' check (format in ('m3u','m3u_vlc')),
  only_healthy boolean not null default true,
  group_ids    uuid[],                                  -- null = todas las categorías
  enabled      boolean not null default true,
  created_at   timestamptz not null default now()
);

create table public.playlist_artifacts (                 -- archivos generados fuera de la BD (epg.xml.gz en R2/Storage)
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  owner_id    uuid not null references auth.users(id) on delete cascade,
  kind        text not null check (kind in ('epg_gz')),
  storage_key text not null,
  bytes       bigint,
  built_at    timestamptz not null default now(),
  meta        jsonb,
  primary key (playlist_id, kind)
);

create table public.notification_targets (               -- Telegram / webhook (los SECRETOS van en variables del motor, no aquí)
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade default auth.uid(),
  playlist_id uuid references public.playlists(id) on delete cascade,
  kind        text not null check (kind in ('telegram','webhook','email')),
  config      jsonb not null default '{}'::jsonb,
  events      text[] not null default '{down,recovered,sync_failed,daily_digest}',
  enabled     boolean not null default true
);

create table public.channel_revisions (                  -- auditoría / "deshacer"
  id          bigint generated always as identity primary key,
  table_name  text not null,
  row_id      uuid not null,
  playlist_id uuid not null,
  owner_id    uuid not null,
  at          timestamptz not null default now(),
  actor       uuid,
  action      text not null check (action in ('insert','update','delete')),
  before      jsonb,
  after       jsonb
);
create index channel_revisions_row_idx on public.channel_revisions (playlist_id, row_id, at desc);

-- ------------------------------------------------------------------ triggers
create or replace function public.tg_set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create trigger set_updated_at before update on public.playlists       for each row execute function public.tg_set_updated_at();
create trigger set_updated_at before update on public.channels        for each row execute function public.tg_set_updated_at();
create trigger set_updated_at before update on public.channel_sources for each row execute function public.tg_set_updated_at();

-- El cliente NUNCA decide owner_id: se hereda del padre (y RLS exige que sea el suyo).
create or replace function public.tg_owner_from_playlist() returns trigger language plpgsql as $$
declare v_owner uuid;
begin
  select owner_id into v_owner from public.playlists where id = new.playlist_id;
  if v_owner is null then
    raise exception 'La lista % no existe o no es tuya', new.playlist_id using errcode = 'foreign_key_violation';
  end if;
  new.owner_id := v_owner;
  return new;
end $$;

create or replace function public.tg_owner_from_channel() returns trigger language plpgsql as $$
begin
  select playlist_id, owner_id into new.playlist_id, new.owner_id from public.channels where id = new.channel_id;
  if new.owner_id is null then
    raise exception 'El canal % no existe o no es tuyo', new.channel_id using errcode = 'foreign_key_violation';
  end if;
  return new;
end $$;

create or replace function public.tg_channel_group_check() returns trigger language plpgsql as $$
begin
  if new.group_id is not null and not exists
     (select 1 from public.groups g where g.id = new.group_id and g.playlist_id = new.playlist_id) then
    raise exception 'La categoría no pertenece a esta lista' using errcode = 'foreign_key_violation';
  end if;
  return new;
end $$;

create trigger owner_from_playlist before insert on public.groups         for each row execute function public.tg_owner_from_playlist();
create trigger owner_from_playlist before insert on public.channels       for each row execute function public.tg_owner_from_playlist();
create trigger owner_from_playlist before insert on public.epg_sources    for each row execute function public.tg_owner_from_playlist();
create trigger owner_from_playlist before insert on public.external_lists for each row execute function public.tg_owner_from_playlist();
create trigger owner_from_playlist before insert on public.outputs        for each row execute function public.tg_owner_from_playlist();
create trigger owner_from_channel  before insert on public.channel_sources for each row execute function public.tg_owner_from_channel();
create trigger group_check before insert or update of group_id on public.channels for each row execute function public.tg_channel_group_check();

-- Sube la versión de la lista UNA vez por transacción (importar 500 canales = 1 bump).
create or replace function public.tg_touch_playlist() returns trigger language plpgsql security definer set search_path = public as $$
declare v_pl uuid;
begin
  v_pl := case when tg_op = 'DELETE' then old.playlist_id else new.playlist_id end;
  update public.playlists set version = version + 1, updated_at = now()
   where id = v_pl and updated_at is distinct from now();
  return null;
end $$;
create trigger touch_playlist after insert or update or delete on public.channels        for each row execute function public.tg_touch_playlist();
create trigger touch_playlist after insert or update or delete on public.channel_sources for each row execute function public.tg_touch_playlist();
create trigger touch_playlist after insert or update or delete on public.groups          for each row execute function public.tg_touch_playlist();
create trigger touch_playlist after insert or update or delete on public.outputs         for each row execute function public.tg_touch_playlist();

create or replace function public.tg_audit() returns trigger language plpgsql security definer set search_path = public as $$
declare r jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  insert into public.channel_revisions(table_name, row_id, playlist_id, owner_id, actor, action, before, after)
  values (tg_table_name, (r->>'id')::uuid, (r->>'playlist_id')::uuid, (r->>'owner_id')::uuid, auth.uid(), lower(tg_op),
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return null;
end $$;
create trigger audit after insert or update or delete on public.channels        for each row execute function public.tg_audit();
create trigger audit after insert or update or delete on public.channel_sources for each row execute function public.tg_audit();

-- Alta de usuario: perfil + primera lista + enlace de salida + categoría por defecto.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
declare v_pl uuid;
begin
  insert into public.profiles(id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(coalesce(new.email, ''), '@', 1)));
  insert into public.playlists(owner_id, name) values (new.id, 'Mi lista') returning id into v_pl;
  insert into public.outputs(playlist_id, name) values (v_pl, 'Principal');
  insert into public.groups(playlist_id, name, sort_order) values (v_pl, 'General', 0);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ------------------------------------------------------------------ vista para la tabla principal
-- Semáforo:  ok (verde) · warn (amarillo: 1-2 strikes, o failover a la alterna) · down (rojo: 3 strikes / todas caídas)
--            unverified (gris: no medible desde el origen) · unknown (sin medir) · unchecked (check_enabled = false)
create or replace view public.v_channels_table with (security_invoker = true) as
select c.id, c.playlist_id, c.tvg_id, c.name, c.logo_url, c.logo_status, c.group_id,
       coalesce(g.name, 'Sin categoría') as group_name,
       c.epg_id, c.chno, c.enabled, c.check_enabled, c.catchup_enabled, c.sort_order,
       a.primary_url, a.alt_url, a.primary_state, coalesce(a.primary_strikes, 0) as strikes,
       coalesce((p.settings->>'strikes_to_down')::int, 3) as strikes_to_down,
       a.latency_ms, a.last_checked_at, a.quality,
       case
         when not c.check_enabled                                                   then 'unchecked'
         when a.n_sources is null or a.n_sources = 0                                then 'unknown'
         when a.primary_state = 'ok'                                                then 'ok'
         when a.all_down                                                            then 'down'
         when a.primary_state = 'suspect' or (a.primary_state = 'down' and a.any_ok) then 'warn'
         when a.primary_state = 'unverified'                                        then 'unverified'
         else 'unknown'
       end as health
from public.channels c
join public.playlists p on p.id = c.playlist_id
left join public.groups g on g.id = c.group_id
left join lateral (
  select count(*)                                           as n_sources,
         max(x.url)             filter (where x.rn = 1)     as primary_url,
         max(x.url)             filter (where x.rn = 2)     as alt_url,
         max(x.state)           filter (where x.rn = 1)     as primary_state,
         max(x.strikes)         filter (where x.rn = 1)     as primary_strikes,
         max(x.latency_ms)      filter (where x.rn = 1)     as latency_ms,
         max(x.last_checked_at) filter (where x.rn = 1)     as last_checked_at,
         (array_agg(x.quality) filter (where x.rn = 1))[1]  as quality,
         coalesce(bool_or(x.state = 'ok'), false)           as any_ok,
         coalesce(bool_and(x.state = 'down'), false)        as all_down
  from (select s.url, coalesce(sh.state, 'unknown') as state, sh.strikes, sh.latency_ms, sh.last_checked_at, sh.quality,
               row_number() over (order by s.priority) as rn
          from public.channel_sources s
          left join public.source_health sh on sh.source_id = s.id
         where s.channel_id = c.id and s.enabled) x
) a on true;

-- ------------------------------------------------------------------ RPC para la UI (security invoker: respetan RLS)
create or replace function public.request_sync(p_playlist uuid, p_kind text default 'full')
returns table (job_id uuid, status text, deduped boolean)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_owner uuid; v_id uuid;
begin
  select owner_id into v_owner from public.playlists where id = p_playlist;
  if v_owner is null or v_owner <> auth.uid() then raise exception 'Lista no encontrada' using errcode = '42501'; end if;
  insert into public.sync_jobs(playlist_id, owner_id, kind, requested_by)
  values (p_playlist, v_owner, p_kind, auth.uid())
  on conflict (playlist_id, kind) where status in ('queued','running') do nothing
  returning id into v_id;
  if v_id is null then
    select j.id, j.status into job_id, status from public.sync_jobs j
     where j.playlist_id = p_playlist and j.kind = p_kind and j.status in ('queued','running') limit 1;
    deduped := true; return next; return;
  end if;
  insert into public.engine_logs(playlist_id, owner_id, job_id, level, message)
  values (p_playlist, v_owner, v_id, 'info', 'Sincronización solicitada (' || p_kind || ')');
  job_id := v_id; status := 'queued'; deduped := false; return next;
end $$;

create or replace function public.bulk_upsert_channels(p_playlist uuid, p_items jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare it jsonb; src jsonb; v_group uuid; v_ch uuid; v_ins boolean; n_ins int := 0; n_upd int := 0; i int; n_src int; ord int := 0;
begin
  for it in select * from jsonb_array_elements(p_items) loop
    ord := ord + 1; v_group := null;
    if nullif(it->>'group', '') is not null then
      insert into public.groups(playlist_id, name) values (p_playlist, it->>'group') on conflict (playlist_id, name) do nothing;
      select id into v_group from public.groups where playlist_id = p_playlist and name = it->>'group';
    end if;
    insert into public.channels(playlist_id, tvg_id, name, logo_url, group_id, epg_id, chno, language, enabled, check_enabled,
                                catchup_enabled, catchup_type, catchup_source, catchup_days, sort_order)
    values (p_playlist, it->>'tvg_id', it->>'name', nullif(it->>'logo_url', ''), v_group, nullif(it->>'epg_id', ''),
            nullif(it->>'chno', '')::int, nullif(it->>'language', ''),
            coalesce((it->>'enabled')::boolean, true), coalesce((it->>'check')::boolean, true),
            it->'catchup' is not null and it->>'catchup' <> 'null',
            it#>>'{catchup,type}', it#>>'{catchup,source}', nullif(it#>>'{catchup,days}', '')::int,
            coalesce((it->>'sort_order')::int, ord))
    on conflict (playlist_id, tvg_id) do update set
      name = excluded.name, logo_url = excluded.logo_url, group_id = excluded.group_id, epg_id = excluded.epg_id,
      chno = excluded.chno, language = excluded.language, enabled = excluded.enabled, check_enabled = excluded.check_enabled,
      catchup_enabled = excluded.catchup_enabled, catchup_type = excluded.catchup_type,
      catchup_source = excluded.catchup_source, catchup_days = excluded.catchup_days, sort_order = excluded.sort_order
    returning id, (xmax = 0) into v_ch, v_ins;
    if v_ins then n_ins := n_ins + 1; else n_upd := n_upd + 1; end if;

    n_src := coalesce(jsonb_array_length(it->'sources'), 0);
    for i in 0 .. n_src - 1 loop
      src := it->'sources'->i;
      insert into public.channel_sources(channel_id, priority, url, referer, user_agent, kind, resolve_ref)
      values (v_ch, i, src->>'url', nullif(src->>'referer', ''), nullif(src->>'ua', ''),
              coalesce(nullif(src->>'kind', ''), 'direct'), nullif(src->>'resolve_ref', ''))
      on conflict (channel_id, priority) do update set
        url = excluded.url, referer = excluded.referer, user_agent = excluded.user_agent,
        kind = excluded.kind, resolve_ref = excluded.resolve_ref;
    end loop;
    delete from public.channel_sources where channel_id = v_ch and priority >= n_src;
  end loop;
  return jsonb_build_object('inserted', n_ins, 'updated', n_upd);
end $$;

create or replace function public.reorder_channels(p_playlist uuid, p_ids uuid[]) returns void
language sql set search_path = public as $$
  update public.channels c set sort_order = x.ord
    from unnest(p_ids) with ordinality as x(id, ord)
   where c.id = x.id and c.playlist_id = p_playlist
$$;

-- Cambia el orden de las URLs de un canal (arrastrar / "usar la alterna como principal")
create or replace function public.set_source_priorities(p_channel uuid, p_ids uuid[]) returns void
language plpgsql set search_path = public as $$
begin
  update public.channel_sources set priority = priority + 50 where channel_id = p_channel;      -- libera el rango
  update public.channel_sources s set priority = (x.ord - 1)::smallint
    from unnest(p_ids) with ordinality as x(id, ord) where s.id = x.id and s.channel_id = p_channel;
  update public.channel_sources set priority = priority - 50 + 10 where channel_id = p_channel and priority >= 50;  -- las no listadas quedan al final
end $$;

create or replace function public.rotate_output_token(p_output uuid) returns text
language sql set search_path = public as $$
  update public.outputs set token = encode(extensions.gen_random_bytes(32), 'hex') where id = p_output returning token
$$;

create or replace function public.search_epg(p_playlist uuid, p_q text, p_limit int default 10)
returns table (guide_id text, display_name text, score real)
language sql stable set search_path = public, extensions as $$
  select e.guide_id, e.display_name, similarity(lower(public.f_unaccent(e.display_name)), lower(public.f_unaccent(p_q)))
    from public.epg_channels e
   where e.playlist_id = p_playlist
     and (lower(public.f_unaccent(e.display_name)) % lower(public.f_unaccent(p_q)) or e.guide_id ilike p_q || '%')
   order by 3 desc limit p_limit
$$;

-- Resumen para la barra superior y el panel (semáforo global, último trabajo, estado del motor)
create or replace function public.playlist_status(p_playlist uuid) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'counts', (select coalesce(jsonb_object_agg(health, n), '{}'::jsonb)
                 from (select health, count(*) n from public.v_channels_table where playlist_id = p_playlist group by 1) q),
    'last_job', (select to_jsonb(j) - 'owner_id' from public.sync_jobs j where j.playlist_id = p_playlist order by requested_at desc limit 1),
    'engine', (select jsonb_build_object('online', coalesce(bool_or(last_seen_at > now() - interval '3 minutes'), false),
                                         'last_seen_at', max(last_seen_at), 'vantage', max(vantage), 'version', max(version))
                 from public.engine_heartbeats))
$$;

-- ------------------------------------------------------------------ RPC del MOTOR / Worker (solo service_role)
create or replace function public.record_probe(
  p_source uuid, p_ok boolean, p_http int default null, p_error text default null, p_latency_ms int default null,
  p_vantage text default 'unknown', p_hard boolean default true,
  p_resolved_url text default null, p_resolved_referer text default null, p_resolved_ua text default null,
  p_quality jsonb default null, p_job uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s record; h public.source_health%rowtype; v_set jsonb;
  v_n int; v_gap interval; v_state text; v_strikes int; v_applied boolean := false; v_changed boolean := false;
begin
  select cs.id, cs.channel_id, cs.playlist_id, cs.owner_id, c.name as channel_name into s
    from public.channel_sources cs join public.channels c on c.id = cs.channel_id where cs.id = p_source;
  if not found then raise exception 'fuente % no existe', p_source; end if;
  select settings into v_set from public.playlists where id = s.playlist_id;
  v_n   := coalesce((v_set->>'strikes_to_down')::int, 3);
  v_gap := make_interval(mins => coalesce((v_set->>'strike_gap_minutes')::int, 30));

  insert into public.source_health(source_id, channel_id, playlist_id, owner_id)
  values (s.id, s.channel_id, s.playlist_id, s.owner_id) on conflict (source_id) do nothing;
  select * into h from public.source_health where source_id = p_source for update;

  if p_ok then
    v_state := 'ok'; v_strikes := 0;
  elsif not p_hard then                                   -- fallo "blando": no prueba nada (otra región, bloqueo de IP...)
    v_state := case when h.state in ('ok','suspect','down') then h.state else 'unverified' end; v_strikes := h.strikes;
  else                                                    -- fallo firme (404/410/manifiesto inválido medido desde un origen válido)
    if h.last_strike_at is null or now() - h.last_strike_at >= v_gap then
      v_strikes := h.strikes + 1; v_applied := true;      -- los strikes se ESPACIAN: 3 clics seguidos no matan un canal
    else
      v_strikes := h.strikes;
    end if;
    v_state := case when v_strikes >= v_n then 'down' when v_strikes >= 1 then 'suspect' else h.state end;
  end if;

  update public.source_health set
    state = v_state, strikes = v_strikes,
    last_strike_at   = case when v_applied then now() when p_ok then null else last_strike_at end,
    last_checked_at  = now(),
    last_ok_at       = case when p_ok then now() else last_ok_at end,
    last_http        = p_http,
    last_error       = case when p_ok then null else left(p_error, 300) end,
    latency_ms       = p_latency_ms, vantage = p_vantage,
    resolved_url     = case when p_ok then p_resolved_url     else resolved_url end,
    resolved_referer = case when p_ok then p_resolved_referer else resolved_referer end,
    resolved_ua      = case when p_ok then p_resolved_ua      else resolved_ua end,
    quality          = case when p_ok then coalesce(p_quality, quality) else quality end,
    updated_at       = now()
  where source_id = p_source;

  insert into public.health_events(source_id, playlist_id, owner_id, ok, http, error, latency_ms, vantage, strike_applied)
  values (s.id, s.playlist_id, s.owner_id, p_ok, p_http, left(p_error, 300), p_latency_ms, p_vantage, v_applied);

  if v_applied then
    insert into public.engine_logs(playlist_id, owner_id, job_id, level, channel_id, message)
    values (s.playlist_id, s.owner_id, p_job, case when v_state = 'down' then 'error' else 'warn' end, s.channel_id,
            case when v_state = 'down' then s.channel_name || ' marcado como CAÍDO (strike ' || v_strikes || '/' || v_n || ')'
                 else 'Strike ' || v_strikes || '/' || v_n || ' aplicado a ' || s.channel_name end
            || coalesce(' · ' || left(p_error, 80), ''));
  elsif p_ok and h.state in ('suspect','down') then
    insert into public.engine_logs(playlist_id, owner_id, job_id, level, channel_id, message)
    values (s.playlist_id, s.owner_id, p_job, 'info', s.channel_id, s.channel_name || ' recuperado');
  end if;

  v_changed := h.state is distinct from v_state or (p_ok and h.resolved_url is distinct from p_resolved_url);
  if v_changed then
    update public.playlists set version = version + 1, updated_at = now() where id = s.playlist_id and updated_at is distinct from now();
  end if;
  return jsonb_build_object('state', v_state, 'strikes', v_strikes, 'strike_applied', v_applied,
                            'changed', v_changed, 'strikes_to_down', v_n);
end $$;

create or replace function public.due_sources(p_limit int default 200, p_playlist uuid default null, p_force boolean default false)
returns table (source_id uuid, channel_id uuid, playlist_id uuid, channel_name text, priority smallint, url text, referer text,
               user_agent text, kind text, resolve_ref text, state text, strikes smallint, default_ua text)
language sql stable security definer set search_path = public as $$
  select cs.id, c.id, c.playlist_id, c.name, cs.priority, cs.url, cs.referer, cs.user_agent, cs.kind, cs.resolve_ref,
         coalesce(sh.state, 'unknown'), coalesce(sh.strikes, 0)::smallint, p.settings->>'ua'
    from public.channel_sources cs
    join public.channels c  on c.id = cs.channel_id and c.enabled and c.check_enabled
    join public.playlists p on p.id = c.playlist_id
    left join public.source_health sh on sh.source_id = cs.id
   where cs.enabled and (p_playlist is null or c.playlist_id = p_playlist)
     and (p_force or sh.last_checked_at is null or sh.last_checked_at < now() - case coalesce(sh.state, 'unknown')
            when 'ok' then interval '3 hours' when 'suspect' then interval '30 minutes'
            when 'down' then interval '6 hours' else interval '1 hour' end)
   order by sh.last_checked_at nulls first
   limit p_limit
$$;

create or replace function public.claim_job(p_engine text, p_vantage text default 'unknown') returns public.sync_jobs
language plpgsql security definer set search_path = public as $$
declare j public.sync_jobs;
begin
  insert into public.engine_heartbeats(engine_id, vantage) values (p_engine, p_vantage)
  on conflict (engine_id) do update set last_seen_at = now(), vantage = excluded.vantage;
  update public.sync_jobs set status = 'running', started_at = now(), engine_id = p_engine
   where id = (select id from public.sync_jobs where status = 'queued' order by requested_at for update skip locked limit 1)
  returning * into j;
  if j.id is not null then
    insert into public.engine_logs(playlist_id, owner_id, job_id, message) values (j.playlist_id, j.owner_id, j.id, 'Motor ' || p_engine || ' tomó el trabajo');
  end if;
  return j;
end $$;

create or replace function public.finish_job(p_job uuid, p_status text, p_summary jsonb default null, p_error text default null) returns void
language plpgsql security definer set search_path = public as $$
declare j public.sync_jobs;
begin
  update public.sync_jobs set status = p_status, finished_at = now(), summary = p_summary, error = p_error
   where id = p_job returning * into j;
  if j.id is null then return; end if;
  update public.playlists set version = version + 1, updated_at = now() where id = j.playlist_id and updated_at is distinct from now();
  insert into public.engine_logs(playlist_id, owner_id, job_id, level, message, data)
  values (j.playlist_id, j.owner_id, j.id, case when p_status = 'succeeded' then 'info' else 'error' end,
          case when p_status = 'succeeded' then 'Sincronización terminada · archivo M3U republicado' else 'Sincronización fallida' end
          || coalesce(' · ' || p_error, ''), p_summary);
end $$;

create or replace function public.engine_log(p_playlist uuid, p_level text, p_message text, p_job uuid default null,
                                             p_channel uuid default null, p_data jsonb default null) returns void
language sql security definer set search_path = public as $$
  insert into public.engine_logs(playlist_id, owner_id, job_id, level, channel_id, message, data)
  select p.id, p.owner_id, p_job, p_level, p_channel, left(p_message, 500), p_data from public.playlists p where p.id = p_playlist
$$;

create or replace function public.engine_heartbeat(p_engine text, p_vantage text default 'unknown', p_version text default null, p_info jsonb default null) returns void
language sql security definer set search_path = public as $$
  insert into public.engine_heartbeats(engine_id, vantage, version, info) values (p_engine, p_vantage, p_version, p_info)
  on conflict (engine_id) do update set last_seen_at = now(), vantage = excluded.vantage, version = excluded.version, info = excluded.info
$$;

-- Lo que consume el Worker para armar la M3U: por canal elige la MEJOR fuente
-- (ok primero, evita las caídas, luego prioridad) y respeta el filtro del enlace de salida.
create or replace function public.get_playlist_payload(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.outputs; pl public.playlists; result jsonb;
begin
  select * into o from public.outputs where token = p_token and enabled;
  if not found then return null; end if;
  select * into pl from public.playlists where id = o.playlist_id;
  select jsonb_build_object(
           'playlist', jsonb_build_object('id', pl.id, 'name', pl.name, 'version', pl.version, 'settings', pl.settings),
           'output',   jsonb_build_object('id', o.id, 'format', o.format, 'only_healthy', o.only_healthy),
           'channels', coalesce(jsonb_agg(q.j order by q.gsort, q.chno nulls last, q.sort_order), '[]'::jsonb))
    into result
    from (
      select jsonb_build_object(
               'tvg_id', c.tvg_id, 'name', c.name, 'logo', c.logo_url, 'group', coalesce(g.name, 'Sin categoría'),
               'epg_id', c.epg_id, 'chno', c.chno, 'lang', c.language,
               'catchup', case when c.catchup_enabled then jsonb_build_object('type', c.catchup_type, 'source', c.catchup_source, 'days', c.catchup_days) end,
               'source', jsonb_build_object('url', coalesce(sel.resolved_url, sel.url), 'referer', coalesce(sel.resolved_referer, sel.referer),
                                            'ua', coalesce(sel.resolved_ua, sel.user_agent), 'kind', sel.kind,
                                            'resolve_ref', sel.resolve_ref, 'state', sel.state)) as j,
             coalesce(g.sort_order, 9999) as gsort, c.chno, c.sort_order
        from public.channels c
        left join public.groups g on g.id = c.group_id
        join lateral (
          select s.url, s.referer, s.user_agent, s.kind, s.resolve_ref, coalesce(sh.state, 'unknown') as state,
                 sh.resolved_url, sh.resolved_referer, sh.resolved_ua
            from public.channel_sources s left join public.source_health sh on sh.source_id = s.id
           where s.channel_id = c.id and s.enabled
           order by (coalesce(sh.state, 'unknown') = 'ok') desc, (coalesce(sh.state, 'unknown') = 'down') asc, s.priority asc
           limit 1) sel on true
       where c.playlist_id = o.playlist_id and c.enabled
         and (o.group_ids is null or c.group_id = any(o.group_ids))
         and (not o.only_healthy or sel.state <> 'down')) q;
  return result;
end $$;

create or replace function public.purge_old_data() returns void
language sql security definer set search_path = public as $$
  delete from public.engine_logs        where at < now() - interval '7 days';
  delete from public.health_events      where at < now() - interval '14 days';
  delete from public.channel_revisions  where at < now() - interval '90 days';
  delete from public.sync_jobs          where finished_at < now() - interval '30 days';
$$;

-- ------------------------------------------------------------------ RLS
do $$
declare t text;
begin
  foreach t in array array['playlists','groups','channels','channel_sources','epg_sources','external_lists','outputs','notification_targets'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy owner_all on public.%I for all to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()))', t);
  end loop;
  foreach t in array array['source_health','health_events','sync_jobs','engine_logs','epg_channels','playlist_artifacts','channel_revisions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy owner_read on public.%I for select to authenticated using (owner_id = (select auth.uid()))', t);
  end loop;
end $$;
alter table public.profiles enable row level security;
create policy own_profile on public.profiles for all to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
alter table public.engine_heartbeats enable row level security;
create policy see_engines on public.engine_heartbeats for select to authenticated using (owner_id is null or owner_id = (select auth.uid()));

-- ------------------------------------------------------------------ permisos explícitos (lista blanca)
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
grant usage on schema public to anon, authenticated, service_role;
grant usage on schema extensions to anon, authenticated, service_role;   -- f_unaccent / trigram lo necesitan al insertar y buscar

grant select, insert, update, delete on public.profiles, public.playlists, public.groups, public.channels, public.channel_sources,
      public.epg_sources, public.external_lists, public.outputs, public.notification_targets to authenticated;
grant select on public.source_health, public.health_events, public.sync_jobs, public.engine_logs, public.epg_channels,
      public.playlist_artifacts, public.channel_revisions, public.engine_heartbeats, public.v_channels_table to authenticated;
grant execute on function public.request_sync(uuid, text), public.bulk_upsert_channels(uuid, jsonb), public.reorder_channels(uuid, uuid[]),
      public.rotate_output_token(uuid), public.set_source_priorities(uuid, uuid[]), public.search_epg(uuid, text, int), public.playlist_status(uuid), public.f_unaccent(text) to authenticated;
grant all on all tables in schema public to service_role;
grant execute on all functions in schema public to service_role;

-- ------------------------------------------------------------------ Realtime (solo si existe la publicación de Supabase)
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['engine_logs','source_health','sync_jobs','engine_heartbeats'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- =================================================================== 0002_worker_helpers.sql
-- 0002 · Funciones de apoyo para el Worker y el motor (solo service_role)

-- El Worker resuelve el archivo EPG de un enlace público sin cargar toda la lista.
create or replace function public.get_output_artifact(p_token text, p_kind text default 'epg_gz') returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(a) - 'owner_id'
    from public.playlist_artifacts a
    join public.outputs o on o.playlist_id = a.playlist_id
   where o.token = p_token and o.enabled and a.kind = p_kind
$$;

-- El motor registra dónde dejó el epg.xml.gz (R2 / Storage).
create or replace function public.register_artifact(p_playlist uuid, p_kind text, p_key text, p_bytes bigint default null, p_meta jsonb default null) returns void
language sql security definer set search_path = public as $$
  insert into public.playlist_artifacts(playlist_id, owner_id, kind, storage_key, bytes, meta)
  select p.id, p.owner_id, p_kind, p_key, p_bytes, p_meta from public.playlists p where p.id = p_playlist
  on conflict (playlist_id, kind) do update set storage_key = excluded.storage_key, bytes = excluded.bytes, built_at = now(), meta = excluded.meta
$$;

revoke all on function public.get_output_artifact(text, text), public.register_artifact(uuid, text, text, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.get_output_artifact(text, text), public.register_artifact(uuid, text, text, bigint, jsonb) to service_role;

-- =================================================================== 0003_saas_core.sql
-- =====================================================================================
--  IPTV Engine Pro · 0003_saas_core.sql
--  Núcleo SaaS: roles, planes, feature flags, entitlements, límites, XP/niveles, facturación
--  (INACTIVA por defecto: billing_mode = 'off'), promos, Founder plan, auditoría de admin.
--  Todo el dinero se maneja fuera (Merchant of Record + webhooks firmados); aquí solo viven
--  los EVENTOS ya verificados por el Worker (idempotentes).
-- =====================================================================================

-- ------------------------------------------------------------------ profiles: roles y consentimiento
alter table public.profiles
  add column role                  text    not null default 'user' check (role in ('user','admin')),
  add column handle                text    check (handle is null or handle ~ '^[a-z0-9_]{3,24}$'),
  add column country               text    check (country is null or country ~ '^[A-Z]{2}$'),
  add column share_contributions   boolean not null default true,   -- enlaces PÚBLICOS pasan directo al catálogo (consentido en ToS)
  add column tos_version           text,
  add column tos_accepted_at       timestamptz,
  add column grandfathered_until   timestamptz,                      -- Founder: Pro gratis hasta esta fecha
  add column founder_discount_pct  int     not null default 0 check (founder_discount_pct between 0 and 100);
create unique index profiles_handle_uq on public.profiles (lower(handle)) where handle is not null;

-- El cliente NUNCA puede escalar privilegios: solo columnas "seguras" son editables.
revoke insert, update, delete on public.profiles from authenticated;
grant update (display_name, handle, country, share_contributions) on public.profiles to authenticated;
drop policy own_profile on public.profiles;
create policy own_profile_select on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy own_profile_update on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

alter table public.playlists add column is_master boolean not null default false;   -- la lista "maestra" del admin (fuente del catálogo)
create unique index playlists_one_master on public.playlists (is_master) where is_master;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' from public.profiles where id = auth.uid()), false)
$$;

-- ------------------------------------------------------------------ configuración global (la controla SOLO el admin)
create table public.app_settings (
  key        text primary key,
  value      jsonb not null,
  note       text,
  updated_at timestamptz not null default now()
);
insert into public.app_settings(key, value, note) values
  ('billing_mode',         '"off"',   'off = nadie paga, flags "open" abiertas · preview = muestra planes sin cobrar · live = cobros activos'),
  ('billing_provider',     '"none"',  'lemonsqueezy | paddle | none'),
  ('founder_months',       '6',       'Meses de Pro gratis para quienes ya existen cuando se activa el cobro'),
  ('founder_discount_pct', '20',      'Descuento de por vida para esos usuarios'),
  ('founder_granted_at',   'null',    'Se rellena una sola vez al activar el cobro'),
  ('grace_days',           '7',       'Días de gracia tras un pago fallido'),
  ('hospital_days',        '7',       'Días que un canal caído permanece en el Hospital antes de declararse muerto'),
  ('tos_version',          '"2026-10"','Versión vigente de los Términos'),
  ('auto_accept_votes',    '0',       'Si > 0, una sugerencia con N aportantes distintos y fuente sana se acepta sola (0 = siempre revisión manual)');

create table public.admin_audit (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor      uuid,
  action     text not null,
  target     text,
  detail     jsonb
);

create or replace function public.admin_audit_log(p_action text, p_target text, p_detail jsonb default null) returns void
language sql security definer set search_path = public as $$
  insert into public.admin_audit(actor, action, target, detail) values (auth.uid(), p_action, p_target, p_detail)
$$;

create or replace function public.setting_json(p_key text) returns jsonb
language sql stable security definer set search_path = public as $$ select value from public.app_settings where key = p_key $$;
create or replace function public.setting_int(p_key text, p_default int) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select case when jsonb_typeof(value) = 'number' then (value #>> '{}')::int end from public.app_settings where key = p_key), p_default)
$$;
create or replace function public.billing_mode() returns text
language sql stable security definer set search_path = public as $$ select coalesce(public.setting_json('billing_mode') #>> '{}', 'off') $$;

create or replace function public.admin_set_setting(p_key text, p_value jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'solo admin' using errcode = '42501'; end if;
  if p_key = 'billing_mode' then
    if p_value #>> '{}' not in ('off','preview') then raise exception 'usa admin_activate_billing() para pasar a live'; end if;
  end if;
  update public.app_settings set value = p_value, updated_at = now() where key = p_key;
  if not found then raise exception 'ajuste desconocido: %', p_key; end if;
  perform public.admin_audit_log('set_setting', p_key, p_value);
end $$;

-- ------------------------------------------------------------------ planes, niveles
create table public.plans (
  key           text primary key,
  name          text not null,
  price_monthly integer,            -- en centavos de USD
  price_yearly  integer,
  active        boolean not null default false,   -- los planes de pago NO están a la venta todavía
  provider_ref  jsonb
);
insert into public.plans(key, name, price_monthly, price_yearly, active) values
  ('free', 'Gratis', 0, 0, true),
  ('pro',  'Pro', 499, 3990, false);

create table public.levels (
  level    int primary key,
  name     text not null,
  min_xp   int not null unique,
  perks_text text
);
insert into public.levels(level, name, min_xp, perks_text) values
  (1,'Novato',0,'Acceso básico'), (2,'Explorador',100,'+50 canales'), (3,'Colaborador',300,'2.ª lista y más enlaces'),
  (4,'Curador',800,'Multivista de 4, modo auditoría y formatos extra'), (5,'Guardián',2000,'Chequeo cada 60 min'),
  (6,'Maestro',5000,'2 alternas más por canal'), (7,'Leyenda',12000,'Insignia y votos de peso en el catálogo');

create table public.seasons (
  id        int generated always as identity primary key,
  name      text not null,
  starts_at timestamptz not null,
  ends_at   timestamptz not null check (ends_at > starts_at)
);

create table public.user_stats (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  xp        int not null default 0 check (xp >= 0),
  level     int not null default 1 references public.levels(level),
  updated_at timestamptz not null default now()
);

create table public.xp_events (
  id        bigint generated always as identity primary key,
  user_id   uuid not null references auth.users(id) on delete cascade,
  kind      text not null,
  ref       text not null,                 -- idempotencia: el mismo (usuario, tipo, ref) solo cuenta una vez
  xp        int not null,
  season_id int references public.seasons(id),
  at        timestamptz not null default now(),
  unique (user_id, kind, ref)
);

create or replace function public.level_for_xp(p_xp int) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(max(level), 1) from public.levels where min_xp <= p_xp
$$;

-- Única vía para dar XP (service_role / otras funciones). Idempotente.
create or replace function public.award_xp(p_user uuid, p_kind text, p_ref text, p_xp int) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_new boolean; v_season int;
begin
  select id into v_season from public.seasons where now() between starts_at and ends_at order by starts_at desc limit 1;
  insert into public.xp_events(user_id, kind, ref, xp, season_id) values (p_user, p_kind, p_ref, p_xp, v_season)
  on conflict (user_id, kind, ref) do nothing;
  get diagnostics v_new = row_count;
  if not v_new then return false; end if;
  insert into public.user_stats(user_id, xp, level) values (p_user, greatest(p_xp, 0), public.level_for_xp(greatest(p_xp, 0)))
  on conflict (user_id) do update
     set xp = greatest(public.user_stats.xp + p_xp, 0),
         level = public.level_for_xp(greatest(public.user_stats.xp + p_xp, 0)),
         updated_at = now();
  return true;
end $$;

-- ------------------------------------------------------------------ feature flags (el admin las mueve cuando quiera)
create table public.feature_flags (
  key                    text primary key,
  description            text,
  free_value             jsonb not null,
  pro_value              jsonb not null,
  lower_is_better        boolean not null default false,        -- p. ej. minutos entre chequeos
  open_during_free_phase boolean not null default false,        -- true = todos disfrutan el valor Pro mientras billing_mode <> 'live'
  cost_sensitive         boolean not null default false         -- cuesta dinero real al operador: NUNCA se abre gratis
);
insert into public.feature_flags(key, description, free_value, pro_value, lower_is_better, open_during_free_phase, cost_sensitive) values
  ('max_channels',           'Canales por usuario',                          '250',  '5000', false, false, false),
  ('max_playlists',          'Listas por usuario',                           '1',    '10',   false, false, false),
  ('max_outputs',            'Enlaces de salida (tokens)',                   '2',    '20',   false, false, false),
  ('max_alternates',         'URLs alternas por canal (fallbacks)',          '1',    '5',    false, false, false),
  ('check_interval_minutes', 'Minutos mínimos entre chequeos de un canal ok','180',  '10',   true,  false, true),
  ('history_days',           'Días de historial de salud',                   '7',    '365',  false, false, false),
  ('import_batch_max',       'Canales por importación masiva',               '300',  '5000', false, false, false),
  ('max_proxies',            'Proxies propios (BYOP)',                       '0',    '10',   false, false, true),
  ('max_agents',             'Agentes locales propios (BYON)',               '0',    '5',    false, false, true),
  ('multiview_slots',        'Canales simultáneos en Multivista',            '2',    '4',    false, false, false),
  ('smart_delivery',         'Entrega inteligente (Worker redirige al backup)','false','true', false, false, true),
  ('hospital',               'Hospital de canales (cuarentena de 7 días)',   'false','true', false, true,  false),
  ('import_enrichment',      'Auto-clasificación al importar',               'false','true', false, true,  false),
  ('ai_enrichment',          'Clasificación con IA (opcional)',              'false','true', false, false, true),
  ('drm_fields',             'Campos DRM (Widevine/ClearKey)',               'false','true', false, true,  false),
  ('catalog_follow',         'Añadir canales del catálogo compartido',       'false','true', false, true,  false),
  ('alerts_advanced',        'Alertas avanzadas',                            'false','true', false, false, false),
  ('api_access',             'Acceso por API',                               'false','true', false, false, true),
  ('export_formats_extra',   'Exportar TXT / Enigma2 / VLC',                 'false','true', false, true,  false),
  ('audit_mode',             'Modo auditoría',                               'false','true', false, true,  false),
  ('backups_daily',          'Copias diarias',                               'false','true', false, false, true);

create table public.level_perks (
  level int not null references public.levels(level),
  key   text not null references public.feature_flags(key),
  value jsonb not null,
  primary key (level, key)
);
insert into public.level_perks(level, key, value) values
  (2,'max_channels','300'), (3,'max_playlists','2'), (3,'max_outputs','5'),
  (4,'multiview_slots','4'), (4,'audit_mode','true'), (4,'export_formats_extra','true'),
  (5,'check_interval_minutes','60'), (6,'max_alternates','2');

create or replace function public.merge_feature(a jsonb, b jsonb, p_lower boolean) returns jsonb
language sql immutable as $$
  select case
    when a is null then b when b is null then a
    when jsonb_typeof(a) = 'number' and jsonb_typeof(b) = 'number'
      then case when p_lower then to_jsonb(least((a #>> '{}')::numeric, (b #>> '{}')::numeric))
                else to_jsonb(greatest((a #>> '{}')::numeric, (b #>> '{}')::numeric)) end
    when jsonb_typeof(a) = 'boolean' and jsonb_typeof(b) = 'boolean' then to_jsonb((a #>> '{}')::boolean or (b #>> '{}')::boolean)
    else b end
$$;

-- ------------------------------------------------------------------ facturación (inactiva mientras billing_mode = 'off')
create table public.subscriptions (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  provider           text not null,
  provider_sub_id    text not null,
  plan_key           text not null references public.plans(key),
  status             text not null check (status in ('active','trialing','past_due','canceled','expired')),
  interval           text check (interval in ('month','year')),
  current_period_end timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (provider, provider_sub_id)
);
create index subscriptions_user_idx on public.subscriptions (user_id);

create table public.billing_events (
  id           bigint generated always as identity primary key,
  provider     text not null,
  event_id     text not null,
  type         text not null,
  payload      jsonb,
  received_at  timestamptz not null default now(),
  unique (provider, event_id)                     -- reintentos del webhook = no-op
);

create table public.manual_grants (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  granted_by uuid,
  reason     text,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index manual_grants_user_idx on public.manual_grants (user_id, expires_at);

create table public.promo_codes (
  code       text primary key check (code = upper(code)),
  grant_days int not null check (grant_days between 1 and 3650),
  max_uses   int,
  uses       int not null default 0,
  expires_at timestamptz,
  active     boolean not null default true
);
create table public.promo_redemptions (
  code    text not null references public.promo_codes(code),
  user_id uuid not null references auth.users(id) on delete cascade,
  at      timestamptz not null default now(),
  primary key (code, user_id)
);

-- ¿Está viva una suscripción? (con días de gracia y "cancelada pero pagada hasta el fin del periodo")
create or replace function public.sub_is_live(p_status text, p_end timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when p_status in ('active','trialing') then p_end is null or p_end + make_interval(days => public.setting_int('grace_days', 7)) > now()
    when p_status = 'past_due'             then p_end is not null and p_end + make_interval(days => public.setting_int('grace_days', 7)) > now()
    when p_status = 'canceled'             then p_end is not null and p_end > now()
    else false end
$$;

create or replace function public.effective_plan(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when
       coalesce((select role = 'admin' or grandfathered_until > now() from public.profiles where id = p_user), false)
    or exists (select 1 from public.manual_grants g where g.user_id = p_user and g.expires_at > now())
    or exists (select 1 from public.subscriptions s where s.user_id = p_user and s.plan_key = 'pro' and public.sub_is_live(s.status, s.current_period_end))
  then 'pro' else 'free' end
$$;

-- ------------------------------------------------------------------ entitlements
create or replace function public.entitlements_for(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f record; v jsonb; res jsonb := '{}'::jsonb; v_plan text := public.effective_plan(p_user); v_bm text := public.billing_mode();
        v_lvl int := coalesce((select level from public.user_stats where user_id = p_user), 1); perk record;
begin
  for f in select * from public.feature_flags loop
    v := case when v_plan = 'pro' or (f.open_during_free_phase and not f.cost_sensitive and v_bm <> 'live')
              then f.pro_value else f.free_value end;
    for perk in select value from public.level_perks where key = f.key and level <= v_lvl loop
      v := public.merge_feature(v, perk.value, f.lower_is_better);
    end loop;
    res := res || jsonb_build_object(f.key, v);
  end loop;
  return res;
end $$;

create or replace function public.limit_of(p_user uuid, p_key text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((public.entitlements_for(p_user) ->> p_key)::numeric::int, 0)
$$;
create or replace function public.has_feature(p_user uuid, p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((public.entitlements_for(p_user) ->> p_key)::boolean, false)
$$;

create or replace function public.my_entitlements() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_u uuid := auth.uid(); s public.user_stats; nxt record;
begin
  if v_u is null then raise exception 'no autenticado' using errcode = '42501'; end if;
  select * into s from public.user_stats where user_id = v_u;
  select level, name, min_xp into nxt from public.levels where min_xp > coalesce(s.xp, 0) order by min_xp limit 1;
  return jsonb_build_object(
    'plan', public.effective_plan(v_u), 'billing_mode', public.billing_mode(),
    'level', coalesce(s.level, 1), 'xp', coalesce(s.xp, 0),
    'next_level', case when nxt.level is not null then jsonb_build_object('level', nxt.level, 'name', nxt.name, 'xp_needed', nxt.min_xp) end,
    'features', public.entitlements_for(v_u),
    'founder', (select jsonb_build_object('until', grandfathered_until, 'discount_pct', founder_discount_pct)
                  from public.profiles where id = v_u and (grandfathered_until is not null or founder_discount_pct > 0)));
end $$;

-- ------------------------------------------------------------------ límites aplicados EN LA BASE (la UI solo los muestra)
create or replace function public.enforce_limit(p_owner uuid, p_key text, p_count int) returns void
language plpgsql stable security definer set search_path = public as $$
declare v_lim int;
begin
  if exists (select 1 from public.profiles where id = p_owner and role = 'admin') then return; end if;
  v_lim := public.limit_of(p_owner, p_key);
  if p_count > v_lim then
    raise exception 'limit_reached:% (máximo % en tu plan)', p_key, v_lim using errcode = '53400';
  end if;
end $$;

create or replace function public.tg_limit_playlists() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.enforce_limit(new.owner_id, 'max_playlists', (select count(*) from public.playlists where owner_id = new.owner_id)::int + 1);
  return new;
end $$;
create or replace function public.tg_limit_outputs() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.enforce_limit(new.owner_id, 'max_outputs', (select count(*) from public.outputs where owner_id = new.owner_id)::int + 1);
  return new;
end $$;
create or replace function public.tg_limit_channels() returns trigger language plpgsql security definer set search_path = public as $$
declare o record;
begin
  for o in select distinct owner_id from new_rows loop
    perform public.enforce_limit(o.owner_id, 'max_channels', (select count(*) from public.channels where owner_id = o.owner_id)::int);
  end loop;
  return null;
end $$;
create or replace function public.tg_limit_sources() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.enforce_limit(new.owner_id, 'max_alternates',
          (select count(*) from public.channel_sources where channel_id = new.channel_id)::int);   -- 1 principal + N alternas
  return new;
end $$;

create index if not exists channels_owner_idx on public.channels (owner_id);
create index if not exists outputs_owner_idx  on public.outputs (owner_id);
create trigger zz_limit before insert on public.playlists for each row execute function public.tg_limit_playlists();
create trigger zz_limit before insert on public.outputs   for each row execute function public.tg_limit_outputs();
create trigger zz_limit after  insert on public.channels  referencing new table as new_rows for each statement execute function public.tg_limit_channels();
create trigger zz_limit before insert on public.channel_sources for each row execute function public.tg_limit_sources();

-- ------------------------------------------------------------------ acciones del usuario
create or replace function public.accept_tos(p_version text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set tos_version = coalesce(p_version, public.setting_json('tos_version') #>> '{}'), tos_accepted_at = now()
   where id = auth.uid();
end $$;

create or replace function public.redeem_promo(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pc public.promo_codes; v_exp timestamptz;
begin
  if auth.uid() is null then raise exception 'no autenticado' using errcode = '42501'; end if;
  select * into pc from public.promo_codes where code = upper(trim(p_code)) for update;
  if not found or not pc.active or (pc.expires_at is not null and pc.expires_at < now())
     or (pc.max_uses is not null and pc.uses >= pc.max_uses) then
    raise exception 'código inválido o agotado' using errcode = 'P0001';
  end if;
  insert into public.promo_redemptions(code, user_id) values (pc.code, auth.uid());   -- 2.º canje = unique violation
  update public.promo_codes set uses = uses + 1 where code = pc.code;
  v_exp := greatest(now(), coalesce((select max(expires_at) from public.manual_grants where user_id = auth.uid()), now())) + make_interval(days => pc.grant_days);
  insert into public.manual_grants(user_id, reason, expires_at) values (auth.uid(), 'promo:' || pc.code, v_exp);
  return jsonb_build_object('pro_until', v_exp);
end $$;

-- ------------------------------------------------------------------ acciones del admin
create or replace function public.admin_grant_plan(p_user uuid, p_days int, p_reason text default null) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare v_exp timestamptz;
begin
  if not public.is_admin() then raise exception 'solo admin' using errcode = '42501'; end if;
  v_exp := now() + make_interval(days => p_days);
  insert into public.manual_grants(user_id, granted_by, reason, expires_at) values (p_user, auth.uid(), p_reason, v_exp);
  perform public.admin_audit_log('grant_plan', p_user::text, jsonb_build_object('days', p_days, 'reason', p_reason));
  return v_exp;
end $$;

create or replace function public.admin_set_flag(p_key text, p_free jsonb default null, p_pro jsonb default null, p_open boolean default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'solo admin' using errcode = '42501'; end if;
  update public.feature_flags set free_value = coalesce(p_free, free_value), pro_value = coalesce(p_pro, pro_value),
         open_during_free_phase = coalesce(p_open, open_during_free_phase) where key = p_key;
  if not found then raise exception 'flag desconocida: %', p_key; end if;
  perform public.admin_audit_log('set_flag', p_key, jsonb_build_object('free', p_free, 'pro', p_pro, 'open', p_open));
end $$;

-- Pasar a COBRO REAL: acción explícita. La 1.ª vez concede el plan Founder a todos los usuarios existentes.
create or replace function public.admin_activate_billing() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int := 0; v_first boolean;
begin
  if not public.is_admin() then raise exception 'solo admin' using errcode = '42501'; end if;
  if (public.setting_json('billing_provider') #>> '{}') = 'none' then
    raise exception 'configura billing_provider antes de activar el cobro';
  end if;
  v_first := public.setting_json('founder_granted_at') = 'null'::jsonb;
  if v_first then
    update public.profiles set grandfathered_until = now() + make_interval(months => public.setting_int('founder_months', 6)),
           founder_discount_pct = public.setting_int('founder_discount_pct', 20)
     where role <> 'admin';
    get diagnostics v_n = row_count;
    update public.app_settings set value = to_jsonb(now()), updated_at = now() where key = 'founder_granted_at';
  end if;
  update public.app_settings set value = '"live"', updated_at = now() where key = 'billing_mode';
  update public.plans set active = true where key = 'pro';
  perform public.admin_audit_log('activate_billing', null, jsonb_build_object('founders', v_n));
  return jsonb_build_object('billing_mode', 'live', 'founders_granted', v_n);
end $$;

-- Evento ya VERIFICADO por el Worker (firma del proveedor comprobada allí). Idempotente.
create or replace function public.apply_subscription_event(
  p_provider text, p_event_id text, p_type text, p_user uuid, p_sub_id text,
  p_status text, p_period_end timestamptz, p_interval text default 'month', p_payload jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_new boolean;
begin
  insert into public.billing_events(provider, event_id, type, payload) values (p_provider, p_event_id, p_type, p_payload)
  on conflict (provider, event_id) do nothing;
  get diagnostics v_new = row_count;
  if not v_new then return jsonb_build_object('duplicate', true); end if;
  insert into public.subscriptions(user_id, provider, provider_sub_id, plan_key, status, interval, current_period_end)
  values (p_user, p_provider, p_sub_id, 'pro', p_status, p_interval, p_period_end)
  on conflict (provider, provider_sub_id) do update
     set status = excluded.status, current_period_end = excluded.current_period_end, interval = excluded.interval, updated_at = now();
  return jsonb_build_object('duplicate', false, 'plan', public.effective_plan(p_user));
end $$;

-- ------------------------------------------------------------------ RLS y permisos
alter table public.app_settings      enable row level security;
alter table public.admin_audit       enable row level security;
alter table public.plans             enable row level security;
alter table public.levels            enable row level security;
alter table public.seasons           enable row level security;
alter table public.feature_flags     enable row level security;
alter table public.level_perks       enable row level security;
alter table public.user_stats        enable row level security;
alter table public.xp_events         enable row level security;
alter table public.subscriptions     enable row level security;
alter table public.billing_events    enable row level security;
alter table public.manual_grants     enable row level security;
alter table public.promo_codes       enable row level security;
alter table public.promo_redemptions enable row level security;

create policy read_all   on public.plans         for select to authenticated using (true);
create policy read_all   on public.levels        for select to authenticated using (true);
create policy read_all   on public.seasons       for select to authenticated using (true);
create policy read_all   on public.feature_flags for select to authenticated using (true);
create policy read_all   on public.level_perks   for select to authenticated using (true);
create policy read_own   on public.user_stats    for select to authenticated using (user_id = (select auth.uid()));
create policy read_own   on public.xp_events     for select to authenticated using (user_id = (select auth.uid()));
create policy read_own   on public.subscriptions for select to authenticated using (user_id = (select auth.uid()));
create policy read_own   on public.manual_grants for select to authenticated using (user_id = (select auth.uid()));
create policy read_own   on public.promo_redemptions for select to authenticated using (user_id = (select auth.uid()));
create policy admin_read on public.admin_audit   for select to authenticated using (public.is_admin());
create policy admin_read on public.billing_events for select to authenticated using (public.is_admin());
create policy admin_all  on public.promo_codes   for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_read on public.app_settings  for select to authenticated using (public.is_admin() or key in ('billing_mode','tos_version','founder_months','founder_discount_pct','hospital_days'));

grant select on public.plans, public.levels, public.seasons, public.feature_flags, public.level_perks, public.user_stats, public.xp_events,
      public.subscriptions, public.manual_grants, public.promo_redemptions, public.app_settings, public.admin_audit, public.billing_events to authenticated;
grant select, insert, update, delete on public.promo_codes to authenticated;      -- RLS: solo admin
-- Todo lo demás (apply_subscription_event, award_xp, entitlements_for, limit_of, has_feature...) queda SOLO para service_role / triggers.
-- Postgres da EXECUTE a PUBLIC por defecto a cada función nueva: se quita en bloque y se vuelven a conceder las de la API del usuario.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.request_sync(uuid, text), public.bulk_upsert_channels(uuid, jsonb), public.reorder_channels(uuid, uuid[]),
      public.rotate_output_token(uuid), public.set_source_priorities(uuid, uuid[]), public.search_epg(uuid, text, int), public.playlist_status(uuid),
      public.f_unaccent(text), public.is_admin(), public.billing_mode(), public.my_entitlements(), public.accept_tos(text), public.redeem_promo(text),
      public.admin_set_setting(text, jsonb), public.admin_grant_plan(uuid, int, text), public.admin_set_flag(text, jsonb, jsonb, boolean),
      public.admin_activate_billing() to authenticated;
grant execute on all functions in schema public to service_role;

-- =================================================================== 0004_features.sql
-- =====================================================================================
--  IPTV Engine Pro · 0004_features.sql
--  Hospital de canales · BYON (agentes propios) · BYOP (proxies) · DRM · fallbacks · entrega inteligente
--  · auto-clasificación e importación masiva con pruebas en vivo · reportes · catálogo compartido
--  y bandeja de aportes · multivista · uptime 90 días · puntaje de lista · insignias y misiones.
--  Sin dependencias de proveedor: Postgres + convenciones Supabase (auth.uid(), roles).
-- =====================================================================================

-- ------------------------------------------------------------------ helpers puros
create or replace function public.normalize_channel_name(t text) returns text
language sql immutable parallel safe set search_path = extensions, public as $$
  select btrim(regexp_replace(
           regexp_replace(
             regexp_replace(
               regexp_replace(lower(public.f_unaccent(coalesce(t, ''))), '[\[\(\{][^\]\)\}]*[\]\)\}]', ' ', 'g'),
               '^\s*[a-z]{2,3}\s*[:|]\s*', ''),
             '\m(fhd|uhd|hd|sd|4k|8k|hevc|h265|h264|1080p|1080i|720p|576p|480p|50fps|60fps|multi|vip|premium|backup)\M', ' ', 'g'),
           '[^a-z0-9]+', ' ', 'g'))
$$;

create or replace function public.detect_quality(t text) returns text
language sql immutable parallel safe as $$
  select case when lower(coalesce(t,'')) ~ '\m(4k|uhd|2160p)\M' then '4k'
              when lower(coalesce(t,'')) ~ '\m(fhd|1080p|1080i)\M' then 'fhd'
              when lower(coalesce(t,'')) ~ '\m(hd|720p)\M' then 'hd'
              when lower(coalesce(t,'')) ~ '\m(sd|480p|576p)\M' then 'sd' end
$$;

-- ¿Se puede compartir este enlace en el catálogo público? Falso si lleva credenciales/tokens/IP privada.
create or replace function public.is_shareable_url(p_url text) returns boolean
language sql immutable parallel safe as $$
  select p_url ~* '^https?://'
     and p_url !~* '^https?://[^/]*@'                                                   -- user:pass@host
     and p_url !~* '[?&;](username|user|password|pass|pwd|token|auth|sig|signature|expires|exp|hdnts|hdntl|st|e|key|apikey|api_key|access_token|session|sid)='
     and p_url !~* '/(live|movie|series|streaming)/[^/?]+/[^/?]+/[0-9]+'                -- patrón Xtream: /live/usuario/clave/123
     and p_url !~* '/[0-9a-f]{32,}(/|\.|$)'                                             -- segmento largo hex = token personal
     and p_url !~* '^https?://(localhost|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|0\.)'
     and p_url !~* '^https?://[^/:]*\.(local|lan|internal|home)(:|/|$)'
$$;

create or replace function public.url_fingerprint(p_url text) returns text
language sql immutable parallel safe set search_path = extensions, public as $$
  select encode(extensions.digest(lower(regexp_replace(split_part(p_url, '?', 1), '/+$', '')), 'sha256'), 'hex')
$$;

create or replace function public.urlenc(t text) returns text
language plpgsql immutable as $$
declare ch text; r text := '';
begin
  foreach ch in array regexp_split_to_array(coalesce(t, ''), '') loop
    if ch ~ '[A-Za-z0-9._~-]' then r := r || ch;
    else r := r || regexp_replace(upper(encode(convert_to(ch, 'utf8'), 'hex')), '(..)', '%\1', 'g'); end if;
  end loop;
  return r;
end $$;

-- ------------------------------------------------------------------ catálogos técnicos: perfiles de cabeceras y resolvedores
create table public.header_profiles (
  key        text primary key,
  label      text not null,
  user_agent text not null,
  headers    jsonb not null default '{}'::jsonb,       -- conjunto COHERENTE con ese user agent
  builtin    boolean not null default true
);
insert into public.header_profiles(key, label, user_agent, headers) values
 ('smarttv_tizen',  'Samsung Tizen',   'Mozilla/5.0 (SMART-TV; LINUX; Tizen 7.0) AppleWebKit/537.36 (KHTML, like Gecko) 94.0.4606.31/7.0 TV Safari/537.36',
   '{"Accept":"*/*","Accept-Language":"es-DO,es;q=0.9,en;q=0.8","Connection":"keep-alive"}'),
 ('smarttv_webos',  'LG webOS',        'Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.88 Safari/537.36 WebAppManager',
   '{"Accept":"*/*","Accept-Language":"es-DO,es;q=0.9,en;q=0.8","Connection":"keep-alive"}'),
 ('smarttv_bravia', 'Sony BRAVIA',     'Mozilla/5.0 (Linux; Android 9; BRAVIA 4K GB Build/PTT1.190515.001.S38) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
   '{"Accept":"*/*","Accept-Language":"es-DO,es;q=0.9,en;q=0.8","Connection":"keep-alive"}'),
 ('chrome_win',     'Chrome Windows',  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
   '{"Accept":"*/*","Accept-Language":"es-DO,es;q=0.9,en;q=0.8","sec-ch-ua":"\"Chromium\";v=\"126\", \"Not.A/Brand\";v=\"24\", \"Google Chrome\";v=\"126\"","sec-ch-ua-mobile":"?0","sec-ch-ua-platform":"\"Windows\"","Sec-Fetch-Dest":"empty","Sec-Fetch-Mode":"cors","Sec-Fetch-Site":"cross-site"}'),
 ('vlc',            'VLC',             'VLC/3.0.20 LibVLC/3.0.20', '{}'),
 ('kodi',           'Kodi',            'Kodi/21.0 (Linux; Android 11) Version/21.0', '{"Accept":"*/*"}'),
 ('tivimate',       'TiviMate',        'TiviMate/5.0.1 (Android 11)', '{"Accept":"*/*"}');

create table public.resolvers (
  key         text primary key,
  capability  text not null check (capability in ('redirect','proxy_required','engine_only')),
  enabled     boolean not null default true,
  description text
);
insert into public.resolvers(key, capability, enabled, description) values
 ('direct',        'redirect',       true,  'La URL se entrega tal cual'),
 ('dailymotion',   'redirect',       true,  'Token fresco de Dailymotion (caché de 3 min en el Worker)'),
 ('youtube',       'engine_only',    true,  'Solo el motor puede obtener la URL fresca (YouTube liga el token a la IP)'),
 ('generic',       'redirect',       true,  'Extractor genérico: busca el .m3u8 dentro de la página'),
 ('azteca_akamai', 'proxy_required', false, 'Reservado: orígenes Akamai con firma por IP');

-- ------------------------------------------------------------------ canales / fuentes: campos nuevos
alter table public.channels
  add column country    text check (country is null or country ~ '^[A-Z]{2}$'),
  add column catalog_id uuid;                                      -- FK se añade tras crear catalog_channels

alter table public.channel_sources
  add column stream_format    text not null default 'auto' check (stream_format in ('auto','hls','dash','mp4','ts')),
  add column drm              jsonb check (drm is null or (jsonb_typeof(drm) = 'object' and drm->>'type' in ('clearkey','widevine','playready'))),
  add column country          text check (country is null or country ~ '^[A-Z]{2}$'),
  add column vantage_required text,                                -- p. ej. 'local-rd': solo un motor/agente de ese origen valida esta fuente
  add column header_profile   text references public.header_profiles(key),
  add column extra_headers    jsonb check (extra_headers is null or (jsonb_typeof(extra_headers) = 'object' and length(extra_headers::text) < 2048)),
  add column resolver         text references public.resolvers(key),
  add constraint channel_sources_no_ctl check (coalesce(referer, '') !~ '[\r\n]' and coalesce(user_agent, '') !~ '[\r\n]' and url !~ '[\r\n ]');

alter table public.outputs
  add column delivery text not null default 'direct' check (delivery in ('direct','smart'));
alter table public.outputs drop constraint outputs_format_check;
alter table public.outputs add constraint outputs_format_check check (format in ('m3u','m3u_vlc','txt','enigma2'));

-- Reglas por fuente: DRM validado y reservado a quien tenga la función; cabeceras sin saltos de línea
create or replace function public.tg_source_rules() returns trigger language plpgsql security definer set search_path = public as $$
declare k text; v jsonb;
begin
  if new.drm is not null then
    if not public.has_feature(new.owner_id, 'drm_fields') and not exists (select 1 from public.profiles where id = new.owner_id and role = 'admin') then
      raise exception 'limit_reached:drm_fields (función no disponible en tu plan)' using errcode = '53400';
    end if;
    if new.drm->>'type' = 'clearkey' and coalesce(new.drm->>'keys', '') !~ '^[0-9a-fA-F]{32}:[0-9a-fA-F]{32}(,[0-9a-fA-F]{32}:[0-9a-fA-F]{32})*$'
       and coalesce(new.drm->>'license_url', '') !~* '^https?://' then
      raise exception 'ClearKey requiere keys "kid:key" (32 hex cada uno) o license_url';
    end if;
    if new.drm->>'type' in ('widevine','playready') and coalesce(new.drm->>'license_url', '') !~* '^https?://' then
      raise exception '% requiere license_url http(s)', new.drm->>'type';
    end if;
  end if;
  if new.extra_headers is not null then
    for k, v in select * from jsonb_each(new.extra_headers) loop
      if k !~ '^[A-Za-z0-9-]{1,40}$' or jsonb_typeof(v) <> 'string' or (v #>> '{}') ~ '[\r\n]' then
        raise exception 'cabecera inválida: %', k;
      end if;
    end loop;
  end if;
  return new;
end $$;
create trigger source_rules before insert or update on public.channel_sources for each row execute function public.tg_source_rules();

create or replace function public.tg_output_rules() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.delivery = 'smart' and not public.has_feature(new.owner_id, 'smart_delivery')
     and not exists (select 1 from public.profiles where id = new.owner_id and role = 'admin') then
    raise exception 'limit_reached:smart_delivery (función no disponible en tu plan)' using errcode = '53400';
  end if;
  if new.format in ('txt','enigma2') and not public.has_feature(new.owner_id, 'export_formats_extra')
     and not exists (select 1 from public.profiles where id = new.owner_id and role = 'admin') then
    raise exception 'limit_reached:export_formats_extra (función no disponible en tu plan)' using errcode = '53400';
  end if;
  return new;
end $$;
create trigger output_rules before insert or update on public.outputs for each row execute function public.tg_output_rules();

-- ------------------------------------------------------------------ HOSPITAL DE CANALES
alter table public.source_health
  add column hospital_since timestamptz,
  add column dead_at        timestamptz;

create or replace function public.tg_hospital() returns trigger language plpgsql as $$
begin
  if new.state = 'down' then
    if tg_op = 'INSERT' then new.hospital_since := now(); new.dead_at := null;
    elsif old.state is distinct from 'down' then new.hospital_since := now(); new.dead_at := null; end if;
  else
    new.hospital_since := null; new.dead_at := null;           -- cualquier otro estado = alta médica
  end if;
  return new;
end $$;
create trigger hospital before insert or update of state on public.source_health for each row execute function public.tg_hospital();

-- Declara "muertas" las fuentes que llevan más de hospital_days caídas (no se borran: solo se sondean muy de vez en cuando)
create or replace function public.hospital_sweep() returns int
language plpgsql security definer set search_path = public as $$
declare n int; r record;
begin
  for r in
    with dead as (
      update public.source_health sh set dead_at = now()
       where sh.state = 'down' and sh.dead_at is null
         and sh.hospital_since < now() - make_interval(days => public.setting_int('hospital_days', 7))
         and public.has_feature(sh.owner_id, 'hospital')
      returning sh.playlist_id, sh.owner_id)
    select playlist_id, owner_id, count(*) c from dead group by 1, 2
  loop
    insert into public.engine_logs(playlist_id, owner_id, level, message)
    values (r.playlist_id, r.owner_id, 'warn', r.c || ' fuente(s) declaradas muertas tras ' || public.setting_int('hospital_days', 7) || ' días en el Hospital');
    n := coalesce(n, 0) + r.c;
  end loop;
  return coalesce(n, 0);
end $$;

-- Solo expone ESTE ajuste (setting_int no se concede a los usuarios: leería cualquier ajuste numérico)
create or replace function public.hospital_days() returns int
language sql stable security definer set search_path = public as $$ select public.setting_int('hospital_days', 7) $$;

create or replace view public.v_hospital with (security_invoker = true) as
select sh.source_id, sh.channel_id, sh.playlist_id, c.name as channel_name, c.logo_url, s.url, s.priority,
       sh.hospital_since, sh.dead_at, sh.last_error, sh.last_http, sh.last_checked_at,
       greatest(0, public.hospital_days() - floor(extract(epoch from now() - sh.hospital_since) / 86400))::int as days_left,
       case when sh.dead_at is not null then 'dead' else 'in_hospital' end as status
  from public.source_health sh
  join public.channel_sources s on s.id = sh.source_id
  join public.channels c on c.id = sh.channel_id
 where sh.state = 'down';

-- ------------------------------------------------------------------ BYOP: proxies propios (HTTP / SOCKS5)
create table public.proxies (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users(id) on delete cascade default auth.uid(),
  name         text not null check (length(name) between 1 and 60),
  scheme       text not null check (scheme in ('http','https','socks5','socks5h')),
  host         text not null check (host ~ '^[A-Za-z0-9.-]{1,253}$'),
  port         int  not null check (port between 1 and 65535),
  username     text,
  country      text check (country is null or country ~ '^[A-Z]{2}$'),
  enabled      boolean not null default true,
  last_test_at timestamptz,
  last_ok      boolean,
  last_error   text,
  latency_ms   int,
  exit_country text,
  created_at   timestamptz not null default now()
);
create table public.proxy_secrets (                      -- la clave NUNCA se puede leer desde el navegador
  proxy_id uuid primary key references public.proxies(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  password text not null
);
create table public.proxy_assignments (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references auth.users(id) on delete cascade default auth.uid(),
  proxy_id   uuid not null references public.proxies(id) on delete cascade,
  scope      text not null check (scope in ('country','channel','source')),
  country    text check (country is null or country ~ '^[A-Z]{2}$'),
  channel_id uuid references public.channels(id) on delete cascade,
  source_id  uuid references public.channel_sources(id) on delete cascade,
  check ((scope = 'country' and country is not null and channel_id is null and source_id is null)
      or (scope = 'channel' and channel_id is not null and country is null and source_id is null)
      or (scope = 'source'  and source_id  is not null and country is null and channel_id is null))
);
create unique index proxy_assign_uq on public.proxy_assignments (owner_id, scope, coalesce(country, ''), coalesce(channel_id::text, ''), coalesce(source_id::text, ''));

create or replace function public.tg_proxy_limit() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.enforce_limit(new.owner_id, 'max_proxies', (select count(*) from public.proxies where owner_id = new.owner_id)::int + 1);
  return new;
end $$;
create trigger zz_limit before insert on public.proxies for each row execute function public.tg_proxy_limit();

-- Todo lo asignado debe ser del mismo dueño (nadie usa el proxy / canal ajeno)
create or replace function public.tg_assignment_owner() returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.owner_id := auth.uid();
  if not exists (select 1 from public.proxies where id = new.proxy_id and owner_id = new.owner_id)
     or (new.channel_id is not null and not exists (select 1 from public.channels where id = new.channel_id and owner_id = new.owner_id))
     or (new.source_id  is not null and not exists (select 1 from public.channel_sources where id = new.source_id and owner_id = new.owner_id)) then
    raise exception 'proxy o destino no te pertenece' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger owner_check before insert or update on public.proxy_assignments for each row execute function public.tg_assignment_owner();
create or replace function public.tg_secret_owner() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.proxies where id = new.proxy_id and owner_id = auth.uid()) then raise exception 'proxy no te pertenece' using errcode = '42501'; end if;
  new.owner_id := auth.uid(); return new;
end $$;
create trigger owner_check before insert or update on public.proxy_secrets for each row execute function public.tg_secret_owner();

-- Prioridad: fuente > canal > país. Devuelve la URL con credenciales (solo para el motor / agentes).
create or replace function public.proxy_url_for_source(p_source uuid) returns text
language sql stable security definer set search_path = public as $$
  select p.scheme || '://' ||
         case when p.username is not null then public.urlenc(p.username) || ':' || public.urlenc(coalesce(ps.password, '')) || '@' else '' end ||
         p.host || ':' || p.port
    from public.channel_sources cs
    join public.channels c on c.id = cs.channel_id
    join lateral (
      select pa.proxy_id from public.proxy_assignments pa
       where pa.owner_id = cs.owner_id
         and ((pa.scope = 'source'  and pa.source_id  = cs.id)
           or (pa.scope = 'channel' and pa.channel_id = cs.channel_id)
           or (pa.scope = 'country' and pa.country = coalesce(cs.country, c.country)))
       order by case pa.scope when 'source' then 1 when 'channel' then 2 else 3 end limit 1) a on true
    join public.proxies p on p.id = a.proxy_id and p.enabled
    left join public.proxy_secrets ps on ps.proxy_id = p.id
   where cs.id = p_source
$$;

create or replace function public.record_proxy_test(p_proxy uuid, p_ok boolean, p_latency int default null, p_exit_country text default null, p_error text default null) returns void
language sql security definer set search_path = public as $$
  update public.proxies set last_test_at = now(), last_ok = p_ok, latency_ms = p_latency, exit_country = p_exit_country, last_error = left(p_error, 200) where id = p_proxy
$$;

-- ------------------------------------------------------------------ BYON: agentes propios (sin entregar nunca la service_role)
create table public.agents (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users(id) on delete cascade default auth.uid(),
  name         text not null check (length(name) between 1 and 60),
  country      text check (country is null or country ~ '^[A-Z]{2}$'),
  vantage      text not null,
  token_hash   text not null unique,
  enabled      boolean not null default true,
  version      text,
  last_seen_at timestamptz,
  created_at   timestamptz not null default now()
);

create or replace function public.create_agent(p_name text, p_country text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_tok text := 'ag_' || encode(extensions.gen_random_bytes(24), 'hex'); v_id uuid; v_c text := upper(p_country);
begin
  if auth.uid() is null then raise exception 'no autenticado' using errcode = '42501'; end if;
  perform public.enforce_limit(auth.uid(), 'max_agents', (select count(*) from public.agents where owner_id = auth.uid())::int + 1);
  insert into public.agents(owner_id, name, country, vantage, token_hash)
  values (auth.uid(), p_name, v_c, 'local-' || lower(coalesce(v_c, 'xx')), encode(extensions.digest(v_tok, 'sha256'), 'hex'))
  returning id into v_id;
  return jsonb_build_object('agent_id', v_id, 'token', v_tok, 'note', 'Guarda el token ahora: no se vuelve a mostrar');
end $$;

create or replace function public.agent_auth(p_token text) returns public.agents
language plpgsql stable security definer set search_path = public, extensions as $$
declare a public.agents;
begin
  select * into a from public.agents where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') and enabled;
  if a.id is null then raise exception 'agente no autorizado' using errcode = '28000'; end if;
  return a;
end $$;

create or replace function public.agent_heartbeat(p_token text, p_version text default null, p_info jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
declare a public.agents := public.agent_auth(p_token);
begin
  update public.agents set last_seen_at = now(), version = p_version where id = a.id;
  insert into public.engine_heartbeats(engine_id, owner_id, vantage, version, info)
  values ('agent:' || a.id, a.owner_id, a.vantage, p_version, p_info)
  on conflict (engine_id) do update set last_seen_at = now(), version = excluded.version, info = excluded.info, vantage = excluded.vantage;
end $$;

-- ------------------------------------------------------------------ due_sources v2 (vantage, hospital, proxy, cabeceras)
drop function public.due_sources(int, uuid, boolean);
create or replace function public.due_sources(p_limit int default 200, p_playlist uuid default null, p_force boolean default false,
                                              p_vantage text default null, p_owner uuid default null)
returns table (source_id uuid, channel_id uuid, playlist_id uuid, channel_name text, priority smallint, url text, referer text,
               user_agent text, kind text, resolve_ref text, state text, strikes smallint, default_ua text,
               header_profile text, extra_headers jsonb, stream_format text, country text, vantage_required text,
               in_hospital boolean, proxy_url text)
language sql stable security definer set search_path = public as $$
  select x.*, public.proxy_url_for_source(x.source_id)
    from (
      select cs.id as source_id, c.id as channel_id, c.playlist_id, c.name as channel_name, cs.priority, cs.url, cs.referer, cs.user_agent,
             cs.kind, cs.resolve_ref, coalesce(sh.state, 'unknown') as state, coalesce(sh.strikes, 0)::smallint as strikes,
             p.settings->>'ua' as default_ua, cs.header_profile, cs.extra_headers, cs.stream_format,
             coalesce(cs.country, c.country) as country, cs.vantage_required, (sh.hospital_since is not null) as in_hospital
        from public.channel_sources cs
        join public.channels c  on c.id = cs.channel_id and c.enabled and c.check_enabled
        join public.playlists p on p.id = c.playlist_id
        left join public.source_health sh on sh.source_id = cs.id
       where cs.enabled and (p_playlist is null or c.playlist_id = p_playlist) and (p_owner is null or c.owner_id = p_owner)
         and (p_vantage is null or cs.vantage_required is null or cs.vantage_required = p_vantage)
         and (p_force or sh.last_checked_at is null or sh.last_checked_at < now() - case
                when sh.dead_at is not null then interval '7 days'                  -- muerto: una visita semanal por si resucita
                when coalesce(sh.state, 'unknown') = 'ok' then interval '3 hours'
                when sh.state = 'suspect' then interval '30 minutes'
                when sh.state = 'down' then interval '12 hours'                     -- en el Hospital: sondeo esporádico
                else interval '1 hour' end)
       order by sh.last_checked_at nulls first
       limit p_limit) x
$$;

-- Funciones del agente (autenticadas con SU token; solo ve y escribe lo de su dueño)
create or replace function public.agent_due_sources(p_token text, p_limit int default 100, p_force boolean default false)
returns table (source_id uuid, channel_id uuid, channel_name text, url text, referer text, user_agent text, kind text, resolve_ref text,
               state text, header_profile text, extra_headers jsonb, stream_format text, proxy_url text)
language plpgsql stable security definer set search_path = public as $$
declare a public.agents := public.agent_auth(p_token);
begin
  return query select d.source_id, d.channel_id, d.channel_name, d.url, d.referer, d.user_agent, d.kind, d.resolve_ref, d.state,
                      d.header_profile, d.extra_headers, d.stream_format, d.proxy_url
                 from public.due_sources(p_limit, null, p_force, a.vantage, a.owner_id) d;
end $$;

create or replace function public.agent_record_probe(p_token text, p_source uuid, p_ok boolean, p_http int default null, p_error text default null,
        p_latency_ms int default null, p_hard boolean default true, p_resolved_url text default null, p_quality jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.agents := public.agent_auth(p_token);
begin
  if not exists (select 1 from public.channel_sources where id = p_source and owner_id = a.owner_id) then
    raise exception 'fuente ajena' using errcode = '42501';
  end if;
  return public.record_probe(p_source, p_ok, p_http, p_error, p_latency_ms, a.vantage, p_hard, p_resolved_url, null, null, p_quality, null);
end $$;

-- ------------------------------------------------------------------ CATÁLOGO COMPARTIDO + BANDEJA DE APORTES
create table public.catalog_channels (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique,
  name       text not null,
  name_norm  text generated always as (public.normalize_channel_name(name)) stored,
  country    text check (country is null or country ~ '^[A-Z]{2}$'),
  category   text,
  logo_url   text check (logo_url is null or logo_url ~* '^https?://'),
  epg_id     text,
  language   text,
  status     text not null default 'approved' check (status in ('approved','hidden')),
  created_at timestamptz not null default now()
);
create index catalog_channels_trgm on public.catalog_channels using gin (name_norm extensions.gin_trgm_ops);
alter table public.channels add constraint channels_catalog_fk foreign key (catalog_id) references public.catalog_channels(id) on delete set null;

create table public.catalog_aliases (
  catalog_id uuid not null references public.catalog_channels(id) on delete cascade,
  alias      text not null,
  alias_norm text generated always as (public.normalize_channel_name(alias)) stored,
  primary key (catalog_id, alias)
);
create index catalog_aliases_trgm on public.catalog_aliases using gin (alias_norm extensions.gin_trgm_ops);

create table public.catalog_sources (
  id              uuid primary key default gen_random_uuid(),
  catalog_id      uuid not null references public.catalog_channels(id) on delete cascade,
  url             text not null check (url ~* '^https?://'),
  referer         text,
  user_agent      text,
  kind            text not null default 'direct' check (kind in ('direct','dailymotion','youtube')),
  country         text,
  fingerprint     text not null unique,
  status          text not null default 'approved' check (status in ('approved','hidden')),
  health_state    text not null default 'unknown' check (health_state in ('unknown','ok','suspect','down')),
  fail_count      int not null default 0,
  last_checked_at timestamptz,
  last_ok_at      timestamptz,
  created_at      timestamptz not null default now(),
  check (public.is_shareable_url(url))
);
create index catalog_sources_cat_idx on public.catalog_sources (catalog_id);

create table public.channel_suggestions (
  id           uuid primary key default gen_random_uuid(),
  fingerprint  text not null,
  name         text not null,
  country      text,
  category     text,
  logo_url     text,
  epg_id       text,
  url          text check (url is null or public.is_shareable_url(url)),   -- null = solo nombre + logo (enlace personal)
  referer      text,
  user_agent   text,
  kind         text not null default 'direct',
  catalog_id   uuid references public.catalog_channels(id) on delete set null,
  status       text not null default 'pending' check (status in ('pending','accepted','rejected')),
  reject_reason text,
  reviewed_by  uuid,
  reviewed_at  timestamptz,
  created_at   timestamptz not null default now()
);
create unique index channel_suggestions_pending_uq on public.channel_suggestions (fingerprint) where status = 'pending';
create index channel_suggestions_fp_idx on public.channel_suggestions (fingerprint);

create table public.suggestion_submitters (
  suggestion_id uuid not null references public.channel_suggestions(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  at            timestamptz not null default now(),
  primary key (suggestion_id, user_id)
);

create table public.category_rules (
  id       int generated always as identity primary key,
  pattern  text not null,
  category text not null,
  priority int not null default 100
);
insert into public.category_rules(pattern, category, priority) values
 ('espn|sport|deport|fox sports|tudn|dazn|nba|nfl|futbol|football|f1|golf|tennis|win sports|liga', 'Deportes', 10),
 ('news|noticia|cnn|bbc|telesur|jazeera|24h|cnbc|euronews|dw ', 'Noticias', 10),
 ('kids|disney|nick|cartoon|boomerang|baby|junior|infantil|toon|discovery kids', 'Infantil', 10),
 ('movie|cine|hbo|cinemax|film|starz|tcm|paramount|axn|space|golden|tnt', 'Películas y Series', 20),
 ('music|mtv|vh1|hits|telehit|radio|htv|vevo', 'Música', 20),
 ('discovery|history|nat geo|national geographic|animal planet|documental|a e|tlc|smithsonian', 'Documentales', 20),
 ('telemicro|antena|color vision|cdn|rnn|teleantillas|telesistema|canal 4|canal 5|canal 9|digital 15|cibao|rd ', 'Local RD', 5);

create or replace function public.guess_category(p_name_norm text) returns text
language sql stable security definer set search_path = public as $$
  select category from public.category_rules where p_name_norm ~ pattern order by priority, id limit 1
$$;

create or replace function public.match_catalog(p_name text, p_country text default null, p_limit int default 3)
returns table (catalog_id uuid, name text, category text, logo_url text, epg_id text, country text, score real)
language sql stable security definer set search_path = public, extensions as $$
  with q as (select public.normalize_channel_name(p_name) as n),
  cand as (
    select cc.id as cid, cc.name_norm as nn from public.catalog_channels cc where cc.status = 'approved'
    union all select ca.catalog_id, ca.alias_norm from public.catalog_aliases ca
  )
  select c.id, c.name, c.category, c.logo_url, c.epg_id, c.country,
         least(1.0, max(
           (case when cand.nn = q.n then 1.0 else similarity(cand.nn, q.n) end
            * case when regexp_replace(cand.nn, '[^0-9]', '', 'g') = regexp_replace(q.n, '[^0-9]', '', 'g') then 1.0 else 0.5 end)
           + case when p_country is not null and c.country = upper(p_country) then 0.05 else 0 end))::real as score
    from cand join public.catalog_channels c on c.id = cand.cid and c.status = 'approved'
    cross join q
   where q.n <> '' and (cand.nn = q.n or cand.nn % q.n)
   group by c.id
  having max((case when cand.nn = q.n then 1.0 else similarity(cand.nn, q.n) end
            * case when regexp_replace(cand.nn, '[^0-9]', '', 'g') = regexp_replace(q.n, '[^0-9]', '', 'g') then 1.0 else 0.5 end)) >= 0.5
   order by 7 desc limit p_limit
$$;

-- Contribución automática: SOLO enlaces públicos (sin credenciales), con consentimiento (ToS + interruptor).
create or replace function public.contribute_source(p_source uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s record; v_fp text; v_sug uuid; v_votes int; v_auto int := public.setting_int('auto_accept_votes', 0);
begin
  select cs.url, cs.referer, cs.user_agent, cs.kind, cs.drm, cs.owner_id, cs.country as scountry,
         c.name as cname, c.logo_url, c.epg_id, c.country as ccountry, c.enabled as cenabled, g.name as gname,
         p.share_contributions, p.tos_accepted_at, p.country as pcountry
    into s
    from public.channel_sources cs join public.channels c on c.id = cs.channel_id
    left join public.groups g on g.id = c.group_id
    join public.profiles p on p.id = cs.owner_id
   where cs.id = p_source;
  if not found or not s.share_contributions or s.tos_accepted_at is null or not s.cenabled or s.drm is not null
     or not public.is_shareable_url(s.url) then return; end if;
  v_fp := public.url_fingerprint(s.url);
  if exists (select 1 from public.catalog_sources where fingerprint = v_fp)
     or exists (select 1 from public.channel_suggestions where fingerprint = v_fp and status = 'rejected') then return; end if;
  insert into public.channel_suggestions(fingerprint, name, country, category, logo_url, epg_id, url, referer, user_agent, kind)
  values (v_fp, s.cname, coalesce(s.scountry, s.ccountry, s.pcountry), s.gname, s.logo_url, s.epg_id, s.url, s.referer, s.user_agent, s.kind)
  on conflict (fingerprint) where status = 'pending' do nothing;
  select id into v_sug from public.channel_suggestions where fingerprint = v_fp and status = 'pending';
  insert into public.suggestion_submitters(suggestion_id, user_id) values (v_sug, s.owner_id) on conflict do nothing;
  if v_auto > 0 then
    select count(*) into v_votes from public.suggestion_submitters where suggestion_id = v_sug;
    if v_votes >= v_auto then perform public.accept_suggestion_internal(v_sug, null, null); end if;
  end if;
exception when others then
  null;      -- compartir NUNCA debe impedir que el usuario guarde su canal
end $$;

create or replace function public.tg_contribute() returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.contribute_source(new.id); return null; end $$;
create trigger contribute after insert or update of url on public.channel_sources for each row execute function public.tg_contribute();

-- ¿Qué se compartió y qué es personal? (la UI ofrece "solo nombre + logo" para lo personal)
create or replace function public.contribution_preview(p_playlist uuid)
returns table (channel_id uuid, name text, shareable boolean, shared boolean)
language sql stable security invoker set search_path = public as $$
  select c.id, c.name,
         coalesce(bool_and(public.is_shareable_url(s.url) and s.drm is null), false),
         coalesce(bool_or(exists (select 1 from public.catalog_sources k where k.fingerprint = public.url_fingerprint(s.url))), false)
    from public.channels c left join public.channel_sources s on s.channel_id = c.id
   where c.playlist_id = p_playlist group by c.id, c.name
$$;

create or replace function public.suggest_channel_meta(p_channel uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare c record; v_fp text; v_id uuid;
begin
  select ch.name, ch.logo_url, ch.epg_id, ch.country, g.name as gname, p.share_contributions, p.country as pcountry
    into c from public.channels ch left join public.groups g on g.id = ch.group_id join public.profiles p on p.id = ch.owner_id
   where ch.id = p_channel and ch.owner_id = auth.uid();
  if not found then raise exception 'canal no encontrado' using errcode = '42501'; end if;
  if not c.share_contributions then return null; end if;
  v_fp := 'meta:' || public.normalize_channel_name(c.name) || ':' || coalesce(c.country, c.pcountry, 'xx');
  insert into public.channel_suggestions(fingerprint, name, country, category, logo_url, epg_id)
  values (v_fp, c.name, coalesce(c.country, c.pcountry), c.gname, c.logo_url, c.epg_id)
  on conflict (fingerprint) where status = 'pending' do nothing;
  select id into v_id from public.channel_suggestions where fingerprint = v_fp and status = 'pending';
  insert into public.suggestion_submitters(suggestion_id, user_id) values (v_id, auth.uid()) on conflict do nothing;
  return v_id;
end $$;

create or replace function public.accept_suggestion_internal(p_id uuid, p_catalog uuid, p_actor uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare s public.channel_suggestions; v_cat uuid := p_catalog; v_first boolean := true; u record; v_slug text; m record;
begin
  select * into s from public.channel_suggestions where id = p_id and status = 'pending' for update;
  if not found then raise exception 'sugerencia no pendiente'; end if;
  if v_cat is null then
    select catalog_id into v_cat from public.match_catalog(s.name, s.country, 1) where score >= 0.85;
  end if;
  if v_cat is null then
    v_slug := regexp_replace(public.normalize_channel_name(s.name), ' ', '-', 'g') || '-' || lower(coalesce(s.country, 'xx'));
    insert into public.catalog_channels(slug, name, country, category, logo_url, epg_id)
    values (v_slug, s.name, s.country, coalesce(s.category, public.guess_category(public.normalize_channel_name(s.name))), s.logo_url, s.epg_id)
    on conflict (slug) do update set logo_url = coalesce(public.catalog_channels.logo_url, excluded.logo_url)
    returning id into v_cat;
  else
    update public.catalog_channels set logo_url = coalesce(logo_url, s.logo_url), epg_id = coalesce(epg_id, s.epg_id) where id = v_cat;
  end if;
  if s.url is not null then
    insert into public.catalog_sources(catalog_id, url, referer, user_agent, kind, country, fingerprint)
    values (v_cat, s.url, s.referer, s.user_agent, s.kind, s.country, s.fingerprint) on conflict (fingerprint) do nothing;
  end if;
  update public.channel_suggestions set status = 'accepted', catalog_id = v_cat, reviewed_by = p_actor, reviewed_at = now() where id = p_id;
  for u in select user_id from public.suggestion_submitters where suggestion_id = p_id order by at loop
    perform public.award_xp(u.user_id, 'contrib_accepted', p_id::text, case when v_first then 50 else 10 end);
    perform public.bump_mission(u.user_id, 'contrib_accepted', 1);
    perform public.award_badge(u.user_id, 'contributor');
    v_first := false;
  end loop;
  return v_cat;
end $$;

create or replace function public.admin_accept_suggestion(p_id uuid, p_catalog uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if not public.is_admin() then raise exception 'solo admin' using errcode = '42501'; end if;
  v := public.accept_suggestion_internal(p_id, p_catalog, auth.uid());
  perform public.admin_audit_log('accept_suggestion', p_id::text, jsonb_build_object('catalog', v));
  return v;
end $$;

create or replace function public.admin_reject_suggestion(p_id uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'solo admin' using errcode = '42501'; end if;
  update public.channel_suggestions set status = 'rejected', reject_reason = left(p_reason, 200), reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_id and status = 'pending';
  perform public.admin_audit_log('reject_suggestion', p_id::text, jsonb_build_object('reason', p_reason));
end $$;

-- Siembra el catálogo con la lista "maestra" del admin (enlaces personales se omiten)
create or replace function public.admin_seed_catalog_from_playlist(p_playlist uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c record; s record; v_cat uuid; n_ch int := 0; n_src int := 0; v_slug text;
begin
  if not public.is_admin() then raise exception 'solo admin' using errcode = '42501'; end if;
  for c in select ch.*, g.name as gname from public.channels ch left join public.groups g on g.id = ch.group_id where ch.playlist_id = p_playlist and ch.enabled loop
    v_slug := regexp_replace(public.normalize_channel_name(c.name), ' ', '-', 'g') || '-' || lower(coalesce(c.country, 'xx'));
    insert into public.catalog_channels(slug, name, country, category, logo_url, epg_id, language)
    values (v_slug, c.name, c.country, c.gname, c.logo_url, c.epg_id, c.language)
    on conflict (slug) do update set logo_url = coalesce(public.catalog_channels.logo_url, excluded.logo_url) returning id into v_cat;
    n_ch := n_ch + 1;
    update public.channels set catalog_id = v_cat where id = c.id;
    for s in select * from public.channel_sources where channel_id = c.id and enabled and drm is null and public.is_shareable_url(url) loop
      insert into public.catalog_sources(catalog_id, url, referer, user_agent, kind, country, fingerprint)
      values (v_cat, s.url, s.referer, s.user_agent, s.kind, coalesce(s.country, c.country), public.url_fingerprint(s.url)) on conflict (fingerprint) do nothing;
      n_src := n_src + 1;
    end loop;
  end loop;
  perform public.admin_audit_log('seed_catalog', p_playlist::text, jsonb_build_object('channels', n_ch, 'sources', n_src));
  return jsonb_build_object('channels', n_ch, 'sources_seen', n_src);
end $$;

-- 3 strikes para fuentes del catálogo (las valida el motor del admin)
create or replace function public.record_catalog_probe(p_source uuid, p_ok boolean) returns text
language plpgsql security definer set search_path = public as $$
declare v_state text;
begin
  update public.catalog_sources set
     fail_count = case when p_ok then 0 else fail_count + 1 end,
     health_state = case when p_ok then 'ok' when fail_count + 1 >= 3 then 'down' else 'suspect' end,
     last_checked_at = now(), last_ok_at = case when p_ok then now() else last_ok_at end
   where id = p_source returning health_state into v_state;
  return v_state;
end $$;

-- Copiar canales del catálogo a mi lista (principal + alternas sanas, respetando mi plan)
create or replace function public.import_from_catalog(p_playlist uuid, p_catalog_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_items jsonb; v_max int;
begin
  if not exists (select 1 from public.playlists where id = p_playlist and owner_id = auth.uid()) then raise exception 'lista no encontrada' using errcode = '42501'; end if;
  if not public.has_feature(auth.uid(), 'catalog_follow') then raise exception 'limit_reached:catalog_follow (función no disponible en tu plan)' using errcode = '53400'; end if;
  v_max := public.limit_of(auth.uid(), 'max_alternates') + 1;
  select coalesce(jsonb_agg(jsonb_build_object(
           'tvg_id', c.slug, 'name', c.name, 'group', c.category, 'logo_url', c.logo_url, 'epg_id', c.epg_id, 'country', c.country, 'catalog_id', c.id,
           'sources', (select coalesce(jsonb_agg(jsonb_build_object('url', k.url, 'referer', k.referer, 'ua', k.user_agent, 'kind', k.kind, 'country', k.country)), '[]'::jsonb)
                         from (select * from public.catalog_sources k where k.catalog_id = c.id and k.status = 'approved' and k.health_state <> 'down'
                                order by (k.health_state = 'ok') desc, k.created_at limit v_max) k))), '[]'::jsonb)
    into v_items from public.catalog_channels c where c.id = any(p_catalog_ids) and c.status = 'approved';
  return public.bulk_upsert_channels(p_playlist, v_items);
end $$;

-- ------------------------------------------------------------------ IMPORTACIÓN MASIVA: auto-clasificación + pruebas en vivo antes de importar
create table public.import_batches (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references auth.users(id) on delete cascade default auth.uid(),
  playlist_id  uuid not null references public.playlists(id) on delete cascade,
  label        text,
  status       text not null default 'testing' check (status in ('testing','ready','imported','discarded')),
  total        int not null default 0,
  created_at   timestamptz not null default now(),
  committed_at timestamptz,
  summary      jsonb
);
create table public.import_items (
  id              bigint generated always as identity primary key,
  batch_id        uuid not null references public.import_batches(id) on delete cascade,
  owner_id        uuid not null references auth.users(id) on delete cascade,
  idx             int not null,
  raw             jsonb not null,
  enriched        jsonb,
  test_state      text not null default 'pending' check (test_state in ('pending','testing','ok','fail','skipped')),
  test_http       int,
  test_error      text,
  test_latency_ms int,
  test_vantage    text,
  tested_at       timestamptz,
  selected        boolean not null default true
);
create index import_items_batch_idx on public.import_items (batch_id, idx);
create index import_items_queue_idx on public.import_items (test_state) where test_state in ('pending','testing');

create or replace function public.create_import_batch(p_playlist uuid, p_items jsonb, p_label text default null, p_test boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_u uuid := auth.uid(); v_b uuid; it jsonb; i int := 0; v_n int; v_enrich boolean; v_nn text; m record; v_enr jsonb; v_lim int;
begin
  if not exists (select 1 from public.playlists where id = p_playlist and owner_id = v_u) then raise exception 'lista no encontrada' using errcode = '42501'; end if;
  v_n := coalesce(jsonb_array_length(p_items), 0);
  v_lim := public.limit_of(v_u, 'import_batch_max');
  if v_n > v_lim and not public.is_admin() then raise exception 'limit_reached:import_batch_max (máximo % por importación en tu plan)', v_lim using errcode = '53400'; end if;
  v_enrich := public.has_feature(v_u, 'import_enrichment');
  insert into public.import_batches(owner_id, playlist_id, label, total, status) values (v_u, p_playlist, p_label, v_n, case when p_test then 'testing' else 'ready' end) returning id into v_b;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    i := i + 1; v_enr := null;
    if nullif(it->>'url', '') is null or it->>'url' !~* '^https?://' then
      insert into public.import_items(batch_id, owner_id, idx, raw, test_state, test_error, selected) values (v_b, v_u, i, it, 'skipped', 'URL inválida', false);
      continue;
    end if;
    if v_enrich then
      v_nn := public.normalize_channel_name(it->>'name');
      select * into m from public.match_catalog(it->>'name', it->>'country', 1) where score >= 0.8;
      v_enr := jsonb_build_object('name_norm', v_nn, 'quality', public.detect_quality(it->>'name'),
                 'catalog_id', m.catalog_id, 'score', m.score,
                 'name', coalesce(m.name, nullif(btrim(it->>'name'), ''), initcap(v_nn)),
                 'group', coalesce(m.category, nullif(it->>'group', ''), public.guess_category(v_nn)),
                 'logo_url', coalesce(m.logo_url, nullif(it->>'logo', ''), nullif(it->>'logo_url', '')),
                 'epg_id', coalesce(m.epg_id, nullif(it->>'epg_id', ''), nullif(it->>'tvg_id', '')),
                 'country', coalesce(m.country, nullif(it->>'country', '')),
                 'origin', case when m.catalog_id is not null then 'catalog' when public.guess_category(v_nn) is not null then 'rules' else 'none' end);
    end if;
    insert into public.import_items(batch_id, owner_id, idx, raw, enriched, test_state)
    values (v_b, v_u, i, it, v_enr, case when p_test then 'pending' else 'skipped' end);
  end loop;
  return jsonb_build_object('batch_id', v_b, 'total', v_n, 'enriched', v_enrich);
end $$;

create or replace function public.import_batch_summary(p_batch uuid) returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object('status', (select status from public.import_batches where id = p_batch),
    'counts', coalesce(jsonb_object_agg(test_state, n), '{}'::jsonb))
  from (select test_state, count(*) n from public.import_items where batch_id = p_batch group by 1) q
$$;

-- Los motores/agentes toman trabajo de prueba (re-encola lo que quedó "testing" más de 5 min)
create or replace function public.claim_import_tests(p_limit int default 50, p_vantage text default null, p_owner uuid default null)
returns table (item_id bigint, batch_id uuid, url text, referer text, user_agent text, header_profile text, extra_headers jsonb)
language plpgsql security definer set search_path = public as $$
begin
  update public.import_items set test_state = 'pending' where test_state = 'testing' and tested_at < now() - interval '5 minutes';
  return query
    with c as (
      select i.id from public.import_items i
       where i.test_state = 'pending' and (p_owner is null or i.owner_id = p_owner)
       order by i.batch_id, i.idx for update skip locked limit p_limit)
    update public.import_items i set test_state = 'testing', tested_at = now(), test_vantage = p_vantage
      from c where i.id = c.id
    returning i.id, i.batch_id, i.raw->>'url', nullif(i.raw->>'referer', ''), nullif(i.raw->>'ua', ''), nullif(i.raw->>'header_profile', ''), i.raw->'extra_headers';
end $$;

create or replace function public.record_import_test(p_item bigint, p_ok boolean, p_http int default null, p_error text default null, p_latency_ms int default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_b uuid;
begin
  update public.import_items set test_state = case when p_ok then 'ok' else 'fail' end, test_http = p_http, test_error = left(p_error, 200),
         test_latency_ms = p_latency_ms, tested_at = now() where id = p_item returning batch_id into v_b;
  if v_b is not null and not exists (select 1 from public.import_items where batch_id = v_b and test_state in ('pending','testing')) then
    update public.import_batches set status = 'ready' where id = v_b and status = 'testing';
  end if;
end $$;

create or replace function public.agent_claim_import_tests(p_token text, p_limit int default 50)
returns table (item_id bigint, url text, referer text, user_agent text, header_profile text, extra_headers jsonb)
language plpgsql security definer set search_path = public as $$
declare a public.agents := public.agent_auth(p_token);
begin
  return query select c.item_id, c.url, c.referer, c.user_agent, c.header_profile, c.extra_headers from public.claim_import_tests(p_limit, a.vantage, a.owner_id) c;
end $$;
create or replace function public.agent_record_import_test(p_token text, p_item bigint, p_ok boolean, p_http int default null, p_error text default null, p_latency_ms int default null) returns void
language plpgsql security definer set search_path = public as $$
declare a public.agents := public.agent_auth(p_token);
begin
  if not exists (select 1 from public.import_items where id = p_item and owner_id = a.owner_id) then raise exception 'ítem ajeno' using errcode = '42501'; end if;
  perform public.record_import_test(p_item, p_ok, p_http, p_error, p_latency_ms);
end $$;

-- Importa lo marcado: agrupa duplicados (mismo canal del catálogo / mismo nombre) como FALLBACKS, mejor fuente primero
create or replace function public.commit_import_batch(p_batch uuid, p_only_ok boolean default true, p_apply_enrichment boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b public.import_batches; v_items jsonb; v_res jsonb; v_max int; v_n int;
begin
  select * into b from public.import_batches where id = p_batch and owner_id = auth.uid() for update;
  if not found then raise exception 'lote no encontrado' using errcode = '42501'; end if;
  if b.status = 'imported' then raise exception 'lote ya importado'; end if;
  v_max := public.limit_of(auth.uid(), 'max_alternates') + 1;
  with base as (
    select i.*, coalesce(case when p_apply_enrichment then i.enriched->>'name' end, i.raw->>'name') as nm,
           coalesce(case when p_apply_enrichment then i.enriched->>'catalog_id' end, public.normalize_channel_name(i.raw->>'name')) as gk
      from public.import_items i
     where i.batch_id = p_batch and i.selected and (not p_only_ok or i.test_state in ('ok','skipped'))
  ), ranked as (
    select base.*, row_number() over (partition by gk order by (test_state = 'ok') desc, test_latency_ms nulls last, idx) as rn,
           first_value(idx) over (partition by gk order by idx) as first_idx
      from base
  ), chan as (
    select gk, min(first_idx) as ord,
           (array_agg(nm order by rn))[1] as name,
           (array_agg(case when p_apply_enrichment then enriched->>'group' end order by rn) filter (where enriched->>'group' is not null))[1] as grp,
           (array_agg(coalesce(case when p_apply_enrichment then enriched->>'logo_url' end, raw->>'logo', raw->>'logo_url') order by rn)
              filter (where coalesce(case when p_apply_enrichment then enriched->>'logo_url' end, raw->>'logo', raw->>'logo_url') is not null))[1] as logo,
           (array_agg(case when p_apply_enrichment then enriched->>'epg_id' end order by rn) filter (where enriched->>'epg_id' is not null))[1] as epg,
           (array_agg(nullif(case when p_apply_enrichment then enriched->>'country' end, '') order by rn) filter (where enriched->>'country' is not null))[1] as country,
           (array_agg(case when p_apply_enrichment then (enriched->>'catalog_id') end order by rn) filter (where enriched->>'catalog_id' is not null))[1] as catalog_id,
           (array_agg(raw->>'group' order by rn) filter (where nullif(raw->>'group', '') is not null))[1] as raw_group,
           (array_agg(nullif(raw->>'tvg_id', '') order by rn) filter (where nullif(raw->>'tvg_id', '') is not null))[1] as tvg,
           jsonb_agg(jsonb_build_object('url', raw->>'url', 'referer', nullif(raw->>'referer', ''), 'ua', nullif(raw->>'ua', ''),
                     'kind', coalesce(nullif(raw->>'kind', ''), 'direct'), 'drm', raw->'drm', 'header_profile', nullif(raw->>'header_profile', ''),
                     'extra_headers', raw->'extra_headers', 'country', nullif(raw->>'country', '')) order by rn) filter (where rn <= v_max) as sources
      from ranked group by gk
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'tvg_id', coalesce(tvg, regexp_replace(public.normalize_channel_name(name), ' ', '-', 'g') || '-' || substr(encode(extensions.digest(gk, 'sha256'), 'hex'), 1, 4)),
           'name', name, 'group', coalesce(grp, raw_group), 'logo_url', logo, 'epg_id', epg, 'country', country,
           'catalog_id', catalog_id, 'sources', sources) order by ord), '[]'::jsonb)
    into v_items from chan;
  v_n := jsonb_array_length(v_items);
  v_res := public.bulk_upsert_channels(b.playlist_id, v_items);
  update public.import_batches set status = 'imported', committed_at = now(), summary = v_res || jsonb_build_object('channels', v_n) where id = p_batch;
  perform public.award_xp(auth.uid(), 'import', p_batch::text, least(v_n / 10, 50));
  perform public.bump_mission(auth.uid(), 'channels_imported', v_n);
  if v_n > 0 then perform public.award_badge(auth.uid(), 'first_import'); end if;
  return v_res || jsonb_build_object('channels', v_n);
end $$;

create or replace function public.discard_import_batch(p_batch uuid) returns void
language sql security invoker set search_path = public as $$
  update public.import_batches set status = 'discarded' where id = p_batch and status <> 'imported';
  delete from public.import_items where batch_id = p_batch and exists (select 1 from public.import_batches b where b.id = p_batch and b.status = 'discarded');
$$;

-- ------------------------------------------------------------------ REPORTES colaborativos de fallo
create table public.channel_reports (
  id          bigint generated always as identity primary key,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  channel_id  uuid references public.channels(id) on delete set null,
  fingerprint text,
  kind        text not null check (kind in ('no_video','no_audio','buffering','wrong_content','geo_blocked','bad_epg','other')),
  note        text check (length(note) <= 300),
  created_day date not null default current_date,
  created_at  timestamptz not null default now(),
  unique (reporter_id, channel_id, kind, created_day)
);

create or replace function public.report_channel(p_channel uuid, p_kind text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c record; v_fp text; v_n int; v_today int;
begin
  select ch.id, ch.name, ch.playlist_id, ch.owner_id into c from public.channels ch where ch.id = p_channel and ch.owner_id = auth.uid();
  if not found then raise exception 'canal no encontrado' using errcode = '42501'; end if;
  select public.url_fingerprint(s.url) into v_fp from public.channel_sources s
   where s.channel_id = p_channel and s.enabled and public.is_shareable_url(s.url) order by s.priority limit 1;
  insert into public.channel_reports(reporter_id, channel_id, fingerprint, kind, note) values (auth.uid(), p_channel, v_fp, p_kind, p_note)
  on conflict (reporter_id, channel_id, kind, created_day) do nothing;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('duplicate', true); end if;
  -- "revisar ya": las fuentes del canal pasan a ser las primeras de la cola del motor
  update public.source_health set last_checked_at = null where channel_id = p_channel;
  perform public.engine_log(c.playlist_id, 'warn', 'Reporte de fallo (' || p_kind || ') en ' || c.name || ' · revisión prioritaria');
  select count(*) into v_today from public.xp_events where user_id = auth.uid() and kind = 'report' and at::date = current_date;
  if v_today < 5 then perform public.award_xp(auth.uid(), 'report', p_channel::text || ':' || current_date::text, 2); end if;
  perform public.bump_mission(auth.uid(), 'reports', 1);
  return jsonb_build_object('duplicate', false, 'recheck_queued', true);
end $$;

create or replace view public.v_report_hotspots as              -- solo para admin (se otorga a service_role y se expone vía RPC)
select fingerprint, count(distinct reporter_id) as reporters, count(*) as reports, max(created_at) as last_report,
       (array_agg(kind order by created_at desc))[1] as last_kind
  from public.channel_reports where fingerprint is not null and created_at > now() - interval '7 days' group by fingerprint;

create or replace function public.admin_report_hotspots(p_min int default 2) returns setof public.v_report_hotspots
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'solo admin' using errcode = '42501'; end if;
  return query select * from public.v_report_hotspots where reporters >= p_min order by reporters desc;
end $$;

-- ------------------------------------------------------------------ MULTIVISTA y preferencias
create table public.multiview_layouts (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references auth.users(id) on delete cascade default auth.uid(),
  name       text not null check (length(name) between 1 and 60),
  layout     text not null default '2x2' check (layout in ('1x1','1x2','2x2','pip','1+3')),
  slots      jsonb not null default '[]'::jsonb check (jsonb_typeof(slots) = 'array'),   -- [{channel_id, muted}]
  created_at timestamptz not null default now()
);
create or replace function public.tg_multiview_rules() returns trigger language plpgsql security definer set search_path = public as $$
declare v_max int := public.limit_of(new.owner_id, 'multiview_slots'); v_bad int;
begin
  if jsonb_array_length(new.slots) > v_max and not exists (select 1 from public.profiles where id = new.owner_id and role = 'admin') then
    raise exception 'limit_reached:multiview_slots (máximo % canales a la vez en tu plan)', v_max using errcode = '53400';
  end if;
  select count(*) into v_bad from jsonb_array_elements(new.slots) s
   where not exists (select 1 from public.channels c where c.id = (s->>'channel_id')::uuid and c.owner_id = new.owner_id);
  if v_bad > 0 then raise exception 'la multivista referencia canales que no son tuyos' using errcode = '42501'; end if;
  return new;
end $$;
create trigger rules before insert or update on public.multiview_layouts for each row execute function public.tg_multiview_rules();

create table public.user_prefs (
  user_id uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  data    jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object' and length(data::text) < 8192)
);

-- ------------------------------------------------------------------ UPTIME 90 días y PUNTAJE de lista
create table public.health_daily (
  source_id   uuid not null references public.channel_sources(id) on delete cascade,
  day         date not null,
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  channel_id  uuid not null references public.channels(id) on delete cascade,
  owner_id    uuid not null references auth.users(id) on delete cascade,
  checks      int not null default 0,
  oks         int not null default 0,
  latency_sum bigint not null default 0,
  primary key (source_id, day)
);
create index health_daily_channel_idx on public.health_daily (channel_id, day);

create or replace function public.tg_health_daily() returns trigger language plpgsql security definer set search_path = public as $$
declare v_ch uuid;
begin
  select channel_id into v_ch from public.channel_sources where id = new.source_id;
  if v_ch is null then return null; end if;
  insert into public.health_daily(source_id, day, playlist_id, channel_id, owner_id, checks, oks, latency_sum)
  values (new.source_id, new.at::date, new.playlist_id, v_ch, new.owner_id, 1, case when new.ok then 1 else 0 end, coalesce(new.latency_ms, 0))
  on conflict (source_id, day) do update set checks = public.health_daily.checks + 1,
        oks = public.health_daily.oks + excluded.oks, latency_sum = public.health_daily.latency_sum + excluded.latency_sum;
  return null;
end $$;
create trigger daily after insert on public.health_events for each row execute function public.tg_health_daily();

create or replace function public.channel_uptime(p_channel uuid, p_days int default 90)
returns table (day date, checks int, oks int, uptime_pct numeric)
language plpgsql stable security definer set search_path = public as $$
declare v_days int;
begin
  if not exists (select 1 from public.channels where id = p_channel and owner_id = auth.uid()) then raise exception 'canal no encontrado' using errcode = '42501'; end if;
  v_days := least(p_days, public.limit_of(auth.uid(), 'history_days'), 365);
  return query
    select d::date, coalesce(sum(h.checks), 0)::int, coalesce(sum(h.oks), 0)::int,
           case when coalesce(sum(h.checks), 0) = 0 then null else round(100.0 * sum(h.oks) / sum(h.checks), 1) end
      from generate_series(current_date - (v_days - 1), current_date, interval '1 day') d
      left join public.health_daily h on h.channel_id = p_channel and h.day = d::date
     group by d order by d;
end $$;

create or replace function public.playlist_score(p_playlist uuid) returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare t int; r record; v jsonb;
begin
  select count(*) into t from public.channels where playlist_id = p_playlist and enabled;
  if t = 0 then return jsonb_build_object('score', 0, 'channels', 0); end if;
  select
    round(100.0 * count(*) filter (where health = 'ok') / nullif(count(*) filter (where health in ('ok','warn','down')), 0))::int as p_ok,
    round(100.0 * count(*) filter (where logo_url is not null and logo_status <> 'broken') / count(*))::int as p_logo,
    round(100.0 * count(*) filter (where epg_id is not null) / count(*))::int as p_epg,
    round(100.0 * count(*) filter (where alt_url is not null) / count(*))::int as p_fallback,
    round(100.0 * count(*) filter (where group_id is not null) / count(*))::int as p_cat
    into r from public.v_channels_table where playlist_id = p_playlist and enabled;
  v := jsonb_build_object('channels', t, 'healthy', coalesce(r.p_ok, 0), 'logos', r.p_logo, 'epg', r.p_epg, 'fallbacks', r.p_fallback, 'categorized', r.p_cat);
  return v || jsonb_build_object('score', round(0.40 * coalesce(r.p_ok, 0) + 0.15 * r.p_logo + 0.15 * r.p_epg + 0.15 * r.p_fallback + 0.15 * r.p_cat)::int);
end $$;

-- ------------------------------------------------------------------ INSIGNIAS, MISIONES, TEMPORADAS
create table public.badges (
  key text primary key, name text not null, description text, icon text, hidden boolean not null default false
);
insert into public.badges(key, name, description, icon) values
 ('first_import', 'Primer paso',    'Importaste tu primera lista',                 'rocket'),
 ('contributor',  'Colaborador',    'Un canal que aportaste entró al catálogo',    'users'),
 ('doctor',       'Doctor de canales', 'Rescataste 10 canales del Hospital',      'stethoscope'),
 ('guardian',     'Guardián',       'Reportaste 25 fallos reales',                 'shield');
create table public.user_badges (
  user_id uuid not null references auth.users(id) on delete cascade,
  badge_key text not null references public.badges(key),
  at timestamptz not null default now(),
  primary key (user_id, badge_key)
);
create table public.missions (
  key text primary key, title text not null, metric text not null, goal int not null check (goal > 0), xp int not null, active boolean not null default true
);
insert into public.missions(key, title, metric, goal, xp) values
 ('import_50',  'Importa 50 canales',                  'channels_imported', 50, 40),
 ('report_5',   'Reporta 5 fallos reales',             'reports',            5, 20),
 ('contrib_3',  'Consigue 3 aportes aceptados',        'contrib_accepted',   3, 60);
create table public.user_missions (
  user_id uuid not null references auth.users(id) on delete cascade,
  mission_key text not null references public.missions(key),
  progress int not null default 0,
  completed_at timestamptz,
  primary key (user_id, mission_key)
);

create or replace function public.award_badge(p_user uuid, p_key text) returns void
language sql security definer set search_path = public as $$
  insert into public.user_badges(user_id, badge_key) values (p_user, p_key) on conflict do nothing
$$;

create or replace function public.bump_mission(p_user uuid, p_metric text, p_n int) returns void
language plpgsql security definer set search_path = public as $$
declare m record; v_p int;
begin
  for m in select * from public.missions where metric = p_metric and active loop
    insert into public.user_missions(user_id, mission_key, progress) values (p_user, m.key, 0) on conflict do nothing;
    update public.user_missions set progress = least(progress + p_n, m.goal)
     where user_id = p_user and mission_key = m.key and completed_at is null returning progress into v_p;
    if v_p is not null and v_p >= m.goal then
      update public.user_missions set completed_at = now() where user_id = p_user and mission_key = m.key and completed_at is null;
      perform public.award_xp(p_user, 'mission', m.key, m.xp);
    end if;
  end loop;
end $$;

-- Ranking público: solo alias + nivel + XP (nunca correo ni listas)
create or replace view public.v_leaderboard as
select p.handle, s.level, s.xp from public.profiles p join public.user_stats s on s.user_id = p.id
 where p.handle is not null order by s.xp desc limit 50;

-- ------------------------------------------------------------------ bulk_upsert_channels v2 (país, catálogo, DRM, cabeceras, fallbacks)
create or replace function public.bulk_upsert_channels(p_playlist uuid, p_items jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare it jsonb; src jsonb; v_group uuid; v_ch uuid; v_ins boolean; n_ins int := 0; n_upd int := 0; i int; n_src int; ord int := 0;
begin
  for it in select * from jsonb_array_elements(p_items) loop
    ord := ord + 1; v_group := null;
    if nullif(it->>'group', '') is not null then
      insert into public.groups(playlist_id, name) values (p_playlist, it->>'group') on conflict (playlist_id, name) do nothing;
      select id into v_group from public.groups where playlist_id = p_playlist and name = it->>'group';
    end if;
    insert into public.channels(playlist_id, tvg_id, name, logo_url, group_id, epg_id, chno, language, enabled, check_enabled,
                                catchup_enabled, catchup_type, catchup_source, catchup_days, sort_order, country, catalog_id)
    values (p_playlist, it->>'tvg_id', it->>'name', nullif(it->>'logo_url', ''), v_group, nullif(it->>'epg_id', ''),
            nullif(it->>'chno', '')::int, nullif(it->>'language', ''),
            coalesce((it->>'enabled')::boolean, true), coalesce((it->>'check')::boolean, true),
            it->'catchup' is not null and it->>'catchup' <> 'null',
            it#>>'{catchup,type}', it#>>'{catchup,source}', nullif(it#>>'{catchup,days}', '')::int,
            coalesce((it->>'sort_order')::int, ord), nullif(upper(it->>'country'), ''), nullif(it->>'catalog_id', '')::uuid)
    on conflict (playlist_id, tvg_id) do update set
      name = excluded.name, logo_url = coalesce(excluded.logo_url, public.channels.logo_url), group_id = coalesce(excluded.group_id, public.channels.group_id),
      epg_id = coalesce(excluded.epg_id, public.channels.epg_id),
      chno = excluded.chno, language = excluded.language, enabled = excluded.enabled, check_enabled = excluded.check_enabled,
      catchup_enabled = excluded.catchup_enabled, catchup_type = excluded.catchup_type,
      catchup_source = excluded.catchup_source, catchup_days = excluded.catchup_days, sort_order = excluded.sort_order,
      country = coalesce(excluded.country, public.channels.country), catalog_id = coalesce(excluded.catalog_id, public.channels.catalog_id)
    returning id, (xmax = 0) into v_ch, v_ins;
    if v_ins then n_ins := n_ins + 1; else n_upd := n_upd + 1; end if;

    n_src := coalesce(jsonb_array_length(it->'sources'), 0);
    for i in 0 .. n_src - 1 loop
      src := it->'sources'->i;
      insert into public.channel_sources(channel_id, priority, url, referer, user_agent, kind, resolve_ref, stream_format, drm, country,
                                         vantage_required, header_profile, extra_headers, resolver)
      values (v_ch, i, src->>'url', nullif(src->>'referer', ''), nullif(src->>'ua', ''),
              coalesce(nullif(src->>'kind', ''), 'direct'), nullif(src->>'resolve_ref', ''),
              coalesce(nullif(src->>'stream_format', ''), 'auto'),
              case when jsonb_typeof(src->'drm') = 'object' then src->'drm' end,
              nullif(upper(src->>'country'), ''), nullif(src->>'vantage_required', ''), nullif(src->>'header_profile', ''),
              case when jsonb_typeof(src->'extra_headers') = 'object' then src->'extra_headers' end,
              nullif(src->>'resolver', ''))
      on conflict (channel_id, priority) do update set
        url = excluded.url, referer = excluded.referer, user_agent = excluded.user_agent, kind = excluded.kind, resolve_ref = excluded.resolve_ref,
        stream_format = excluded.stream_format, drm = excluded.drm, country = excluded.country, vantage_required = excluded.vantage_required,
        header_profile = excluded.header_profile, extra_headers = excluded.extra_headers, resolver = excluded.resolver;
    end loop;
    delete from public.channel_sources where channel_id = v_ch and priority >= n_src;
  end loop;
  return jsonb_build_object('inserted', n_ins, 'updated', n_upd);
end $$;

-- ------------------------------------------------------------------ get_playlist_payload v2 + candidatos de reproducción (fallbacks)
create or replace function public.get_playlist_payload(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.outputs; pl public.playlists; result jsonb;
begin
  select * into o from public.outputs where token = p_token and enabled;
  if not found then return null; end if;
  select * into pl from public.playlists where id = o.playlist_id;
  select jsonb_build_object(
           'playlist', jsonb_build_object('id', pl.id, 'name', pl.name, 'version', pl.version, 'settings', pl.settings),
           'output',   jsonb_build_object('id', o.id, 'format', o.format, 'only_healthy', o.only_healthy,
                         'delivery', case when o.delivery = 'smart' and (public.has_feature(o.owner_id, 'smart_delivery') or exists (select 1 from public.profiles where id = o.owner_id and role = 'admin')) then 'smart' else 'direct' end,
                         'extra_formats', public.has_feature(o.owner_id, 'export_formats_extra') or exists (select 1 from public.profiles where id = o.owner_id and role = 'admin')),
           'channels', coalesce(jsonb_agg(q.j order by q.gsort, q.chno nulls last, q.sort_order), '[]'::jsonb))
    into result
    from (
      select jsonb_build_object(
               'tvg_id', c.tvg_id, 'name', c.name, 'logo', c.logo_url, 'group', coalesce(g.name, 'Sin categoría'),
               'epg_id', c.epg_id, 'chno', c.chno, 'lang', c.language,
               'catchup', case when c.catchup_enabled then jsonb_build_object('type', c.catchup_type, 'source', c.catchup_source, 'days', c.catchup_days) end,
               'fallbacks', (select count(*) from public.channel_sources s2 where s2.channel_id = c.id and s2.enabled and s2.id <> sel.id),
               'source', jsonb_build_object('url', coalesce(sel.resolved_url, sel.url), 'referer', coalesce(sel.resolved_referer, sel.referer),
                                            'ua', coalesce(sel.resolved_ua, sel.user_agent), 'kind', sel.kind,
                                            'resolve_ref', sel.resolve_ref, 'state', sel.state,
                                            'drm', sel.drm, 'stream_format', sel.stream_format, 'extra_headers', sel.extra_headers,
                                            'header_profile', sel.header_profile,
                                            'profile', case when sel.hp_ua is not null then jsonb_build_object('ua', sel.hp_ua, 'headers', sel.hp_headers) end)) as j,
             coalesce(g.sort_order, 9999) as gsort, c.chno, c.sort_order
        from public.channels c
        left join public.groups g on g.id = c.group_id
        join lateral (
          select s.id, s.url, s.referer, s.user_agent, s.kind, s.resolve_ref, s.drm, s.stream_format, s.extra_headers, s.header_profile,
                 hp.user_agent as hp_ua, hp.headers as hp_headers,
                 coalesce(sh.state, 'unknown') as state, sh.resolved_url, sh.resolved_referer, sh.resolved_ua
            from public.channel_sources s left join public.source_health sh on sh.source_id = s.id
            left join public.header_profiles hp on hp.key = s.header_profile
           where s.channel_id = c.id and s.enabled
           order by (coalesce(sh.state, 'unknown') = 'ok') desc, (coalesce(sh.state, 'unknown') = 'down') asc, s.priority asc
           limit 1) sel on true
       where c.playlist_id = o.playlist_id and c.enabled
         and (o.group_ids is null or c.group_id = any(o.group_ids))
         and (not o.only_healthy or sel.state <> 'down')) q;
  return result;
end $$;

-- Lo usa el Worker en /p/:token/play/:tvg_id: lista ordenada de fuentes (sanas primero, muertas fuera) para redirigir al backup sin cortar el reproductor
create or replace function public.get_play_candidates(p_token text, p_tvg_id text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.outputs; v_ch uuid; v jsonb;
begin
  select * into o from public.outputs where token = p_token and enabled;
  if not found then return null; end if;
  select id into v_ch from public.channels where playlist_id = o.playlist_id and tvg_id = p_tvg_id and enabled;
  if v_ch is null then return null; end if;
  select jsonb_build_object('delivery', case when o.delivery = 'smart' and (public.has_feature(o.owner_id, 'smart_delivery') or exists (select 1 from public.profiles where id = o.owner_id and role = 'admin')) then 'smart' else 'direct' end,
           'candidates', coalesce(jsonb_agg(jsonb_build_object(
           'source_id', s.id, 'url', coalesce(sh.resolved_url, s.url), 'referer', coalesce(sh.resolved_referer, s.referer),
           'ua', coalesce(sh.resolved_ua, s.user_agent), 'kind', s.kind, 'resolve_ref', s.resolve_ref, 'state', coalesce(sh.state, 'unknown'),
           'header_profile', s.header_profile, 'extra_headers', s.extra_headers, 'drm', s.drm, 'stream_format', s.stream_format,
           'profile', case when hp.key is not null then jsonb_build_object('ua', hp.user_agent, 'headers', hp.headers) end)
         order by case coalesce(sh.state, 'unknown') when 'ok' then 0 when 'unknown' then 1 when 'unverified' then 1 when 'suspect' then 2 else 3 end, s.priority), '[]'::jsonb))
    into v
    from public.channel_sources s left join public.source_health sh on sh.source_id = s.id
    left join public.header_profiles hp on hp.key = s.header_profile
   where s.channel_id = v_ch and s.enabled and sh.dead_at is null;
  return v;
end $$;

-- ------------------------------------------------------------------ purge v2 (hospital + uptime)
create or replace function public.purge_old_data() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.engine_logs        where at < now() - interval '7 days';
  delete from public.health_events      where at < now() - interval '14 days';
  delete from public.channel_revisions  where at < now() - interval '90 days';
  delete from public.sync_jobs          where finished_at < now() - interval '30 days';
  delete from public.health_daily       where day < current_date - 400;
  delete from public.import_batches     where created_at < now() - interval '14 days';
  delete from public.channel_reports    where created_at < now() - interval '90 days';
  perform public.hospital_sweep();
end $$;

-- ------------------------------------------------------------------ RLS
do $$
declare t text;
begin
  foreach t in array array['proxies','proxy_assignments','multiview_layouts','import_batches'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy owner_all on public.%I for all to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()))', t);
  end loop;
  foreach t in array array['import_items','health_daily','agents'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy owner_read on public.%I for select to authenticated using (owner_id = (select auth.uid()))', t);
  end loop;
end $$;
alter table public.proxy_secrets enable row level security;
create policy owner_write on public.proxy_secrets for all to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy owner_update on public.agents for update to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy owner_delete on public.agents for delete to authenticated using (owner_id = (select auth.uid()));
create policy owner_update on public.import_items for update to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
alter table public.user_prefs enable row level security;
create policy own_all on public.user_prefs for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

alter table public.header_profiles enable row level security;
alter table public.resolvers enable row level security;
alter table public.category_rules enable row level security;
alter table public.badges enable row level security;
alter table public.missions enable row level security;
alter table public.user_badges enable row level security;
alter table public.user_missions enable row level security;
alter table public.catalog_channels enable row level security;
alter table public.catalog_aliases enable row level security;
alter table public.catalog_sources enable row level security;
alter table public.channel_suggestions enable row level security;
alter table public.suggestion_submitters enable row level security;
alter table public.channel_reports enable row level security;
create policy read_all on public.header_profiles for select to authenticated using (true);
create policy read_all on public.resolvers       for select to authenticated using (true);
create policy read_all on public.badges          for select to authenticated using (true);
create policy read_all on public.missions        for select to authenticated using (true);
create policy read_own on public.user_badges     for select to authenticated using (user_id = (select auth.uid()));
create policy read_own on public.user_missions   for select to authenticated using (user_id = (select auth.uid()));
create policy admin_all on public.category_rules for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy read_approved on public.catalog_channels for select to authenticated using (status = 'approved' or public.is_admin());
create policy admin_write   on public.catalog_channels for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy read_approved on public.catalog_aliases  for select to authenticated using (true);
create policy admin_write   on public.catalog_aliases  for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy read_approved on public.catalog_sources  for select to authenticated using (status = 'approved' or public.is_admin());
create policy admin_write   on public.catalog_sources  for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy read_mine  on public.channel_suggestions for select to authenticated
  using (public.is_admin() or exists (select 1 from public.suggestion_submitters s where s.suggestion_id = id and s.user_id = (select auth.uid())));
create policy read_mine  on public.suggestion_submitters for select to authenticated using (user_id = (select auth.uid()) or public.is_admin());
create policy read_mine  on public.channel_reports for select to authenticated using (reporter_id = (select auth.uid()) or public.is_admin());

-- ------------------------------------------------------------------ permisos (lista blanca; reaplica TODA la API de usuario)
revoke all on public.proxies, public.proxy_assignments, public.proxy_secrets, public.agents, public.import_batches, public.import_items,
       public.health_daily, public.multiview_layouts, public.user_prefs, public.header_profiles, public.resolvers, public.category_rules,
       public.badges, public.missions, public.user_badges, public.user_missions, public.catalog_channels, public.catalog_aliases,
       public.catalog_sources, public.channel_suggestions, public.suggestion_submitters, public.channel_reports,
       public.v_hospital, public.v_leaderboard, public.v_report_hotspots from anon, authenticated;
grant select, insert, update, delete on public.proxies, public.proxy_assignments, public.multiview_layouts, public.user_prefs to authenticated;
grant insert, update, delete on public.proxy_secrets to authenticated;                           -- sin SELECT: la clave no se puede leer de vuelta
grant select (id, owner_id, name, country, vantage, enabled, version, last_seen_at, created_at) on public.agents to authenticated;
grant update (name, enabled, country) on public.agents to authenticated;
grant delete on public.agents to authenticated;
grant select, delete on public.import_batches to authenticated;
grant select on public.import_items to authenticated;
grant update (selected) on public.import_items to authenticated;
grant select on public.health_daily, public.header_profiles, public.resolvers, public.badges, public.missions, public.user_badges, public.user_missions,
      public.catalog_channels, public.catalog_aliases, public.catalog_sources, public.channel_suggestions, public.suggestion_submitters,
      public.channel_reports, public.v_hospital, public.v_leaderboard to authenticated;
grant select, insert, update, delete on public.category_rules to authenticated;                  -- RLS: solo admin escribe
grant insert, update, delete on public.catalog_channels, public.catalog_aliases, public.catalog_sources to authenticated;   -- RLS: solo admin

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  -- núcleo (0001/0003)
  public.request_sync(uuid, text), public.bulk_upsert_channels(uuid, jsonb), public.reorder_channels(uuid, uuid[]),
  public.rotate_output_token(uuid), public.set_source_priorities(uuid, uuid[]), public.search_epg(uuid, text, int), public.playlist_status(uuid),
  public.f_unaccent(text), public.is_admin(), public.billing_mode(), public.my_entitlements(), public.accept_tos(text), public.redeem_promo(text),
  public.admin_set_setting(text, jsonb), public.admin_grant_plan(uuid, int, text), public.admin_set_flag(text, jsonb, jsonb, boolean),
  public.admin_activate_billing(),
  -- 0004: puras / de apoyo a RLS y triggers
  public.hospital_days(), public.normalize_channel_name(text), public.detect_quality(text), public.is_shareable_url(text), public.url_fingerprint(text), public.guess_category(text),
  -- 0004: API de usuario
  public.create_agent(text, text), public.contribution_preview(uuid), public.suggest_channel_meta(uuid), public.match_catalog(text, text, int),
  public.import_from_catalog(uuid, uuid[]), public.create_import_batch(uuid, jsonb, text, boolean), public.import_batch_summary(uuid),
  public.commit_import_batch(uuid, boolean, boolean), public.discard_import_batch(uuid), public.report_channel(uuid, text, text),
  public.channel_uptime(uuid, int), public.playlist_score(uuid),
  -- 0004: admin (cada una comprueba is_admin())
  public.admin_accept_suggestion(uuid, uuid), public.admin_reject_suggestion(uuid, text), public.admin_seed_catalog_from_playlist(uuid),
  public.admin_report_hotspots(int)
  to authenticated;
-- Agentes: se autentican con SU token (no con la sesión de Supabase); el token se valida dentro de cada función.
grant execute on function public.agent_heartbeat(text, text, jsonb), public.agent_due_sources(text, int, boolean),
  public.agent_record_probe(text, uuid, boolean, int, text, int, boolean, text, jsonb),
  public.agent_claim_import_tests(text, int), public.agent_record_import_test(text, bigint, boolean, int, text, int) to anon, authenticated;
grant all on all tables in schema public to service_role;
grant execute on all functions in schema public to service_role;

-- ------------------------------------------------------------------ Realtime
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['import_items','import_batches','agents'] loop
      if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- =================================================================== 0005_admin_ui.sql
-- 0005: apoyo al panel de administración (solo lectura + búsqueda de usuarios). Cada función comprueba is_admin().

create or replace function public.admin_find_user(p_email text)
returns table (user_id uuid, email text, display_name text, plan text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'solo admin' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_email, ''))) < 3 then return; end if;
  return query
    select u.id, u.email::text, p.display_name, p.plan, p.created_at
      from auth.users u join public.profiles p on p.id = u.id
     where u.email ilike '%' || replace(replace(btrim(p_email), '%', ''), '_', '\_') || '%'
     order by u.email limit 20;
end $$;

create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'solo admin' using errcode = '42501'; end if;
  return jsonb_build_object(
    'users',               (select count(*) from public.profiles),
    'pro_active',          (select count(distinct user_id) from public.subscriptions where status in ('active','trialing','past_due')),
    'manual_grants',       (select count(distinct user_id) from public.manual_grants where expires_at > now()),
    'playlists',           (select count(*) from public.playlists),
    'channels',            (select count(*) from public.channels),
    'catalog_channels',    (select count(*) from public.catalog_channels where status = 'approved'),
    'pending_suggestions', (select count(*) from public.channel_suggestions where status = 'pending'),
    'in_hospital',         (select count(*) from public.source_health where state = 'down' and dead_at is null),
    'dead',                (select count(*) from public.source_health where dead_at is not null),
    'billing_mode',        public.billing_mode());
end $$;

revoke execute on function public.admin_find_user(text), public.admin_overview() from public, anon, authenticated;
grant execute on function public.admin_find_user(text), public.admin_overview() to authenticated;

-- =================================================================== 0006_resolvers.sql
-- 0006: el Worker elige el resolvedor por fuente (columna resolver) y respeta los que el admin apaga (resolvers.enabled).
-- create or replace conserva los permisos ya otorgados a la función.

create or replace function public.get_play_candidates(p_token text, p_tvg_id text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.outputs; v_ch uuid; v jsonb;
begin
  select * into o from public.outputs where token = p_token and enabled;
  if not found then return null; end if;
  select id into v_ch from public.channels where playlist_id = o.playlist_id and tvg_id = p_tvg_id and enabled;
  if v_ch is null then return null; end if;
  select jsonb_build_object('delivery', case when o.delivery = 'smart' and (public.has_feature(o.owner_id, 'smart_delivery') or exists (select 1 from public.profiles where id = o.owner_id and role = 'admin')) then 'smart' else 'direct' end,
           'disabled_resolvers', (select coalesce(jsonb_agg(key), '[]'::jsonb) from public.resolvers where not enabled),
           'candidates', coalesce(jsonb_agg(jsonb_build_object(
           'source_id', s.id, 'url', coalesce(sh.resolved_url, s.url), 'referer', coalesce(sh.resolved_referer, s.referer),
           'ua', coalesce(sh.resolved_ua, s.user_agent), 'kind', s.kind, 'resolve_ref', s.resolve_ref, 'resolver', s.resolver, 'state', coalesce(sh.state, 'unknown'),
           'header_profile', s.header_profile, 'extra_headers', s.extra_headers, 'drm', s.drm, 'stream_format', s.stream_format,
           'profile', case when hp.key is not null then jsonb_build_object('ua', hp.user_agent, 'headers', hp.headers) end)
         order by case coalesce(sh.state, 'unknown') when 'ok' then 0 when 'unknown' then 1 when 'unverified' then 1 when 'suspect' then 2 else 3 end, s.priority), '[]'::jsonb))
    into v
    from public.channel_sources s left join public.source_health sh on sh.source_id = s.id
    left join public.header_profiles hp on hp.key = s.header_profile
   where s.channel_id = v_ch and s.enabled and sh.dead_at is null;
  return v;
end $$;

-- ------------------------------------------------------------------ due_sources / agent_due_sources: ahora incluyen `resolver`
drop function public.due_sources(int, uuid, boolean, text, uuid);
create or replace function public.due_sources(p_limit int default 200, p_playlist uuid default null, p_force boolean default false,
                                              p_vantage text default null, p_owner uuid default null)
returns table (source_id uuid, channel_id uuid, playlist_id uuid, channel_name text, priority smallint, url text, referer text,
               user_agent text, kind text, resolve_ref text, state text, strikes smallint, default_ua text,
               header_profile text, extra_headers jsonb, stream_format text, country text, vantage_required text,
               in_hospital boolean, resolver text, proxy_url text)
language sql stable security definer set search_path = public as $$
  select x.*, public.proxy_url_for_source(x.source_id)
    from (
      select cs.id as source_id, c.id as channel_id, c.playlist_id, c.name as channel_name, cs.priority, cs.url, cs.referer, cs.user_agent,
             cs.kind, cs.resolve_ref, coalesce(sh.state, 'unknown') as state, coalesce(sh.strikes, 0)::smallint as strikes,
             p.settings->>'ua' as default_ua, cs.header_profile, cs.extra_headers, cs.stream_format,
             coalesce(cs.country, c.country) as country, cs.vantage_required, (sh.hospital_since is not null) as in_hospital, cs.resolver
        from public.channel_sources cs
        join public.channels c  on c.id = cs.channel_id and c.enabled and c.check_enabled
        join public.playlists p on p.id = c.playlist_id
        left join public.source_health sh on sh.source_id = cs.id
       where cs.enabled and (p_playlist is null or c.playlist_id = p_playlist) and (p_owner is null or c.owner_id = p_owner)
         and (p_vantage is null or cs.vantage_required is null or cs.vantage_required = p_vantage)
         and (p_force or sh.last_checked_at is null or sh.last_checked_at < now() - case
                when sh.dead_at is not null then interval '7 days'                  -- muerto: una visita semanal por si resucita
                when coalesce(sh.state, 'unknown') = 'ok' then interval '3 hours'
                when sh.state = 'suspect' then interval '30 minutes'
                when sh.state = 'down' then interval '12 hours'                     -- en el Hospital: sondeo esporádico
                else interval '1 hour' end)
       order by sh.last_checked_at nulls first
       limit p_limit) x
$$;


drop function public.agent_due_sources(text, int, boolean);
create function public.agent_due_sources(p_token text, p_limit int default 100, p_force boolean default false)
returns table (source_id uuid, channel_id uuid, channel_name text, url text, referer text, user_agent text, kind text, resolve_ref text,
               state text, header_profile text, extra_headers jsonb, stream_format text, resolver text, proxy_url text)
language plpgsql stable security definer set search_path = public as $$
declare a public.agents := public.agent_auth(p_token);
begin
  return query select d.source_id, d.channel_id, d.channel_name, d.url, d.referer, d.user_agent, d.kind, d.resolve_ref, d.state,
                      d.header_profile, d.extra_headers, d.stream_format, d.resolver, d.proxy_url
                 from public.due_sources(p_limit, null, p_force, a.vantage, a.owner_id) d;
end $$;

revoke execute on function public.due_sources(int, uuid, boolean, text, uuid), public.agent_due_sources(text, int, boolean) from public, anon, authenticated;
grant execute on function public.due_sources(int, uuid, boolean, text, uuid) to service_role;
grant execute on function public.agent_due_sources(text, int, boolean) to anon, authenticated, service_role;
