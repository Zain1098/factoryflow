-- Platform administrators need the last saved URL to avoid re-entering it,
-- while the mobile release RPC continues to expose only public update metadata.
create or replace function public.platform_dashboard()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.platform_require_admin();
  return jsonb_build_object(
    'users', (select count(*) from public.users),
    'blocked_users', (select count(*) from public.users where coalesce(active, true) = false),
    'workspaces', (select count(*) from public.factories),
    'suspended_workspaces', (select count(*) from public.platform_workspace_state where status <> 'active'),
    'maintenance', coalesce((select value from public.platform_settings where key = 'maintenance'), '{"enabled":false,"title":"Scheduled maintenance","message":"We will be back shortly."}'::jsonb),
    'release', coalesce((select jsonb_build_object(
      'version_name', version_name,
      'version_code', version_code,
      'download_url', download_url,
      'is_mandatory', is_mandatory,
      'published_at', published_at
    ) from public.platform_app_releases where platform = 'android'), '{}'::jsonb),
    'recent_events', coalesce((select jsonb_agg(x) from (select action, result, occurred_at from public.platform_audit_log order by occurred_at desc limit 8) x), '[]'::jsonb)
  );
end;
$$;
