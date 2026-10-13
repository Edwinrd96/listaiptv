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
