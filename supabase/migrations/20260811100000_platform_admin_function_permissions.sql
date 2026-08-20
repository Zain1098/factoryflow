-- Explicitly remove Supabase's authenticated default EXECUTE grant from
-- internal SECURITY DEFINER helpers. Public RPCs are regranted narrowly below.

revoke all on function public.platform_require_admin() from public, anon, authenticated;
revoke all on function public.platform_audit(text,text,uuid,uuid,jsonb,jsonb,jsonb) from public, anon, authenticated;

grant execute on function public.is_platform_admin(), public.platform_dashboard(), public.platform_list_users(text,integer,integer), public.platform_list_workspaces(text,integer,integer), public.platform_set_user_block(uuid,boolean,text), public.platform_set_workspace_status(uuid,text,text), public.platform_set_maintenance(boolean,text,text), public.platform_list_feature_flags(), public.platform_set_feature_flag(text,boolean), public.platform_publish_android_release(text,integer,integer,text,text,text,boolean), public.platform_list_audit(integer), public.platform_maintenance_status(), public.platform_android_release(), public.platform_enabled_feature_flags() to authenticated;
