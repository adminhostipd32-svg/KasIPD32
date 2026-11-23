const memberColumns = 'id,nama,peran,username,status,catatan_status,aktif_sejak,created_at';
const staffAccess = () => ['admin','it_support'].includes(State.session?.role);
const initialData = structuredClone(State.data);
const fieldStyle = 'block w-full mt-1 border border-slate-300 rounded-xl p-2.5 bg-white text-sm';
const primaryStyle = 'rounded-xl bg-teal-700 text-white font-semibold px-4 py-2.5';
const secondaryStyle = 'rounded-xl bg-white border border-slate-300 px-4 py-2 text-sm';
async function rpcKas(name,args={}) {
  const {data,error}=await DB.client.rpc(name,args);
  if(error) throw new Error(error.message);
  return data;
}
async function memberSignIn(username,password,kode) {
  const response=await fetch(new URL('/functions/v1/akun-anggota',DB.url),{method:'POST',headers:{apikey:DB.key,'Content-Type':'application/json'},body:JSON.stringify({aksi:kode?'aktivasi':'login',username,password,kode})});
  const result=await response.json();
  if(!response.ok) throw new Error(result.error || 'Layanan akun belum tersedia.');
  const {error}=await DB.client.auth.setSession(result);
  if(error) throw error;
}
async function loginKas(identifier,password,kode) {
  if(!DB.client) throw new Error('Koneksi Supabase belum tersedia. Muat ulang halaman.');
  if(identifier.includes('@') && !kode) {
    const {error}=await DB.client.auth.signInWithPassword({email:identifier,password});
    if(error) throw error;
  } else await memberSignIn(identifier,password,kode);
  const identity=await rpcKas('identitas_kas');
  if(!identity) { await DB.logout();throw new Error('Akun belum memiliki akses KAS IPD32.'); }
  return identity;
}
function clearKasSession() {
  State.data=structuredClone(initialData);
  State.session=null;
  State.activePage='dashboard';
  State.reportMember='';
  State.activePatunganId=null;
  State.showClosing=false;
  resetAuditView();
  closeModal();
}
function memberCode(mid) {
  const member=State.data.anggota.find(row=>row.id===mid);
  if(!staffAccess() || !member) return;
  openConfirmModal({title:'Terbitkan kode akses?',message:'Berikan kode secara pribadi kepada '+member.nama+' setelah memeriksa identitasnya. Kode baru menggantikan kode sebelumnya. Saat digunakan, kode menghubungkan akun dengan kata sandi baru.',confirmLabel:'Terbitkan kode',onConfirm:async()=>{
    try {
      const code=await rpcKas('kode_akses_kas',{mid});
      openModal(`<section class="p-5 space-y-4"><h2 class="font-bold">Kode akses · ${escapeHtml(member.nama)}</h2><p class="text-sm">Berlaku 24 jam dan hanya dapat digunakan sekali. Username <b>${escapeHtml(member.username)}</b>.</p><code class="block break-all bg-teal-50 p-3 rounded-xl">${escapeHtml(code)}</code><button class="${secondaryStyle}" onclick="closeModal()">Selesai</button></section>`);
    } catch(e){showToast(e.message,'error');}
  }});
}
function financialReports() {
  const closing=!staffAccess() || State.showClosing;
  const tabs=staffAccess()?`<div class="dash-switch mb-4" aria-label="Jenis laporan"><button aria-pressed="${!closing}" onclick="State.showClosing=false;renderApp()">Rekap & tagihan</button><button aria-pressed="${!!closing}" onclick="State.showClosing=true;renderApp()">Tutup buku bulanan</button></div>`:'';
  return tabs+(closing?'<monthly-close></monthly-close>':renderReportPage());
}
class MonthlyClose extends HTMLElement {
  connectedCallback() {
    const today=new Date();
    const last=new Date(today.getFullYear(),today.getMonth()-1,1);
    const years=getAvailableYears();
    this.y=years.includes(last.getFullYear())?last.getFullYear():years.at(-1);
    this.m=last.getMonth()+1;
    this.innerHTML=`<section class="space-y-4"><header class="report-banner"><div><h1>${staffAccess()?'Rekonsiliasi & tutup buku':'Laporan final bulanan'}</h1><p>${staffAccess()?'Periksa data dan cocokkan saldo sebelum mengesahkan laporan.':'Pilih bulan untuk membaca laporan yang sudah disahkan.'}</p></div></header><div class="flex flex-wrap gap-3"><label>Tahun<select class="${fieldStyle}" name="tahun">${years.map(y=>`<option ${y===this.y?'selected':''}>${y}</option>`).join('')}</select></label><label>Bulan<select class="${fieldStyle}" name="bulan">${MONTHS.map(m=>`<option value="${m.num}" ${m.num===this.m?'selected':''}>${m.full}</option>`).join('')}</select></label></div><div data-content aria-live="polite"></div></section>`;
    this.body=this.querySelector('[data-content]');
    this.onchange=e=>{
      if(e.target.name==='tahun'||e.target.name==='bulan') {
        this.y=Number(this.querySelector('[name=tahun]').value);
        this.m=Number(this.querySelector('[name=bulan]').value);
        this.load();
      }
    };
    this.load();
  }
  async load(){
    const seq=this.seq=(this.seq||0)+1;
    this.body.textContent='Memuat laporan…';
    try {
      const [history,draft]=await Promise.all([
        staffAccess()?DB.client.from('tutup_buku').select('*').eq('tahun',this.y).eq('bulan',this.m).order('versi',{ascending:false}):DB.client.rpc('laporan_final_kas',{y:this.y,m:this.m}),
        staffAccess()?rpcKas('rekonsiliasi_kas',{y:this.y,m:this.m}):null
      ]);
      if(history.error) throw history.error;
      if(seq!==this.seq || !this.isConnected)return;
      this.draft=draft;this.history=history.data;this.draw();
    } catch(e){if(seq===this.seq)this.body.innerHTML=`<p class="p-4 bg-rose-50 rounded-xl">${escapeHtml(e.message)}</p><button class="${secondaryStyle}" data-reload>Muat ulang</button>`;this.querySelector('[data-reload]')?.addEventListener('click',()=>this.load());}
  }
  totals(r){
    return `<div class="report-tiles">${[['Saldo awal',r.awal,'dues'],['Pemasukan',r.iuran+r.lebih+r.lain,'events'],['Pengeluaran',r.keluar,'future'],['Saldo buku',r.akhir,'total']].map(([k,v,t])=>`<div class="report-tile tile-${t}"><p>${k}</p><strong>${formatRp(v)}</strong></div>`).join('')}</div><p class="text-sm mt-2">Iuran ${formatRp(r.iuran)} · Pemasukan lain ${formatRp(r.lain)} · Lebih bayar ${formatRp(r.lebih)}</p>${r.kategori.length?reportTable('Pengeluaran per kategori',['Kategori','Jumlah'],r.kategori.map(k=>[escapeHtml(k.kategori),formatRp(k.jumlah)])):''}`;
  }
  draw(){
    const active=this.history.find(v=>!v.dibuka_pada);
    const label=MONTHS[this.m-1].full+' '+this.y;
    const basis='<p class="text-xs text-slate-600">Iuran mengikuti bulan tagihan. Lebih bayar yang hanya memiliki tahun dibukukan pada Desember.</p>';
    const version=v=>`<article class="space-y-3"><header><h3 class="font-bold">Laporan kas IPD32 · ${escapeHtml(label)}</h3><p>${v.dibuka_pada?'Arsip revisi':'Final'} · Versi ${v.versi} · ${new Date(v.disahkan_pada).toLocaleDateString('id-ID')}</p></header>${this.totals(v.snapshot)}<p>Saldo aktual <b>${formatRp(v.aktual)}</b> · Selisih <b>${formatRp(v.aktual-v.snapshot.akhir)}</b></p>${basis}${staffAccess()?`<p>Disahkan oleh ${escapeHtml(v.disahkan_oleh)} · ${escapeHtml(v.catatan||'Tanpa catatan')}</p>`:''}${v.dibuka_pada && staffAccess()?`<p>Alasan revisi · ${escapeHtml(v.alasan_revisi)}</p>`:''}</article>`;
    let html='';
    if(active) html+=`<section class="glass-card rounded-2xl p-5 space-y-3"><div id="member-report">${version(active)}</div><button class="${secondaryStyle}" onclick="printMemberReport()">Cetak / simpan PDF</button></section>`;
    else if(!staffAccess()) html+='<p class="rounded-xl p-4 bg-sky-50">Belum ada laporan final untuk bulan ini.</p>';
    if(this.draft && !active) {
      const {rekap,cek}=this.draft;
      html+=`<section class="glass-card rounded-2xl p-5 space-y-4"><h2 class="font-bold">Draf · ${label}</h2>${this.totals(rekap)}${basis}<h3 class="font-bold">Pemeriksaan sebelum final</h3>${[['anggota','Status anggota tanpa tahun efektif','Master anggota'],['peserta','Peserta belum terhubung ke anggota','Patungan'],['acara','Selisih acara belum diposting','Patungan']].map(([k,title,action])=>`<details class="border rounded-xl p-3"><summary class="cursor-pointer font-semibold">${title} · ${cek[k].length}</summary><p class="text-sm mt-2">${cek[k].length?cek[k].map(p=>escapeHtml(p.nama)+(p.event?' · '+escapeHtml(p.event):'')).join('<br>'):'Tidak ada temuan.'}</p>${cek[k].length?`<button class="${secondaryStyle}" onclick="State.settingsTab='anggota';navigateTo('${k==='anggota'?'pengaturan':'patungan'}')">Buka ${action}</button>`:''}</details>`).join('')}<p class="text-xs text-slate-600">Temuan acara berlaku untuk tahun terpilih. Peserta eksternal dapat dicatat sebagai pengecualian. Pembayaran sebagian tetap tercatat sebagai cicilan.</p></section>`;
    }
    if(isAdmin())html+=`<form class="glass-card rounded-2xl p-5 space-y-3"><h2 class="font-bold">${active?'Buka kembali untuk revisi':'Cocokkan saldo aktual'}</h2>${active?'':`<label class="block">Saldo kas dan rekening pada akhir bulan (Rp)<input name="amount" inputmode="numeric" class="${fieldStyle}" required autocomplete="off"></label><p data-diff aria-live="polite">Isi saldo aktual untuk melihat selisih.</p><label class="block"><input type="checkbox" required> Saya sudah memeriksa saldo dan seluruh temuan.</label>`}<label class="block">${active?'Alasan revisi':'Catatan hasil pemeriksaan'}<textarea name="note" class="${fieldStyle}" ${active||Object.values(this.draft.cek).some(v=>v.length)?'required':''}></textarea></label><button class="${primaryStyle}">${active?'Buka revisi':'Sahkan laporan final'}</button><p data-error role="alert" class="text-rose-700"></p></form>`;
    for(const v of this.history.filter(v=>v.dibuka_pada)) html+=`<details class="glass-card rounded-2xl p-4"><summary class="cursor-pointer font-semibold">Arsip versi ${v.versi} · dibuka kembali</summary>${version(v)}</details>`;
    this.body.innerHTML='<div class="space-y-4">'+html+'</div>';
    const form=this.body.querySelector('form');
    if(!form)return;
    const amount=form.elements.amount;
    if(amount)amount.oninput=()=>{formatMoneyInput(amount);form.querySelector('[data-diff]').textContent=amount.value?'Selisih terhadap buku · '+formatRp(Number(amount.value.replaceAll('.',''))-this.draft.rekap.akhir):'Isi saldo aktual untuk melihat selisih.';};
    form.onsubmit=async e=>{
      e.preventDefault();
      const button=form.querySelector('button');button.disabled=true;
      try{
        await rpcKas('rekonsiliasi_kas',{y:this.y,m:this.m,mode:active?'revisi':'final',aktual:amount?Number(amount.value.replaceAll('.','')):null,note:form.elements.note.value,reviewed:true,expected:this.draft});
        await this.load();
      }catch(err){form.querySelector('[data-error]').textContent=err.message;button.disabled=false;}
    };
  }
}
customElements.define('monthly-close',MonthlyClose);