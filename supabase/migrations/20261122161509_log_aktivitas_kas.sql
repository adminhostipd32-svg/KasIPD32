create schema if not exists kas_audit;
revoke all on schema kas_audit from public, anon, authenticated;
create table kas_audit.aktivitas (
  id bigint generated always as identity primary key,
  waktu timestamptz not null default clock_timestamp(),
  aktor text not null,
  tabel text not null,
  aksi text not null,
  objek text not null,
  perubahan jsonb not null
);
alter table kas_audit.aktivitas enable row level security;
revoke all on kas_audit.aktivitas from public, anon, authenticated;

create function kas_audit.catat() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  lama jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) else '{}'::jsonb end;
  baru jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) else '{}'::jsonb end;
  item jsonb := case when tg_op='DELETE' then lama else baru end;
  kolom text;
  beda jsonb := '{}'::jsonb;
  nama text;
  acara text;
begin
  foreach kolom in array array['nama','nama_event','nama_peserta','tahun','bulan','tanggal','tanggal_bayar','nominal','status','peran','aktif_sejak','tarif_bulanan','tipe','kategori','tarif_default','total_pengeluaran','subsidi_kas','terposting_ke_kas','tarif_target','nominal_bayar','status_bayar'] loop
    if lama->kolom is distinct from baru->kolom then
      beda := beda || jsonb_build_object(kolom,jsonb_build_array(lama->kolom,baru->kolom));
    end if;
  end loop;
  if tg_op='UPDATE' and tg_table_name='anggota' and lama->'password' is distinct from baru->'password' then
    beda := beda || '{"kredensial":"Diperbarui"}'::jsonb;
  end if;
  if tg_op='UPDATE' and baru - 'updated_at' = lama - 'updated_at' then return null; end if;
  if item->>'anggota_id' is not null then select a.nama into nama from public.anggota a where a.id=(item->>'anggota_id')::uuid; end if;
  if item->>'patungan_id' is not null then select e.nama_event into acara from public.patungan_event e where e.id=(item->>'patungan_id')::uuid; end if;
  insert into kas_audit.aktivitas(aktor,tabel,aksi,objek,perubahan) values (
    coalesce(nullif(auth.jwt()->>'email',''), auth.uid()::text, nullif(auth.role(),''),session_user::text),
    tg_table_name,tg_op,coalesce(nullif(concat_ws(' · ',coalesce(item->>'nama_event',item->>'nama_peserta',item->>'nama',nama,item->>'kategori'),acara,item->>'bulan',item->>'tahun'),''),item->>'id'),beda
  );
  return null;
end;
$$;
revoke all on function kas_audit.catat() from public, anon, authenticated;
do $$
declare nama text;
begin
  foreach nama in array array['anggota','periode_kas','iuran_kas','saldo_lebih_bayar','transaksi_kas','patungan_event','patungan_peserta'] loop
    execute format('create trigger catat_aktivitas after insert or update or delete on public.%I for each row execute function kas_audit.catat()',nama);
  end loop;
end;
$$;

create function kas_audit.baca(p_sebelum bigint)
returns table(id bigint,waktu timestamptz,aktor text,tabel text,aksi text,objek text,perubahan jsonb)
language plpgsql stable security definer set search_path='' as $$
begin
  if not exists(select 1 from auth.users u where u.id=auth.uid() and u.deleted_at is null and u.raw_app_meta_data->>'kas_role' in ('admin','it_support')) then
    raise exception 'Log aktivitas hanya untuk Admin dan IT Support.' using errcode='42501';
  end if;
  return query select a.id,a.waktu,a.aktor,a.tabel,a.aksi,a.objek,a.perubahan from kas_audit.aktivitas a
    where p_sebelum is null or a.id<p_sebelum order by a.id desc limit 51;
end;
$$;
revoke all on function kas_audit.baca(bigint) from public,anon;
grant usage on schema kas_audit to authenticated;
grant execute on function kas_audit.baca(bigint) to authenticated;
create function public.baca_log_kas(p_sebelum bigint default null)
returns table(id bigint,waktu timestamptz,aktor text,tabel text,aksi text,objek text,perubahan jsonb)
language sql stable security invoker set search_path='' as $$
  select * from kas_audit.baca(p_sebelum);
$$;
revoke all on function public.baca_log_kas(bigint) from public,anon;
grant execute on function public.baca_log_kas(bigint) to authenticated;
