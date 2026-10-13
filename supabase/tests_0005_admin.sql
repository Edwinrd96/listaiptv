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

insert into auth.users(id, email) values ('aaaaaaaa-0000-0000-0000-000000000001','ana@ejemplo.com'), ('cccccccc-0000-0000-0000-000000000003','admin@ejemplo.com');
update public.profiles set role = 'admin' where id = 'cccccccc-0000-0000-0000-000000000003';

-- usuario normal: nada del panel admin
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.fails($q$select * from public.admin_find_user('ana')$q$, 'usuario normal no busca usuarios');
select t.fails($q$select public.admin_overview()$q$, 'usuario normal no ve el resumen admin');
select t.ok(not public.is_admin(), 'is_admin() es falso para un usuario normal');
select t.ok((select count(*) from public.admin_audit) = 0, 'usuario normal no lee la auditoría');
select t.fails($q$select public.admin_activate_billing()$q$, 'usuario normal no activa el cobro');
select t.fails($q$select public.admin_set_flag('max_channels', '999'::jsonb)$q$, 'usuario normal no cambia banderas');
reset role;

-- admin
set role authenticated; select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false);
select t.ok(public.is_admin(), 'is_admin() es verdadero para el admin');
select t.ok((select count(*) from public.admin_find_user('ANA')) = 1 and (select email from public.admin_find_user('ana@')) = 'ana@ejemplo.com', 'admin busca por correo (sin distinguir mayúsculas)');
select t.ok((select count(*) from public.admin_find_user('%')) = 0, 'el comodín % no lista a todo el mundo');
select t.ok((select count(*) from public.admin_find_user('a')) = 0, 'búsqueda de menos de 3 letras no devuelve nada');
select t.ok((public.admin_overview()->>'users')::int = 2 and public.admin_overview()->>'billing_mode' = 'off', 'resumen: usuarios y modo de cobro');
select public.admin_set_flag('max_channels', '300'::jsonb) ;
select t.ok((select free_value from public.feature_flags where key = 'max_channels') = '300'::jsonb, 'admin cambia una bandera');
select t.ok((select count(*) from public.admin_audit where action = 'set_flag') = 1, 'el cambio queda en la auditoría');
reset role;
\echo OK_0005
