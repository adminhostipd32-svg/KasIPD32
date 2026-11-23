create function kas_audit.baca_filter(p_sebelum bigint, p_dari date, p_sampai date, p_pelaku text, p_aksi text)
returns table(id bigint,waktu timestamptz,aktor text,tabel text,aksi text,objek text,perubahan jsonb)
language plpgsql stable security definer set search_path='' as $$
begin
  if not exists(select 1 from auth.users u where u.id=auth.uid() and u.deleted_at is null and u.raw_app_meta_data->>'kas_role' in ('admin','it_support')) then
    raise exception 'Log aktivitas hanya untuk Admin dan IT Support.' using errcode='42501';
  end if;
  return query select a.id,a.waktu,a.aktor,a.tabel,a.aksi,a.objek,a.perubahan from kas_audit.aktivitas a
    where (p_sebelum is null or a.id<p_sebelum)
      and (p_dari is null or a.waktu >= (p_dari::timestamp at time zone 'Asia/Jakarta'))
      and (p_sampai is null or a.waktu < ((p_sampai+1)::timestamp at time zone 'Asia/Jakarta'))
      and (nullif(trim(p_pelaku),'') is null or strpos(lower(a.aktor),lower(trim(p_pelaku)))>0)
      and (p_aksi is null or a.aksi=p_aksi)
    order by a.id desc limit 51;
end;
$$;
revoke all on function kas_audit.baca_filter(bigint,date,date,text,text) from public,anon;
grant usage on schema kas_audit to authenticated;
grant execute on function kas_audit.baca_filter(bigint,date,date,text,text) to authenticated;
create function public.cari_log_kas(p_sebelum bigint, p_dari date, p_sampai date, p_pelaku text, p_aksi text)
returns table(id bigint,waktu timestamptz,aktor text,tabel text,aksi text,objek text,perubahan jsonb)
language sql stable security invoker set search_path='' as $$
  select * from kas_audit.baca_filter(p_sebelum,p_dari,p_sampai,p_pelaku,p_aksi);
$$;
revoke all on function public.cari_log_kas(bigint,date,date,text,text) from public,anon;
grant execute on function public.cari_log_kas(bigint,date,date,text,text) to authenticated;
