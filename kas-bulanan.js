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
async function akunRequest(body,token) {
  const headers={apikey:DB.key,'Content-Type':'application/json'};
  if(token) headers.Authorization='Bearer '+token;
  const response=await fetch(new URL('/functions/v1/akun-anggota',DB.url),{method:'POST',headers,body:JSON.stringify(body)});
  const result=await response.json();
  if(!response.ok)throw new Error(result.error || 'Layanan akun belum tersedia.');
  return result;
}
async function memberSignIn(username,password) {
  const result=await akunRequest({aksi:'login',username,password});
  const {error}=await DB.client.auth.setSession(result);
  if(error)throw error;
}
async function loginKas(identifier,password) {
  if(!DB.client) throw new Error('Koneksi Supabase belum tersedia. Muat ulang halaman.');
  if(identifier.includes('@')) {
    const {error}=await DB.client.auth.signInWithPassword({email:identifier,password});
    if(error) throw error;
  } else await memberSignIn(identifier,password);
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

  resetAuditView();
  closeModal();
}

function openSupportPasswordSetup() {
  openModal(`<form id="support-setup" class="p-5 space-y-4">
    <h2 class="text-lg font-bold">Buat kata sandi IT Support</h2>
    <p class="text-sm">Gunakan kata sandi ini untuk masuk kembali dengan email IT Support.</p>
    <label class="block">Kata sandi baru<input class="${fieldStyle}" name="password" type="password" autocomplete="new-password" minlength="8" required></label>
    <label class="block">Ulangi kata sandi<input class="${fieldStyle}" name="confirm" type="password" autocomplete="new-password" required></label>
    <p class="text-rose-700" role="alert"></p><button class="${primaryStyle}" type="submit">Simpan kata sandi</button></form>`);
  document.getElementById('support-setup').onsubmit = async event => {
    event.preventDefault();
    const form=event.currentTarget, alert=form.querySelector('[role=alert]'), button=form.querySelector('button');
    if(form.elements.password.value!==form.elements.confirm.value){alert.textContent='Kedua kata sandi harus sama.';return;}
    button.disabled=true;
    try {
      const {error}=await DB.client.auth.updateUser({password:form.elements.password.value,data:{kas_perlu_sandi:false}});
      if(error)throw error;
      closeModal();showToast('Kata sandi IT Support tersimpan.','success');
    } catch(error){alert.textContent=error.message;button.disabled=false;}
  };
}

async function periksaLaporan(button) {
  const y=Number(button.previousElementSibling.value);
  const panel=button.parentElement.nextElementSibling;
  button.disabled=true;
  try{
    const hasil=await rpcKas('periksa_laporan_kas',{y});
    panel.innerHTML=[['anggota','Status anggota tanpa bulan atau tahun efektif'],['peserta','Peserta acara belum terhubung ke anggota'],['acara','Acara dengan dampak kas belum diposting']].map(([k,label])=>`<details class="mt-2 border rounded-xl p-3"><summary>${label} · ${hasil[k].length}</summary><p class="text-sm mt-2">${hasil[k].map(r=>escapeHtml(r.nama)+(r.event?' · '+escapeHtml(r.event):'')).join('<br>')||'Tidak ada temuan.'}</p></details>`).join('');
  }catch(e){panel.textContent=e.message;}
  finally{button.disabled=false;}
}
function financialReports() {
  if(!staffAccess()){
    const member=State.data.anggota.find(m=>m.id===State.session.id);
    if(!member)return '<p>Data anggota belum tersedia.</p>';
    return `<header class="report-banner personal-banner mb-4"><div><h1>Laporan saya</h1><p>Tagihan iuran dan patungan</p></div><label>Tahun <select class="${fieldStyle}" onchange="State.personalYear=Number(this.value);renderApp()">${yearOptions(State.personalYear)}</select></label></header>${memberBalanceCard(member,State.personalYear,12,false)}`;
  }
  const year=State.reportYear||State.selectedYear;
  return renderReportPage()+`<details class="glass-card rounded-2xl p-4 mt-5"><summary class="cursor-pointer font-semibold">Pemeriksaan data laporan</summary><div class="flex items-center gap-2 mt-3"><label for="check-year">Tahun</label><select id="check-year" class="border rounded-lg p-2" onchange="this.parentElement.nextElementSibling.textContent=''">${getAvailableYears().map(y=>`<option ${y===year?'selected':''}>${y}</option>`).join('')}</select><button class="${secondaryStyle}" onclick="periksaLaporan(this)">Periksa data</button></div><div aria-live="polite"></div></details>`;
}
