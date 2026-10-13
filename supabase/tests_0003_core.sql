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

insert into auth.users(id, email) values ('aaaaaaaa-0000-0000-0000-000000000001','a@x.com'), ('bbbbbbbb-0000-0000-0000-000000000002','b@x.com'), ('cccccccc-0000-0000-0000-000000000003','admin@x.com');
update public.profiles set role = 'admin' where id = 'cccccccc-0000-0000-0000-000000000003';
select id as pla from public.playlists where owner_id = 'aaaaaaaa-0000-0000-0000-000000000001' \gset

-- ===== escalada de privilegios
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.fails($q$update public.profiles set role = 'admin' where id = auth.uid()$q$, 'A no puede hacerse admin');
select t.fails($q$update public.profiles set plan = 'pro' where id = auth.uid()$q$, 'A no puede ponerse plan pro');
select t.fails($q$update public.profiles set grandfathered_until = now() + interval '5 years' where id = auth.uid()$q$, 'A no puede regalarse Founder');
select t.fails($q$insert into public.user_stats(user_id, xp, level) values (auth.uid(), 99999, 7)$q$, 'A no puede darse XP');
select t.fails($q$insert into public.manual_grants(user_id, expires_at) values (auth.uid(), now() + interval '1 year')$q$, 'A no puede crearse grants');
select t.fails($q$update public.feature_flags set free_value = '99999' where key = 'max_channels'$q$, 'A no edita flags');
select t.fails($q$select public.admin_set_flag('max_channels', '999')$q$, 'A no es admin: admin_set_flag falla');
select t.fails($q$select public.entitlements_for(auth.uid())$q$, 'entitlements_for no es llamable por usuarios');
update public.profiles set handle = 'edwin_rd', country = 'DO' where id = auth.uid();
select t.ok((select handle from public.profiles where id = auth.uid()) = 'edwin_rd', 'A edita sus campos seguros (handle, país)');
select t.fails($q$update public.profiles set handle = 'Mal Handle!' where id = auth.uid()$q$, 'handle inválido rechazado');

-- ===== entitlements y límites (plan gratis, billing off)
select public.my_entitlements() as ent \gset
select t.ok(:'ent'::jsonb->>'plan' = 'free' and :'ent'::jsonb->>'billing_mode' = 'off' and (:'ent'::jsonb#>>'{features,max_channels}')::int = 250, 'free: plan free, billing off, 250 canales');
select t.ok((:'ent'::jsonb#>>'{features,hospital}')::boolean and (:'ent'::jsonb#>>'{features,audit_mode}')::boolean, 'flags "open" abiertas para todos durante la fase gratis');
select t.ok(not (:'ent'::jsonb#>>'{features,max_proxies}')::int > 0 and not (:'ent'::jsonb#>>'{features,smart_delivery}')::boolean, 'flags con coste (proxies, entrega inteligente) NO se abren gratis');

create temp table gen as select format('{"tvg_id":"c%s","name":"Canal %s","group":"G","sources":[{"url":"https://h.test/%s.m3u8"}]}', g, g, g)::jsonb as j from generate_series(1,250) g;
select public.bulk_upsert_channels(:'pla', (select jsonb_agg(j) from gen)) as r1 \gset
select t.ok((select count(*) from public.channels where playlist_id = :'pla') = 250, '250 canales caben en el plan gratis');
select t.fails(format($q$select public.bulk_upsert_channels(%L, '[{"tvg_id":"c251","name":"Uno más","sources":[{"url":"https://h.test/x.m3u8"}]}]')$q$, :'pla'), 'canal 251 rechazado (limit_reached:max_channels)');
insert into public.channel_sources(channel_id, priority, url) select id, 1, 'https://alt1.test/a' from public.channels where tvg_id = 'c1' and playlist_id = :'pla';
select t.ok((select count(*) from public.channel_sources cs join public.channels c on c.id = cs.channel_id where c.tvg_id = 'c1' and c.playlist_id = :'pla') = 2, 'principal + 1 alterna permitidas en gratis');
select t.fails(format($q$insert into public.channel_sources(channel_id, priority, url) select id, 2, 'https://alt2.test/a' from public.channels where tvg_id = 'c1' and playlist_id = %L$q$, :'pla'), 'segunda alterna rechazada en gratis');
select t.fails($q$insert into public.playlists(name) values ('Otra')$q$, '2.ª lista rechazada en gratis');
insert into public.outputs(playlist_id, name) values (:'pla', 'Segundo');
select t.fails(format($q$insert into public.outputs(playlist_id, name) values (%L, 'Tercero')$q$, :'pla'), '3.er enlace de salida rechazado en gratis');

-- ===== XP y niveles (solo service_role)
reset role;
select public.award_xp('aaaaaaaa-0000-0000-0000-000000000001', 'import', 'x1', 120) as a1 \gset
select t.ok(:'a1'::boolean and (select level from public.user_stats where user_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 2, '120 XP -> nivel 2 Explorador');
select public.award_xp('aaaaaaaa-0000-0000-0000-000000000001', 'import', 'x1', 120) as a2 \gset
select t.ok(not :'a2'::boolean and (select xp from public.user_stats where user_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 120, 'mismo evento 2 veces = no duplica XP (idempotente)');
select public.award_xp('aaaaaaaa-0000-0000-0000-000000000001', 'contrib', 'y', 700);
select t.ok((select level from public.user_stats where user_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 4, '820 XP -> nivel 4 Curador');
set role authenticated; select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select public.my_entitlements() as ent2 \gset
select t.ok((:'ent2'::jsonb#>>'{features,max_channels}')::int = 300 and (:'ent2'::jsonb#>>'{features,multiview_slots}')::int = 4 and (:'ent2'::jsonb#>>'{features,max_playlists}')::int = 2, 'nivel 4: perks acumulados (300 canales, multivista 4, 2 listas)');
select t.ok((:'ent2'::jsonb#>>'{next_level,name}') = 'Guardián', 'my_entitlements informa el siguiente nivel');
select t.ok((select count(*) from public.channels where playlist_id = :'pla') = 250, 'sigue con sus canales');
select public.bulk_upsert_channels(:'pla', '[{"tvg_id":"c251","name":"Uno más","sources":[{"url":"https://h.test/x.m3u8"}]}]');
select t.ok((select count(*) from public.channels where playlist_id = :'pla') = 251, 'perk de nivel 2 permite pasar de 250');
select t.ok((select count(*) from public.user_stats) = 1, 'solo ve sus estadísticas');

-- ===== promos
reset role;
insert into public.promo_codes(code, grant_days, max_uses) values ('PRUEBA30', 30, 1);
set role authenticated; select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select public.redeem_promo(' prueba30 ') as pr \gset
select t.ok(public.my_entitlements()->>'plan' = 'pro' and (public.my_entitlements()#>>'{features,max_channels}')::int = 5000, 'promo concede Pro (5000 canales)');
select t.fails($q$select public.redeem_promo('PRUEBA30')$q$, 'promo agotada / ya canjeada');
select t.fails($q$select public.redeem_promo('NOEXISTE')$q$, 'promo inexistente');
select t.fails($q$insert into public.promo_codes(code, grant_days) values ('GRATIS', 999)$q$, 'usuario no crea promos');

-- ===== admin
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false);
select public.admin_set_flag('max_channels', '400');
select t.ok((select free_value from public.feature_flags where key = 'max_channels') = '400', 'admin cambia una flag');
select public.admin_set_flag('max_channels', '250');
select t.fails($q$select public.admin_set_setting('billing_mode', '"live"')$q$, 'billing_mode=live solo vía admin_activate_billing');
select public.admin_grant_plan('aaaaaaaa-0000-0000-0000-000000000001', 10, 'prueba');
select t.ok((select count(*) from public.admin_audit) >= 3, 'acciones de admin auditadas');
select t.ok(public.my_entitlements()->>'plan' = 'pro', 'admin tiene Pro y no tiene límites de plan');
select t.fails($q$select public.admin_activate_billing()$q$, 'no se activa el cobro sin proveedor configurado');

-- ===== suscripciones (eventos del webhook ya verificados por el Worker)
reset role;
select public.apply_subscription_event('lemonsqueezy', 'evt_1', 'subscription_created', 'bbbbbbbb-0000-0000-0000-000000000002', 'sub_9', 'active', now() + interval '30 days') as e1 \gset
select t.ok(:'e1'::jsonb->>'duplicate' = 'false', 'evento de suscripción aplicado');
select t.ok((public.apply_subscription_event('lemonsqueezy', 'evt_1', 'subscription_created', 'bbbbbbbb-0000-0000-0000-000000000002', 'sub_9', 'canceled', now())) ->> 'duplicate' = 'true'
            and (select status from public.subscriptions where provider_sub_id = 'sub_9') = 'active', 'reintento del webhook = no-op (idempotente)');
select public.apply_subscription_event('lemonsqueezy', 'evt_2', 'subscription_payment_failed', 'bbbbbbbb-0000-0000-0000-000000000002', 'sub_9', 'past_due', now() - interval '2 days');
select t.ok(public.sub_is_live('past_due', now() - interval '2 days'), 'pago fallido hace 2 días: sigue Pro (7 días de gracia)');
select t.ok(not public.sub_is_live('past_due', now() - interval '9 days'), 'pago fallido hace 9 días: vuelve a free');
select t.ok(public.sub_is_live('canceled', now() + interval '5 days') and not public.sub_is_live('expired', now() + interval '5 days'), 'cancelada pero pagada sigue activa; expirada no');
select t.fails($q$set role authenticated; select public.apply_subscription_event('x','e','t',null,'s','active',null)$q$, 'usuarios no pueden inyectar eventos de pago');
reset role;

-- ===== Founder plan al activar el cobro
update public.app_settings set value = '"lemonsqueezy"' where key = 'billing_provider';
set role authenticated; select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false);
select public.admin_activate_billing() as act \gset
select t.ok((:'act'::jsonb->>'founders_granted')::int = 2, 'Founder: 2 usuarios existentes (sin contar admin) reciben 6 meses Pro');
select t.ok(public.billing_mode() = 'live' and (select active from public.plans where key = 'pro'), 'billing_mode=live y plan Pro activo');
reset role;
select t.ok((select founder_discount_pct from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 20, '20 % de descuento de por vida');
insert into auth.users(id, email) values ('dddddddd-0000-0000-0000-000000000004','d@x.com');
select t.ok(public.effective_plan('dddddddd-0000-0000-0000-000000000004') = 'free' and public.effective_plan('aaaaaaaa-0000-0000-0000-000000000001') = 'pro', 'usuario nuevo = free; fundadores = pro');
select t.ok(not (public.entitlements_for('dddddddd-0000-0000-0000-000000000004')->>'hospital')::boolean, 'con cobro live, las flags "open" se cierran para free');
set role authenticated; select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000003', false);
select public.admin_activate_billing();
reset role;
select t.ok((select count(*) from public.profiles where founder_discount_pct = 20) = 2, 'Founder solo se concede UNA vez');
select t.ok((select count(*) from public.billing_events) = 2, 'billing_events guarda cada evento una sola vez');
\echo OK_0003
