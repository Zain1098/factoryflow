-- FactoryFlow Platform Control Center.
-- This migration is deliberately isolated from factory operations: a platform
-- administrator controls the application; workspace roles remain tenant scoped.

create table if not exists public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  active boolean not null default true,
  granted_at timestamptz not null default now(),
  granted_by uuid references auth.users(id),
  note text
);

create table if not exists public.platform_workspace_state (
  factory_id uuid primary key references public.factories(id) on delete cascade,
  status text not null default 'active' check (status in ('active', 'suspended', 'archived')),
  reason text,
  changed_at timestamptz not null default now(),
  changed_by uuid references auth.users(id)
);

create table if not exists public.platform_settings (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{1,63}$'),
  value jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create table if not exists public.platform_feature_flags (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{1,63}$'),
  label text not null,
  description text not null default '',
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create table if not exists public.platform_app_releases (
  platform text primary key check (platform in ('android')),
  version_name text not null,
  version_code integer not null check (version_code > 0),
  minimum_supported_version_code integer not null check (minimum_supported_version_code > 0 and minimum_supported_version_code <= version_code),
  download_url text not null check (download_url ~ '^https://'),
  release_notes text not null default '',
  sha256 text check (sha256 is null or sha256 ~ '^[A-Fa-f0-9]{64}$'),
  is_mandatory boolean not null default false,
  published_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create table if not exists public.platform_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references auth.users(id),
  target_user_id uuid references auth.users(id),
  factory_id uuid references public.factories(id),
  action text not null,
  result text not null check (result in ('success', 'denied', 'failed')),
  old_value jsonb,
  new_value jsonb,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);

create index if not exists platform_audit_log_time_idx on public.platform_audit_log (occurred_at desc);
create index if not exists platform_audit_log_factory_time_idx on public.platform_audit_log (factory_id, occurred_at desc);

alter table public.platform_admins enable row level security;
alter table public.platform_workspace_state enable row level security;
alter table public.platform_settings enable row level security;
alter table public.platform_feature_flags enable row level security;
alter table public.platform_app_releases enable row level security;
alter table public.platform_audit_log enable row level security;

revoke all on table public.platform_admins, public.platform_workspace_state,
  public.platform_settings, public.platform_feature_flags, public.platform_app_releases,
  public.platform_audit_log from anon, authenticated;

create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (
    select 1 from public.platform_admins pa where pa.user_id = auth.uid() and pa.active
  );
$$;

create or replace function public.platform_require_admin()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_platform_admin() then
    raise exception 'platform administrator access required';
  end if;
end;
$$;

create or replace function public.platform_audit(
  p_action text, p_result text, p_target_user_id uuid default null,
  p_factory_id uuid default null, p_old_value jsonb default null,
  p_new_value jsonb default null, p_metadata jsonb default '{}'::jsonb
)
returns void language sql security definer set search_path = '' as $$
  insert into public.platform_audit_log(actor_id, target_user_id, factory_id, action, result, old_value, new_value, metadata)
  values (auth.uid(), p_target_user_id, p_factory_id, p_action, p_result, p_old_value, p_new_value, coalesce(p_metadata, '{}'::jsonb));
$$;

create or replace function public.platform_dashboard()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.platform_require_admin();
  return jsonb_build_object(
    'users', (select count(*) from public.users),
    'blocked_users', (select count(*) from public.users where not active),
    'workspaces', (select count(*) from public.factories),
    'suspended_workspaces', (select count(*) from public.platform_workspace_state where status <> 'active'),
    'maintenance', coalesce((select value from public.platform_settings where key = 'maintenance'), '{"enabled":false,"title":"Scheduled maintenance","message":"We will be back shortly."}'::jsonb),
    'release', coalesce((select jsonb_build_object('version_name', version_name, 'version_code', version_code, 'is_mandatory', is_mandatory, 'published_at', published_at) from public.platform_app_releases where platform = 'android'), '{}'::jsonb),
    'recent_events', coalesce((select jsonb_agg(x) from (select action, result, occurred_at from public.platform_audit_log order by occurred_at desc limit 8) x), '[]'::jsonb)
  );
end;
$$;

-- Authenticated mobile clients can read only the public maintenance message.
-- Platform admins bypass the maintenance gate in the mobile application.
create or replace function public.platform_maintenance_status()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.platform_settings where key = 'maintenance'), '{"enabled":false,"title":"Scheduled maintenance","message":"We will be back shortly."}'::jsonb);
$$;

-- Mobile clients receive only global, non-sensitive release and feature state;
-- they cannot read or mutate the backing platform-control tables directly.
create or replace function public.platform_android_release()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select jsonb_build_object(
    'version_name', version_name, 'version_code', version_code,
    'minimum_supported_version_code', minimum_supported_version_code,
    'download_url', download_url, 'release_notes', release_notes,
    'sha256', sha256, 'is_mandatory', is_mandatory, 'published_at', published_at
  ) from public.platform_app_releases where platform = 'android'), '{}'::jsonb);
$$;

create or replace function public.platform_enabled_feature_flags()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(key, enabled), '{}'::jsonb)
  from public.platform_feature_flags;
$$;

create or replace function public.platform_list_users(p_query text default '', p_limit integer default 50, p_offset integer default 0)
returns table(id uuid, name text, email text, role text, active boolean, factory_id uuid, workspace_name text)
language sql stable security definer set search_path = '' as $$
  select u.id, coalesce(u.name, ''), coalesce(u.email, ''), coalesce(u.role, ''), coalesce(u.active, true), u.factory_id, coalesce(f.name, '')
  from public.users u left join public.factories f on f.id = u.factory_id
  where public.is_platform_admin()
    and (coalesce(p_query, '') = '' or u.name ilike '%' || p_query || '%' or u.email ilike '%' || p_query || '%' or f.name ilike '%' || p_query || '%')
  order by u.name nulls last, u.email
  limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0);
$$;

create or replace function public.platform_list_workspaces(p_query text default '', p_limit integer default 50, p_offset integer default 0)
returns table(id uuid, name text, active boolean, status text, member_count bigint, reason text)
language sql stable security definer set search_path = '' as $$
  select f.id, f.name, coalesce(f.active, true), coalesce(s.status, 'active'), count(wm.id), s.reason
  from public.factories f
  left join public.platform_workspace_state s on s.factory_id = f.id
  left join public.workspace_members wm on wm.workspace_id = f.id and lower(wm.status) = 'active'
  where public.is_platform_admin()
    and (coalesce(p_query, '') = '' or f.name ilike '%' || p_query || '%')
  group by f.id, f.name, f.active, s.status, s.reason
  order by f.name
  limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0);
$$;

create or replace function public.platform_set_user_block(p_user_id uuid, p_blocked boolean, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_old boolean;
begin
  perform public.platform_require_admin();
  if p_user_id = auth.uid() then raise exception 'you cannot block your own platform account'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required'; end if;
  select active into v_old from public.users where id = p_user_id for update;
  if not found then raise exception 'user not found'; end if;
  update public.users set active = not p_blocked where id = p_user_id;
  perform public.platform_audit(case when p_blocked then 'user_blocked' else 'user_unblocked' end, 'success', p_user_id, null, jsonb_build_object('active', v_old), jsonb_build_object('active', not p_blocked), jsonb_build_object('reason', btrim(p_reason)));
end;
$$;

create or replace function public.platform_set_workspace_status(p_factory_id uuid, p_status text, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_old text;
begin
  perform public.platform_require_admin();
  if p_status not in ('active', 'suspended', 'archived') or coalesce(btrim(p_reason), '') = '' then raise exception 'a valid status and reason are required'; end if;
  if not exists (select 1 from public.factories where id = p_factory_id) then raise exception 'workspace not found'; end if;
  select status into v_old from public.platform_workspace_state where factory_id = p_factory_id;
  insert into public.platform_workspace_state(factory_id, status, reason, changed_at, changed_by)
  values (p_factory_id, p_status, btrim(p_reason), now(), auth.uid())
  on conflict (factory_id) do update set status = excluded.status, reason = excluded.reason, changed_at = excluded.changed_at, changed_by = excluded.changed_by;
  perform public.platform_audit('workspace_status_changed', 'success', null, p_factory_id, jsonb_build_object('status', coalesce(v_old, 'active')), jsonb_build_object('status', p_status), jsonb_build_object('reason', btrim(p_reason)));
end;
$$;

create or replace function public.platform_set_maintenance(p_enabled boolean, p_title text, p_message text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_value jsonb;
begin
  perform public.platform_require_admin();
  if coalesce(btrim(p_title), '') = '' or coalesce(btrim(p_message), '') = '' then raise exception 'title and message are required'; end if;
  v_value := jsonb_build_object('enabled', p_enabled, 'title', btrim(p_title), 'message', btrim(p_message), 'changed_at', now());
  insert into public.platform_settings(key, value, updated_at, updated_by) values ('maintenance', v_value, now(), auth.uid())
  on conflict(key) do update set value = excluded.value, updated_at = excluded.updated_at, updated_by = excluded.updated_by;
  perform public.platform_audit('maintenance_changed', 'success', null, null, null, v_value);
end;
$$;

create or replace function public.platform_list_feature_flags()
returns table(key text, label text, description text, enabled boolean, updated_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select key, label, description, enabled, updated_at from public.platform_feature_flags
  where public.is_platform_admin() order by key;
$$;

create or replace function public.platform_set_feature_flag(p_key text, p_enabled boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare v_old boolean;
begin
  perform public.platform_require_admin();
  select enabled into v_old from public.platform_feature_flags where key = p_key for update;
  if not found then raise exception 'feature flag not found'; end if;
  update public.platform_feature_flags set enabled = p_enabled, updated_at = now(), updated_by = auth.uid() where key = p_key;
  perform public.platform_audit('feature_flag_changed', 'success', null, null, jsonb_build_object('key', p_key, 'enabled', v_old), jsonb_build_object('key', p_key, 'enabled', p_enabled));
end;
$$;

create or replace function public.platform_publish_android_release(p_version_name text, p_version_code integer, p_minimum_supported_version_code integer, p_download_url text, p_release_notes text, p_sha256 text default null, p_is_mandatory boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.platform_require_admin();
  if p_version_code <= 0 or p_minimum_supported_version_code <= 0 or p_minimum_supported_version_code > p_version_code then raise exception 'invalid Android version codes'; end if;
  if coalesce(p_download_url, '') !~ '^https://' then raise exception 'download URL must use HTTPS'; end if;
  if p_sha256 is not null and p_sha256 !~ '^[A-Fa-f0-9]{64}$' then raise exception 'SHA-256 must be 64 hexadecimal characters'; end if;
  insert into public.platform_app_releases(platform, version_name, version_code, minimum_supported_version_code, download_url, release_notes, sha256, is_mandatory, published_at, updated_by)
  values ('android', btrim(p_version_name), p_version_code, p_minimum_supported_version_code, btrim(p_download_url), coalesce(p_release_notes, ''), nullif(btrim(p_sha256), ''), p_is_mandatory, now(), auth.uid())
  on conflict(platform) do update set version_name = excluded.version_name, version_code = excluded.version_code, minimum_supported_version_code = excluded.minimum_supported_version_code, download_url = excluded.download_url, release_notes = excluded.release_notes, sha256 = excluded.sha256, is_mandatory = excluded.is_mandatory, published_at = excluded.published_at, updated_by = excluded.updated_by;
  perform public.platform_audit('android_release_published', 'success', null, null, null, jsonb_build_object('version_name', p_version_name, 'version_code', p_version_code, 'mandatory', p_is_mandatory));
end;
$$;

create or replace function public.platform_list_audit(p_limit integer default 100)
returns table(id uuid, action text, result text, actor_id uuid, target_user_id uuid, factory_id uuid, metadata jsonb, occurred_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select id, action, result, actor_id, target_user_id, factory_id, metadata, occurred_at
  from public.platform_audit_log where public.is_platform_admin()
  order by occurred_at desc limit least(greatest(p_limit, 1), 100);
$$;

revoke all on function public.is_platform_admin(), public.platform_require_admin(), public.platform_audit(text,text,uuid,uuid,jsonb,jsonb,jsonb), public.platform_dashboard(), public.platform_list_users(text,integer,integer), public.platform_list_workspaces(text,integer,integer), public.platform_set_user_block(uuid,boolean,text), public.platform_set_workspace_status(uuid,text,text), public.platform_set_maintenance(boolean,text,text), public.platform_list_feature_flags(), public.platform_set_feature_flag(text,boolean), public.platform_publish_android_release(text,integer,integer,text,text,text,boolean), public.platform_list_audit(integer), public.platform_maintenance_status(), public.platform_android_release(), public.platform_enabled_feature_flags() from public, anon, authenticated;
grant execute on function public.is_platform_admin(), public.platform_dashboard(), public.platform_list_users(text,integer,integer), public.platform_list_workspaces(text,integer,integer), public.platform_set_user_block(uuid,boolean,text), public.platform_set_workspace_status(uuid,text,text), public.platform_set_maintenance(boolean,text,text), public.platform_list_feature_flags(), public.platform_set_feature_flag(text,boolean), public.platform_publish_android_release(text,integer,integer,text,text,text,boolean), public.platform_list_audit(integer), public.platform_maintenance_status(), public.platform_android_release(), public.platform_enabled_feature_flags() to authenticated;

-- Bootstrap only after creating the Supabase Auth account through a trusted
-- dashboard/server session. Never insert passwords in this migration or frontend.
-- insert into public.platform_admins (user_id, note)
-- select id, 'Initial platform administrator' from auth.users
-- where email = '<your-admin-email>'
-- on conflict (user_id) do update set active = true;
