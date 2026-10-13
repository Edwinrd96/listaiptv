-- Comprobación de instalación (solo LEE; puedes ejecutarla cuantas veces quieras en el SQL Editor).
-- Resultado: una fila por comprobación. Todas deben decir OK. Si alguna dice FALLA, lee el detalle y NO sigas.
with checks(orden, comprobacion, ok, detalle) as (
  values
  (1, 'Extensiones (pgcrypto, pg_trgm, unaccent)',
      (select count(*) = 3 from pg_extension where extname in ('pgcrypto','pg_trgm','unaccent')),
      (select coalesce(string_agg(extname, ', '), 'ninguna') from pg_extension where extname in ('pgcrypto','pg_trgm','unaccent'))),
  (2, 'Tablas de la app creadas (≥ 50)',
      (select count(*) >= 50 from pg_tables where schemaname = 'public'),
      (select count(*)::text || ' tablas' from pg_tables where schemaname = 'public')),
  (3, 'TODAS las tablas con seguridad por filas (RLS) activa',
      (select count(*) = 0 from pg_tables where schemaname = 'public' and not rowsecurity),
      (select coalesce(string_agg(tablename, ', '), 'todas protegidas') from pg_tables where schemaname = 'public' and not rowsecurity)),
  (4, 'Migración 0003 (planes y funciones activables)',
      to_regclass('public.feature_flags') is not null and (select count(*) > 0 from public.feature_flags),
      'feature_flags'),
  (5, 'Migración 0004 (Hospital, agentes, importación…)',
      to_regclass('public.proxies') is not null and to_regclass('public.health_daily') is not null and to_regprocedure('public.hospital_days()') is not null,
      'proxies, health_daily, hospital_days()'),
  (6, 'Migración 0005 (apoyo al admin)',
      to_regprocedure('public.admin_overview()') is not null and to_regprocedure('public.admin_find_user(text)') is not null,
      'admin_overview, admin_find_user'),
  (7, 'Migración 0006 (resolvedores)',
      (select count(*) = 5 from public.resolvers) and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'due_sources' and pg_get_function_result(p.oid) like '%resolver text%'),
      'resolvers (5) y due_sources con columna resolver'),
  (8, 'Los cobros están APAGADOS (billing_mode = off)',
      (select value::text = '"off"' from public.app_settings where key = 'billing_mode'),
      (select value::text from public.app_settings where key = 'billing_mode')),
  (9, 'Trigger que crea tu perfil/lista al registrarte',
      exists (select 1 from pg_trigger where tgname = 'on_auth_user_created' and not tgisinternal),
      'on_auth_user_created en auth.users'),
  (10, 'Funciones del servicio NO ejecutables por visitantes ni usuarios (due_sources, purge_old_data)',
      not has_function_privilege('anon', 'public.due_sources(int,uuid,boolean,text,uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.due_sources(int,uuid,boolean,text,uuid)', 'execute')
      and not has_function_privilege('anon', 'public.purge_old_data()', 'execute')
      and not has_function_privilege('authenticated', 'public.purge_old_data()', 'execute'),
      'solo service_role'),
  (11, 'Un visitante anónimo NO puede ejecutar funciones de administración',
      not has_function_privilege('anon', 'public.admin_overview()', 'execute') and not has_function_privilege('anon', 'public.admin_set_flag(text,jsonb,jsonb,boolean)', 'execute'),
      'admin_* revocadas a anon'),
  (12, 'Un visitante anónimo NO tiene acceso a NINGUNA tabla',
      not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r','p') and has_table_privilege('anon', c.oid, 'select,insert,update,delete')),
      (select coalesce(string_agg(c.relname, ', '), 'ninguna tabla expuesta') from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r','p') and has_table_privilege('anon', c.oid, 'select,insert,update,delete'))),
  (13, 'Las contraseñas de proxy son de solo escritura para los usuarios',
      not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'proxy_secrets' and cmd = 'SELECT' and 'authenticated' = any(roles)),
      'proxy_secrets sin política de lectura'),
  (14, 'Tiempo real (Realtime) activo para las tablas del panel',
      (select count(*) >= 3 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public'),
      (select count(*)::text || ' tablas publicadas' from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public')),
  (15, 'Existe al menos un administrador (si aún no, haz el paso 3.5 de la guía)',
      exists (select 1 from public.profiles where role = 'admin'),
      (select count(*)::text || ' administrador(es)' from public.profiles where role = 'admin'))
)
select orden, case when ok then 'OK' else 'FALLA' end as estado, comprobacion, detalle from checks order by orden;
