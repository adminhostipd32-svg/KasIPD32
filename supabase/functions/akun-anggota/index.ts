import { createClient } from "npm:@supabase/supabase-js@2.49.8";
const headers = {"Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info", "Cache-Control":"no-store"};
const reply = (data: unknown, status = 200) => Response.json(data, {status, headers});
Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response(null, {headers});
  if (req.method !== "POST") return reply({error:"Gunakan POST."},405);
  const url = Deno.env.get("SUPABASE_URL")!;
  const options = {auth:{persistSession:false,autoRefreshToken:false}};
  const admin = createClient(url,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,options);
  const auth = createClient(url,Deno.env.get("SUPABASE_ANON_KEY")!,options);
  try {
    const {aksi,username,password,kode} = await req.json();
    if (typeof username !== "string" || username.length > 160 || typeof password !== "string" || password.length > 256) return reply({error:"Isian tidak valid."},400);
    let email;
    if (aksi === "aktivasi") {
      if (password.length < 10 || typeof kode !== "string" || kode.length !== 36) return reply({error:"Gunakan kode dari pengurus dan kata sandi minimal 10 karakter."},400);
      const claim = await admin.rpc("provisi_kas",{aksi:"klaim",uname:username,kode});
      if (claim.error) return reply({error:"Kode atau username tidak cocok, atau kode kedaluwarsa."},400);
      email = crypto.randomUUID()+"@anggota.invalid";
      const created = await admin.auth.admin.createUser({email,password,email_confirm:true});
      if (created.error) return reply({error:"Akun belum dapat dibuat. Minta kode baru."},400);
      const linked = await admin.rpc("provisi_kas",{aksi:"hubungkan",uname:username,uid:created.data.user.id,gen:claim.data});
      if (linked.error) {
        await admin.auth.admin.deleteUser(created.data.user.id);
        return reply({error:"Aktivasi berubah. Minta kode baru."},409);
      }
    } else if (aksi === "login") {
      const lookup = await admin.rpc("provisi_kas",{aksi:"login",uname:username});
      if (lookup.error) return reply({error:"Layanan akun belum tersedia."},503);
      email = lookup.data || "unassigned@anggota.invalid";
    } else return reply({error:"Aksi tidak valid."},400);
    const {data,error} = await auth.auth.signInWithPassword({email,password});
    if (error || !data.session) return reply({error:"Username atau kata sandi tidak cocok. Jika baru pertama masuk, gunakan kode aktivasi."},401);
    return reply({access_token:data.session.access_token, refresh_token:data.session.refresh_token});
  } catch {
    return reply({error:"Permintaan belum dapat diproses."},400);
  }
});
