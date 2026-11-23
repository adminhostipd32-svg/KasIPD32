create or replace function kas_private.cek_data(y int) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
 'anggota',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nama',nama) order by nama) from public.anggota where status<>'Aktif' and (coalesce(catatan_status,'') !~ '20[0-9]{2}' or coalesce(catatan_status,'') !~* '(jan|feb|mar|apr|mei|jun|jul|agu|agt|sep|okt|nov|des|20[0-9]{2}[-/](0?[1-9]|1[0-2])\M|\m(0?[1-9]|1[0-2])[-/]20[0-9]{2})')),'[]'),
 'peserta',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'acara',e.id,'nama',p.nama_peserta,'event',e.nama_event) order by e.nama_event,p.nama_peserta)
 from public.patungan_peserta p join public.patungan_event e on e.id=p.patungan_id where e.tahun=y and p.anggota_id is null),'[]'),
 'acara',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'nama',e.nama_event) order by e.nama_event) from public.patungan_event e where e.tahun=y and not e.terposting_ke_kas and (coalesce(e.subsidi_kas,0)>0 or e.total_pengeluaran<>coalesce((select sum(p.nominal_bayar) from public.patungan_peserta p where p.patungan_id=e.id),0))),'[]'))
$$;
