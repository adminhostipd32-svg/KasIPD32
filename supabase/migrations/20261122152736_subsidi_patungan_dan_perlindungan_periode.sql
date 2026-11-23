alter table public.patungan_event add column subsidi_kas bigint check (subsidi_kas >= 0);
alter table public.iuran_kas drop constraint iuran_kas_tahun_fkey, add foreign key (tahun) references public.periode_kas(tahun) on delete restrict;
alter table public.saldo_lebih_bayar drop constraint saldo_lebih_bayar_tahun_fkey, add foreign key (tahun) references public.periode_kas(tahun) on delete restrict;
alter table public.transaksi_kas add foreign key (tahun) references public.periode_kas(tahun) on delete restrict;
alter table public.patungan_event add foreign key (tahun) references public.periode_kas(tahun) on delete restrict;

create function public.posting_patungan(p_event uuid, p_tanggal date)
returns void language plpgsql security invoker set search_path = '' as $$
declare
  acara public.patungan_event%rowtype;
  terkumpul bigint;
  subsidi bigint;
  sisa bigint;
begin
  select * into strict acara from public.patungan_event where id = p_event for update;
  if acara.terposting_ke_kas then return; end if;
  if extract(year from p_tanggal) <> acara.tahun or p_tanggal is null then
    raise exception 'Tanggal posting harus berada pada tahun acara.';
  end if;
  select coalesce(sum(nominal_bayar), 0) into terkumpul from public.patungan_peserta where patungan_id = p_event;
  subsidi := coalesce(acara.subsidi_kas, greatest(acara.total_pengeluaran - terkumpul, 0));
  sisa := terkumpul + subsidi - acara.total_pengeluaran;
  if sisa < 0 then raise exception 'Dana peserta dan subsidi belum menutup biaya acara.'; end if;
  if subsidi > 0 then
    insert into public.transaksi_kas(tahun,bulan,tanggal,tipe,kategori,deskripsi,nominal,patungan_id)
    values(acara.tahun,extract(month from p_tanggal),p_tanggal,'keluar','Defisit Patungan','Subsidi kas — ' || acara.nama_event,subsidi,p_event);
  end if;
  if sisa > 0 then
    insert into public.transaksi_kas(tahun,bulan,tanggal,tipe,kategori,deskripsi,nominal,patungan_id)
    values(acara.tahun,extract(month from p_tanggal),p_tanggal,'masuk_lain','Sisa Patungan','Sisa Patungan — ' || acara.nama_event,sisa,p_event);
  end if;
  update public.patungan_event set terposting_ke_kas=true, status='Selesai' where id=p_event;
end;
$$;
revoke all on function public.posting_patungan(uuid,date) from public, anon;
grant execute on function public.posting_patungan(uuid,date) to authenticated;
