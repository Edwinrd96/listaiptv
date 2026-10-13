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
