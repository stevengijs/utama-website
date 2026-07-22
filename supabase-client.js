/*
 * UTAMA lead capture - thin Supabase client wrapper.
 *
 * Fill in SUPABASE_URL and SUPABASE_ANON_KEY below once your Supabase project
 * exists (Supabase dashboard > Project Settings > API). Both values are safe
 * to ship in public site code: the anon key can only ever call submit_lead(),
 * it cannot read or write any table directly. See supabase/schema.sql for the
 * full setup (run that file once in the Supabase SQL Editor first).
 *
 * Until both values below are filled in, submitLead() is a harmless no-op - * the site keeps working exactly as before (forms still show the success
 * animation), it just doesn't persist leads anywhere yet.
 */
const SUPABASE_URL = "";
const SUPABASE_ANON_KEY = "";

let _sbClient = null;
function getSupabaseClient(){
  if(!SUPABASE_URL || !SUPABASE_ANON_KEY) return null;
  if(!_sbClient && window.supabase && window.supabase.createClient){
    _sbClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  }
  return _sbClient;
}

/**
 * Log a brochure request / early-access signup / any other lead form.
 * fields: { email, name, phone, project, unit, budget, when, lang }
 * Dedupes contacts by email server-side (see submit_lead in schema.sql) - * the same person requesting brochures for two projects becomes one contact
 * with two lead rows, not two contacts.
 */
async function submitLead(fields){
  const sb = getSupabaseClient();
  if(!sb) return { ok:false, reason:"not-configured" };
  try{
    const { data, error } = await sb.rpc('submit_lead', {
      p_email: fields.email,
      p_name: fields.name,
      p_phone: fields.phone,
      p_project: fields.project,
      p_unit: fields.unit || null,
      p_budget: fields.budget || null,
      p_timeline: fields.when || null,
      p_source_page: window.location.pathname,
      p_lang: fields.lang || null
    });
    if(error){ console.error("submitLead error", error); return { ok:false, error }; }
    return { ok:true, contactId:data };
  }catch(err){
    console.error("submitLead exception", err);
    return { ok:false, error:err };
  }
}
