import { createClient } from "npm:@supabase/supabase-js@2.49.8";
const headers = {"Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info", "Cache-Control":"no-store"};
const reply = (data:unknown,status=200)=>Response.json(data,{status,headers});
const options={auth:{persistSession:false,autoRefreshToken:false}};
const defaultPassword="ipd32";
// Auth requires six characters. Give each default account a distinct internal credential.
function credential(password:string,email:string) {
  return password===defaultPassword ? "initial/"+email : password;
}
Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response(null,{headers});
  if(req.method!=="POST")return reply({error:"Gunakan POST."},405);
  const url=Deno.env.get("SUPABASE_URL")!;
  const anon=Deno.env.get("SUPABASE_ANON_KEY")!;
  const admin=createClient(url,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,options);
  const auth=createClient(url,anon,options);
  try{
    const {aksi,username,password,baru}=await req.json();
    if(!["login","ubah","atur"].includes(aksi)||typeof username!=="string"||!username.trim()||username.length>160)return reply({error:"Permintaan tidak valid."},400);
    if(aksi!=="atur"&&(typeof password!=="string"||!password||password.length>256))return reply({error:"Masukkan kata sandi."},400);
    if(aksi!=="login"&&(typeof baru!=="string"||baru.length>256||(baru!==defaultPassword&&baru.length<6)))return reply({error:"Gunakan minimal 6 karakter atau kata sandi awal."},400);
    const denied=()=>reply({error:"Username atau kata sandi salah."},401);
    let actor;
    if(aksi!=="login"){
      const caller=createClient(url,anon,{...options,global:{headers:{Authorization:req.headers.get("Authorization")||""}}});
      const {data,error}=await caller.rpc("identitas_kas");
      if(error||!data||(aksi==="atur"?data.role!=="admin":data.role!=="anggota"))return reply({error:"Akses ditolak."},403);
      actor=data;
    }
    const lookup=await admin.rpc("akun_login_kas",{uname:username});
    if(lookup.error)throw lookup.error;
    let account=lookup.data;
    if(!account)return aksi==="atur"?reply({error:"Anggota tidak ditemukan."},404):denied();
    if(aksi==="ubah"&&account.member!==actor.id)return reply({error:"Akses ditolak."},403);
    if(!account.uid){
      if(aksi==="ubah"||(aksi==="login"&&password!==defaultPassword))return denied();
      const email=crypto.randomUUID()+"@anggota.invalid";
      const created=await admin.auth.admin.createUser({email,password:credential(aksi==="atur"?baru:defaultPassword,email),email_confirm:true});
      if(created.error)throw created.error;
      const uid=created.data.user.id;
      const linked=await admin.rpc("akun_login_kas",{uname:username,calon:uid});
      if(!linked.error&&linked.data?.uid!==uid)await admin.auth.admin.deleteUser(uid);
      if(linked.error||!linked.data)throw new Error("Pendaftaran gagal");
      account=linked.data;
      if(aksi==="atur"&&account.uid===uid)return reply({ok:true});
    }
    if(aksi!=="atur"){
      const {data,error}=await auth.auth.signInWithPassword({email:account.email,password:credential(password,account.email)});
      if(error||!data.session)return denied();
      if(aksi==="login")return reply({access_token:data.session.access_token,refresh_token:data.session.refresh_token});
    }
    const changed=await admin.auth.admin.updateUserById(account.uid,{password:credential(baru,account.email)});
    if(changed.error)return reply({error:"Kata sandi gagal diperbarui. Periksa kata sandi baru."},400);
    return reply({ok:true});
  }catch{return reply({error:"Layanan akun belum tersedia. Coba kembali."},503);}
});