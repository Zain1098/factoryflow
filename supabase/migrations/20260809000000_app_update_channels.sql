-- One current Android release per workspace. APK binaries stay on GitHub Releases;
-- this table contains only the signed-in app's update metadata.
create table if not exists public.app_update_channels (
  id uuid primary key default gen_random_uuid(),
  factory_id uuid not null references public.factories(id) on delete cascade,
  platform text not null default 'android' check (platform in ('android')),
  version_name text not null check (version_name ~ '^[0-9]+(\.[0-9]+){1,3}([+-][0-9A-Za-z.-]+)?$'),
  version_code integer not null check (version_code > 0),
  minimum_supported_version_code integer not null check (minimum_supported_version_code > 0 and minimum_supported_version_code <= version_code),
  download_url text not null check (download_url ~ '^https://'),
  release_notes text not null default '',
  sha256 text check (sha256 is null or sha256 ~ '^[A-Fa-f0-9]{64}$'),
  is_mandatory boolean not null default false,
  published_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id) default auth.uid(),
  updated_by uuid references auth.users(id) default auth.uid(),
  unique (factory_id, platform)
);

create index if not exists app_update_channels_factory_platform_idx
  on public.app_update_channels (factory_id, platform);

alter table public.app_update_channels enable row level security;

create or replace function public.set_app_update_channel_audit_fields()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at = now();
  new.updated_by = auth.uid();
  if tg_op = 'INSERT' then
    new.created_by = auth.uid();
  end if;
  return new;
end;
$$;

revoke all on function public.set_app_update_channel_audit_fields() from public;

drop trigger if exists set_app_update_channel_audit_fields on public.app_update_channels;
create trigger set_app_update_channel_audit_fields
before insert or update on public.app_update_channels
for each row execute function public.set_app_update_channel_audit_fields();

drop policy if exists "Active members can read their workspace app update" on public.app_update_channels;
create policy "Active members can read their workspace app update"
on public.app_update_channels for select to authenticated
using (
  exists (
    select 1 from public.workspace_members wm
    where wm.workspace_id = app_update_channels.factory_id
      and wm.user_id = (select auth.uid())
      and lower(wm.status) = 'active'
  )
);

drop policy if exists "Workspace admins can create app updates" on public.app_update_channels;
create policy "Workspace admins can create app updates"
on public.app_update_channels for insert to authenticated
with check (
  exists (
    select 1 from public.workspace_members wm
    where wm.workspace_id = app_update_channels.factory_id
      and wm.user_id = (select auth.uid())
      and lower(wm.status) = 'active'
      and lower(wm.role) in ('owner', 'admin')
  )
);

drop policy if exists "Workspace admins can update app updates" on public.app_update_channels;
create policy "Workspace admins can update app updates"
on public.app_update_channels for update to authenticated
using (
  exists (
    select 1 from public.workspace_members wm
    where wm.workspace_id = app_update_channels.factory_id
      and wm.user_id = (select auth.uid())
      and lower(wm.status) = 'active'
      and lower(wm.role) in ('owner', 'admin')
  )
)
with check (
  exists (
    select 1 from public.workspace_members wm
    where wm.workspace_id = app_update_channels.factory_id
      and wm.user_id = (select auth.uid())
      and lower(wm.status) = 'active'
      and lower(wm.role) in ('owner', 'admin')
  )
);

grant select, insert, update on public.app_update_channels to authenticated;
