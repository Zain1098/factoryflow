import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (request.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405);
  }

  const authorization = request.headers.get('Authorization');
  const token = authorization?.replace(/^Bearer\s+/i, '').trim();
  const projectUrl = Deno.env.get('SUPABASE_URL');
  const secretKey =
    Deno.env.get('SUPABASE_SECRET_KEY') ??
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!token || !projectUrl || !secretKey) {
    return json({ error: 'server_not_configured' }, 500);
  }

  const admin = createClient(projectUrl, secretKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  if (authError || !authData.user) {
    return json({ error: 'not_authenticated' }, 401);
  }

  const { data: profile, error: profileError } = await admin
    .from('users')
    .select('active')
    .eq('id', authData.user.id)
    .maybeSingle();
  if (profileError) return json({ error: 'profile_lookup_failed' }, 500);
  if (!profile || profile.active !== false) {
    return json({ error: 'account_deletion_not_requested' }, 409);
  }

  // public.users, backup_records and account_audit_log are deliberately not
  // deleted, so the admin panel retains the account's history.
  const { error: deleteError } = await admin.auth.admin.deleteUser(
    authData.user.id,
    false,
  );
  if (deleteError) return json({ error: 'auth_delete_failed' }, 500);
  return json({ success: true });
});
