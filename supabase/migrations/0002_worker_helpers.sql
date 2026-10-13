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
