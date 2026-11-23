create schema if not exists kas_private;
revoke all on schema kas_private from public,anon,authenticated;
grant usage on schema kas_private to authenticated;

create table kas_private.akun_anggota(
 anggota_id uuid primary key references public.anggota(id) on delete cascade,
 user_id uuid unique references auth.users(id) on delete set null,
 email text unique, kode_hash text unique, berlaku_sampai timestamptz
);
revoke all on kas_private.akun_anggota from public,anon,authenticated;
create function kas_private.peran() returns text language sql stable security definer set search_path='' as $$
 select case when u.raw_app_meta_data->>'kas_role' in ('admin','it_support') then u.raw_app_meta_data->>'kas_role'
 when exists(select from kas_private.akun_anggota a where a.user_id=u.id) then 'anggota' end
 from auth.users u where u.id=auth.uid() and u.deleted_at is null and u.email_confirmed_at is not null
$$;
create function kas_private.anggota_saya() returns uuid language sql stable security definer set search_path='' as $$
 select anggota_id from kas_private.akun_anggota where user_id=auth.uid()
$$;
create function kas_private.identitas() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('role',kas_private.peran(),'id',coalesce(a.id,u.id),'nama',coalesce(a.nama,split_part(u.email,'@',1)),'email',case when a.id is null then u.email end)
 from auth.users u left join kas_private.akun_anggota k on k.user_id=u.id left join public.anggota a on a.id=k.anggota_id
 where u.id=auth.uid() and kas_private.peran() is not null
$$;
create function public.identitas_kas() returns jsonb language sql stable security invoker set search_path='' as $$ select kas_private.identitas() $$;
-- Keep the old column inaccessible to application roles during the transition.
alter table public.anggota alter column password drop not null;
do $$
declare t text; vis text;
begin
 foreach t in array array['anggota','periode_kas','iuran_kas','saldo_lebih_bayar','transaksi_kas','patungan_event','patungan_peserta'] loop
  execute format('drop policy if exists %I on public.%I','Read '||t,t);
  execute format('drop policy if exists %I on public.%I','Admin write '||t,t);
  execute format('revoke all on public.%I from public, anon, authenticated',t);
  if t='anggota' then
    grant select(id,nama,peran,username,status,catatan_status,aktif_sejak,created_at),
      insert(id,nama,peran,username,status,catatan_status,aktif_sejak),
      update(nama,peran,username,status,catatan_status,aktif_sejak),delete on public.anggota to authenticated;
  else
    execute format('grant select,insert,update,delete on public.%I to authenticated',t);
  end if;
  vis := case when t='anggota' then 'id=kas_private.anggota_saya()'
    when t in ('iuran_kas','saldo_lebih_bayar','patungan_peserta') then 'anggota_id=kas_private.anggota_saya()'
    else 'kas_private.peran()=''anggota''' end;
  execute format('create policy baca_terbatas on public.%I for select to authenticated using (kas_private.peran() in (''admin'',''it_support'') or (%s))',t,vis);
  execute format('create policy bendahara_tulis on public.%I for all to authenticated using(kas_private.peran()=''admin'') with check(kas_private.peran()=''admin'')',t);
 end loop;
end $$;
-- Keep the existing scheduled read-only health check working; only the year is public.
grant select(tahun) on public.periode_kas to anon;
create policy cek_tahun on public.periode_kas for select to anon using(true);

create table public.tutup_buku (
 id uuid primary key default gen_random_uuid(), tahun int not null references public.periode_kas(tahun) on delete restrict,
 bulan int not null check(bulan between 1 and 12), versi int not null,
 aktual bigint not null, snapshot jsonb not null, disahkan_oleh text not null, disahkan_pada timestamptz not null default now(),
 catatan text not null default '', dibuka_pada timestamptz, dibuka_oleh text, alasan_revisi text,
 unique(tahun,bulan,versi)
);
create unique index satu_final_per_bulan on public.tutup_buku(tahun,bulan) where dibuka_pada is null;
alter table public.tutup_buku enable row level security;
revoke all on public.tutup_buku from public,anon,authenticated;
grant select on public.tutup_buku to authenticated;
create policy lihat_laporan on public.tutup_buku for select to authenticated using(kas_private.peran() in ('admin','it_support'));

create function kas_private.rekap(y int,m int) returns jsonb language sql stable security definer set search_path='' as $$
 with aliran as (
 select tahun,bulan,'iuran' jenis,nominal from public.iuran_kas
 union all select tahun,12,'lebih',nominal from public.saldo_lebih_bayar
 union all select tahun,bulan,tipe,nominal from public.transaksi_kas
 ), angka as (
 select coalesce(sum(case when jenis='keluar' then -nominal else nominal end) filter(where (tahun,bulan)<(y,m)),0) awal,
 coalesce(sum(nominal) filter(where (tahun,bulan)=(y,m) and jenis='iuran'),0) iuran,
 coalesce(sum(nominal) filter(where (tahun,bulan)=(y,m) and jenis='lebih'),0) lebih,
 coalesce(sum(nominal) filter(where (tahun,bulan)=(y,m) and jenis='masuk_lain'),0) lain,
 coalesce(sum(nominal) filter(where (tahun,bulan)=(y,m) and jenis='keluar'),0) keluar from aliran
 )
 select jsonb_build_object('awal',awal,'iuran',iuran,'lebih',lebih,'lain',lain,'keluar',keluar,'akhir',awal+iuran+lebih+lain-keluar,
 'kategori',coalesce((select jsonb_agg(to_jsonb(k) order by jumlah desc,kategori) from (select kategori,sum(nominal) jumlah from public.transaksi_kas where tahun=y and bulan=m and tipe='keluar' group by kategori) k),'[]'::jsonb))
 from angka
$$;
create function kas_private.cek_data(y int) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
 'anggota',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nama',nama) order by nama) from public.anggota where status<>'Aktif' and coalesce(catatan_status,'') !~ '20[0-9]{2}'),'[]'),
 'peserta',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'acara',e.id,'nama',p.nama_peserta,'event',e.nama_event) order by e.nama_event,p.nama_peserta)
 from public.patungan_peserta p join public.patungan_event e on e.id=p.patungan_id where e.tahun=y and p.anggota_id is null),'[]'),
 'acara',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'nama',e.nama_event) order by e.nama_event) from public.patungan_event e where e.tahun=y and not e.terposting_ke_kas and e.total_pengeluaran<>coalesce((select sum(p.nominal_bayar) from public.patungan_peserta p where p.patungan_id=e.id),0)),'[]'))
$$;
create function kas_private.tutup(y int,m int,mode text,aktual bigint,note text,expected jsonb,reviewed boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare snap jsonb; cek jsonb; rowid uuid; lastversion int; actor text; payload jsonb;
begin
 if kas_private.peran() is null or kas_private.peran() not in ('admin','it_support') then raise insufficient_privilege;end if;
 if m not between 1 and 12 or m is null or not exists(select from public.periode_kas where tahun=y) then raise exception 'Periode tidak valid';end if;
 if mode <> 'draft' then
   if kas_private.peran()<>'admin' then raise exception 'Hanya bendahara yang dapat menutup atau membuka buku.';end if;
   perform pg_advisory_xact_lock(320032);
 end if;
 snap:=kas_private.rekap(y,m); cek:=kas_private.cek_data(y);
 payload:=jsonb_build_object('rekap',snap,'cek',cek);
 if mode='draft' then return payload;end if;
 select email into actor from auth.users where id=auth.uid();
 if mode='revisi' then
   if nullif(trim(note),'') is null then raise exception 'Alasan revisi wajib diisi.';end if;
   if exists(select from public.tutup_buku t where t.dibuka_pada is null and (t.tahun,t.bulan)>(y,m)) then raise exception 'Buka periode final yang lebih baru terlebih dahulu.';end if;
   update public.tutup_buku t set dibuka_pada=now(),dibuka_oleh=actor,alasan_revisi=note where t.tahun=y and t.bulan=m and t.dibuka_pada is null returning id into rowid;
   if rowid is null then raise exception 'Tidak ada laporan final aktif.';end if;
 elsif mode='final' then
   if make_date(y,m,1)+interval '1 month' > (now() at time zone 'Asia/Jakarta')::date then raise exception 'Tunggu sampai bulan berakhir.';end if;
   if expected is distinct from payload then raise exception 'Data berubah. Muat ulang pemeriksaan.';end if;
   if aktual is distinct from (snap->>'akhir')::bigint then raise exception 'Saldo aktual belum cocok.';end if;
   if reviewed is not true then raise exception 'Periksa data dan konfirmasi rekonsiliasi.';end if;
   if (cek->'anggota'<>'[]' or cek->'peserta'<>'[]' or cek->'acara'<>'[]') and nullif(trim(note),'') is null then raise exception 'Isi catatan hasil pemeriksaan.';end if;
   select coalesce(max(versi),0)+1 into lastversion from public.tutup_buku where tahun=y and bulan=m;
   insert into public.tutup_buku(tahun,bulan,versi,aktual,snapshot,catatan,disahkan_oleh)
   values(y,m,lastversion,aktual,snap||jsonb_build_object('pemeriksaan',jsonb_build_object('anggota',jsonb_array_length(cek->'anggota'),'peserta',jsonb_array_length(cek->'peserta'),'acara',jsonb_array_length(cek->'acara'))),coalesce(note,''),actor) returning id into rowid;
 else raise exception 'Aksi tidak dikenal';end if;
 return jsonb_build_object('id',rowid);
end $$;
create function public.rekonsiliasi_kas(y int,m int,mode text default 'draft',aktual bigint default null,note text default '',expected jsonb default null,reviewed boolean default false) returns jsonb language sql security invoker set search_path='' as $$ select kas_private.tutup(y,m,mode,aktual,note,expected,reviewed) $$;

create function kas_private.jaga_bulan() returns trigger language plpgsql security definer set search_path='' as $$
declare rec jsonb; yr int; mo int;
begin
 perform pg_advisory_xact_lock(320032);
 for rec in select v from (values (case when tg_op<>'INSERT' then to_jsonb(old) end),(case when tg_op<>'DELETE' then to_jsonb(new) end)) x(v) where v is not null loop
   yr:=(rec->>'tahun')::int; mo:=case when tg_table_name='saldo_lebih_bayar' then 12 else (rec->>'bulan')::int end;
   if exists(select from public.tutup_buku t where t.dibuka_pada is null and (yr,mo)<=(t.tahun,t.bulan)) then raise exception 'Perubahan memengaruhi saldo laporan final. Buka revisi terlebih dahulu.';end if;
 end loop;
 if tg_op='DELETE' then return old;end if;return new;
end $$;
do $$ declare t text;begin foreach t in array array['iuran_kas','saldo_lebih_bayar','transaksi_kas'] loop execute format('create trigger jaga_bulan before insert or update or delete on public.%I for each row execute function kas_private.jaga_bulan()',t);end loop;end $$;
revoke all on all functions in schema kas_private from public,anon,authenticated;
grant execute on function kas_private.peran(),kas_private.anggota_saya(),kas_private.identitas(),kas_private.tutup(int,int,text,bigint,text,jsonb,boolean) to authenticated;
revoke all on function public.identitas_kas(),public.rekonsiliasi_kas(int,int,text,bigint,text,jsonb,boolean) from public,anon;
grant execute on function public.identitas_kas(),public.rekonsiliasi_kas(int,int,text,bigint,text,jsonb,boolean) to authenticated;

alter table kas_private.akun_anggota add column generasi bigint not null default 1;
create function kas_private.terbitkan(mid uuid) returns text language plpgsql security definer set search_path='' as $$
declare token text:=gen_random_uuid()::text;
begin
 if coalesce(kas_private.peran(),'') not in ('admin','it_support') then raise insufficient_privilege; end if;
 insert into kas_private.akun_anggota as a(anggota_id,kode_hash,berlaku_sampai) values(mid,encode(sha256(convert_to(token,'UTF8')),'hex'),now()+interval '24 hours')
 on conflict(anggota_id) do update set kode_hash=excluded.kode_hash,berlaku_sampai=excluded.berlaku_sampai,generasi=a.generasi+1;
 return token;
end $$;
create function public.kode_akses_kas(mid uuid) returns text language sql security invoker set search_path='' as $$ select kas_private.terbitkan(mid) $$;
revoke all on function public.kode_akses_kas(uuid),kas_private.terbitkan(uuid) from public,anon;
grant execute on function public.kode_akses_kas(uuid),kas_private.terbitkan(uuid) to authenticated;
-- Service-only bridge between the Auth Admin API and the private member mapping.
create function public.provisi_kas(aksi text,uname text,kode text default null,uid uuid default null,gen bigint default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare a kas_private.akun_anggota; mid uuid;
begin
 select id into mid from public.anggota where lower(username)=lower(trim(uname));
 if aksi='login' then select * into a from kas_private.akun_anggota where anggota_id=mid;return (select to_jsonb(email) from auth.users where id=a.user_id);
 elsif aksi='klaim' then
 update kas_private.akun_anggota set kode_hash=null,berlaku_sampai=null where anggota_id=mid and berlaku_sampai>now() and kode_hash=encode(sha256(convert_to(trim(kode),'UTF8')),'hex') returning * into a;
 if not found then raise exception 'Kode atau username tidak sesuai, atau kode sudah kedaluwarsa.';end if;
 return to_jsonb(a.generasi);
 elsif aksi='hubungkan' then
 update kas_private.akun_anggota set user_id=uid,generasi=generasi+1 where anggota_id=mid and generasi=gen and kode_hash is null;
 if not found then raise exception 'Kode telah diganti. Minta kode baru.';end if;
 return 'true'::jsonb;
 end if;raise exception 'Aksi tidak dikenal';
end $$;
revoke all on function public.provisi_kas(text,text,text,uuid,bigint) from public,anon,authenticated;
grant execute on function public.provisi_kas(text,text,text,uuid,bigint) to service_role;
create function kas_private.ringkasan() returns jsonb language sql stable security definer set search_path='' as $$
 select case when kas_private.peran() is not null then jsonb_build_object(
 'iuran',(select coalesce(jsonb_object_agg(tahun,total),'{}') from (select tahun,sum(nominal) total from public.iuran_kas group by tahun) s),
 'lebih',(select coalesce(jsonb_object_agg(tahun,total),'{}') from (select tahun,sum(nominal) total from public.saldo_lebih_bayar group by tahun) s),
 'acara',(select coalesce(jsonb_object_agg(id,to_jsonb(s)-'id'),'{}') from (select e.id,coalesce(sum(p.nominal_bayar),0) terkumpul,coalesce(sum(p.tarif_target),0) "targetTotal",e.total_pengeluaran pengeluaran,coalesce(sum(p.nominal_bayar),0)-e.total_pengeluaran selisih,count(p.id) filter(where p.status_bayar='Lunas') "lunasCount",count(p.id) "totalPeserta" from public.patungan_event e left join public.patungan_peserta p on p.patungan_id=e.id group by e.id) s)) end $$;
create function public.ringkasan_kas() returns jsonb language sql stable security invoker set search_path='' as $$ select kas_private.ringkasan() $$;
revoke all on function kas_private.ringkasan(),public.ringkasan_kas() from public,anon;
grant execute on function kas_private.ringkasan(),public.ringkasan_kas() to authenticated;

create function kas_private.laporan(y int,m int) returns table(versi int,aktual bigint,snapshot jsonb,disahkan_pada timestamptz,dibuka_pada timestamptz) language sql stable security definer set search_path='' as $$
 select t.versi,t.aktual,t.snapshot,t.disahkan_pada,t.dibuka_pada from public.tutup_buku t where kas_private.peran() is not null and t.tahun=y and t.bulan=m order by t.versi desc $$;
create function public.laporan_final_kas(y int,m int) returns table(versi int,aktual bigint,snapshot jsonb,disahkan_pada timestamptz,dibuka_pada timestamptz) language sql stable security invoker set search_path='' as $$ select * from kas_private.laporan(y,m) $$;
revoke all on function kas_private.laporan(int,int),public.laporan_final_kas(int,int) from public,anon;
grant execute on function kas_private.laporan(int,int),public.laporan_final_kas(int,int) to authenticated;

create function kas_private.kunci_periksa() returns trigger language plpgsql set search_path='' as $$
begin perform pg_advisory_xact_lock(320032);return null;end $$;
revoke all on function kas_private.kunci_periksa() from public,anon,authenticated;
do $$ declare t text;begin foreach t in array array['anggota','patungan_event','patungan_peserta','periode_kas'] loop execute format('create trigger kunci_periksa before insert or update or delete on public.%I for each statement execute function kas_private.kunci_periksa()',t);end loop;end $$;
create trigger catat_tutup_buku after insert or update on public.tutup_buku for each row execute function kas_audit.catat();
