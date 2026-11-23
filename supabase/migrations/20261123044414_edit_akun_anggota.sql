create function public.akun_login_kas_id(mid uuid, calon uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare ident uuid; alamat text;
begin
 if not exists(select from public.anggota where id=mid) then return null; end if;
 if calon is not null then
  if not exists(select from auth.users where id=calon and email like '%@anggota.invalid' and coalesce(raw_app_meta_data->>'kas_role','')='') then raise insufficient_privilege;end if;
  insert into kas_private.akun_anggota as a(anggota_id,user_id) values(mid,calon)
  on conflict(anggota_id) do update set user_id=excluded.user_id where a.user_id is null;
 end if;
 select a.user_id,u.email into ident,alamat from kas_private.akun_anggota a left join auth.users u on u.id=a.user_id where a.anggota_id=mid;
 if ident is not null and not exists(select from auth.users where id=ident and email like '%@anggota.invalid' and coalesce(raw_app_meta_data->>'kas_role','')='') then raise insufficient_privilege;end if;
 return jsonb_build_object('member',mid,'uid',ident,'email',alamat);
end $$;
revoke all on function public.akun_login_kas_id(uuid,uuid) from public,anon,authenticated;
grant execute on function public.akun_login_kas_id(uuid,uuid) to service_role;
create or replace function public.akun_login_kas(uname text, calon uuid default null) returns jsonb language sql security invoker set search_path='' as $$
 select public.akun_login_kas_id((select id from public.anggota where lower(username)=lower(trim(uname))),calon)
$$;
update auth.users set raw_app_meta_data=coalesce(raw_app_meta_data,'{}') ||
 jsonb_build_object('kas_role',case lower(email) when 'adminhostipd32@gmail.com' then 'admin' else 'it_support' end)
 where lower(email) in ('adminhostipd32@gmail.com','risalpanimba@gmail.com') and email_confirmed_at is not null and deleted_at is null and raw_app_meta_data->>'kas_role' is null;
