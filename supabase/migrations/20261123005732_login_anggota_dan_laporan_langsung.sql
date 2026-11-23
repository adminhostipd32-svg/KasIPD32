drop function public.kode_akses_kas(uuid), public.provisi_kas(text,text,text,uuid,bigint);
drop function kas_private.terbitkan(uuid);
revoke execute on function public.rekonsiliasi_kas(int,int,text,bigint,text,jsonb,boolean),kas_private.tutup(int,int,text,bigint,text,jsonb,boolean) from authenticated;
do $$ declare t text;begin
 foreach t in array array['anggota','patungan_event','patungan_peserta','periode_kas'] loop execute format('drop trigger kunci_periksa on public.%I',t);end loop;
 foreach t in array array['iuran_kas','saldo_lebih_bayar','transaksi_kas'] loop execute format('drop trigger jaga_bulan on public.%I',t);end loop;
end $$;
create function public.periksa_laporan_kas(y int) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if coalesce(kas_private.peran(),'') not in ('admin','it_support') then raise insufficient_privilege;end if;
 return kas_private.cek_data(y);
end $$;
revoke all on function public.periksa_laporan_kas(int) from public,anon;
grant execute on function public.periksa_laporan_kas(int) to authenticated;

-- Only the account service can resolve usernames or attach a freshly created Auth user.
create function public.akun_login_kas(uname text, calon uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare mid uuid; ident uuid; alamat text;
begin
 select id into mid from public.anggota where lower(username)=lower(trim(uname));
 if mid is null then return null; end if;
 if calon is not null then
  if not exists(select from auth.users where id=calon and email like '%@anggota.invalid' and coalesce(raw_app_meta_data->>'kas_role','')='') then raise insufficient_privilege;end if;
  insert into kas_private.akun_anggota as a(anggota_id,user_id) values(mid,calon)
  on conflict(anggota_id) do update set user_id=excluded.user_id where a.user_id is null;
 end if;
 select a.user_id,u.email into ident,alamat from kas_private.akun_anggota a left join auth.users u on u.id=a.user_id where a.anggota_id=mid;
 if ident is not null and not exists(select from auth.users where id=ident and email like '%@anggota.invalid' and coalesce(raw_app_meta_data->>'kas_role','')='') then raise insufficient_privilege;end if;
 return jsonb_build_object('member',mid,'uid',ident,'email',alamat);
end $$;
revoke all on function public.akun_login_kas(text,uuid) from public,anon,authenticated;
grant execute on function public.akun_login_kas(text,uuid) to service_role;