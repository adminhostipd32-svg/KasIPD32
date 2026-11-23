create or replace function public.buat_patungan_dengan_anggota(p_id uuid, p_acara jsonb, p_anggota uuid[])
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  saved uuid;
  expected integer;
  added integer;
  rate bigint := (p_acara->>'tarif_default')::bigint;
begin
  if nullif(trim(p_acara->>'nama_event'),'') is null or rate is null or rate < 0 then
    raise exception 'Nama acara dan tarif yang valid diperlukan.';
  end if;
  insert into public.patungan_event
    (id,nama_event,tahun,status,tarif_default,total_pengeluaran,subsidi_kas,catatan_tarif,keterangan)
  values (p_id,trim(p_acara->>'nama_event'),(p_acara->>'tahun')::int,p_acara->>'status',
    rate,(p_acara->>'total_pengeluaran')::bigint,(p_acara->>'subsidi_kas')::bigint,
    p_acara->>'catatan_tarif',p_acara->>'keterangan')
  on conflict (id) do nothing returning id into saved;
  if saved is null then return p_id; end if;
  select count(distinct item) into expected from unnest(p_anggota) as u(item);
  insert into public.patungan_peserta
    (patungan_id,anggota_id,nama_peserta,tarif_target,nominal_bayar,status_bayar,keterangan)
  select saved,a.id,a.nama,rate,0,case when rate=0 then 'Lunas' else 'Belum Bayar' end,a.peran
  from public.anggota a where a.id=any(p_anggota);
  get diagnostics added = row_count;
  if added <> expected then raise exception 'Daftar anggota berubah. Muat ulang dan periksa pilihan peserta.'; end if;
  return saved;
end;
$$;
revoke all on function public.buat_patungan_dengan_anggota(uuid,jsonb,uuid[]) from public, anon;
grant execute on function public.buat_patungan_dengan_anggota(uuid,jsonb,uuid[]) to authenticated;
