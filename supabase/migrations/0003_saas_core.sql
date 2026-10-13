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
