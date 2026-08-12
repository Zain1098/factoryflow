import { createClient } from 'npm:@supabase/supabase-js@2';

const fixedDownloadUrl =
  'https://github.com/Zain1098/factoryflow_app_release_version/releases/download/factoryflow/app-release.apk';

const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });

function validPositiveInt(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value > 0;
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const releaseToken = Deno.env.get('RELEASE_PUBLISH_TOKEN');
  const suppliedToken = request.headers.get('x-release-publish-token');
  const projectUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY');
  if (!releaseToken || !projectUrl || !serviceKey) {
    return json({ error: 'server_not_configured' }, 500);
  }
  if (!suppliedToken || suppliedToken !== releaseToken) {
    return json({ error: 'not_authorized' }, 401);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch (_) {
    return json({ error: 'invalid_json' }, 400);
  }
  const versionName = typeof payload.version_name === 'string' ? payload.version_name.trim() : '';
  const versionCode = payload.version_code;
  const minimumCode = payload.minimum_supported_version_code;
  const releaseNotes = typeof payload.release_notes === 'string' ? payload.release_notes.trim() : '';
  const sha256 = typeof payload.sha256 === 'string' && payload.sha256.trim() ? payload.sha256.trim().toLowerCase() : null;
  const isMandatory = payload.is_mandatory === true;

  if (!versionName || versionName.length > 80 || !validPositiveInt(versionCode) ||
      !validPositiveInt(minimumCode) || minimumCode > versionCode ||
      releaseNotes.length > 4000 ||
      (sha256 !== null && !/^[a-f0-9]{64}$/.test(sha256))) {
    return json({ error: 'invalid_release_metadata' }, 400);
  }

  const admin = createClient(projectUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const release = {
    channel: 'android', version_name: versionName, version_code: versionCode,
    minimum_supported_version_code: minimumCode, download_url: fixedDownloadUrl,
    release_notes: releaseNotes, sha256, is_mandatory: isMandatory,
    published_at: new Date().toISOString(), published_by: 'github-actions',
  };
  const { error: releaseError } = await admin
    .from('platform_app_releases')
    .upsert(release, { onConflict: 'channel' });
  if (releaseError) return json({ error: 'release_publish_failed' }, 500);

  const { error: auditError } = await admin.from('platform_audit_log').insert({
    action: 'android_release_published', result: 'success', new_value: release,
    metadata: { source: 'github-actions', fixed_download_url: fixedDownloadUrl },
  });
  if (auditError) return json({ error: 'audit_write_failed' }, 500);
  return json({ success: true, version_code: versionCode });
});
