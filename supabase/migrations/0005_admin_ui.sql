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
