-- Platform-control surface. This deliberately does not change manufacturing
-- records: factories remain the tenant identifier used by operational flows.

CREATE TABLE IF NOT EXISTS public.platform_admins (
  user_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  active boolean NOT NULL DEFAULT true,
  granted_at timestamptz NOT NULL DEFAULT now(),
  granted_by uuid REFERENCES public.users(id),
  note text
);

CREATE TABLE IF NOT EXISTS public.platform_workspace_state (
  workspace_id uuid PRIMARY KEY REFERENCES public.factories(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'suspended', 'archived')),
  reason text,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by uuid REFERENCES public.users(id)
);

CREATE TABLE IF NOT EXISTS public.platform_settings (
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.users(id)
);

CREATE TABLE IF NOT EXISTS public.platform_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid REFERENCES public.users(id),
  target_user_id uuid REFERENCES public.users(id),
  workspace_id uuid REFERENCES public.factories(id),
  action text NOT NULL,
  result text NOT NULL CHECK (result IN ('success', 'denied', 'failed')),
  old_value jsonb,
  new_value jsonb,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.platform_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  body text NOT NULL,
  severity text NOT NULL DEFAULT 'info'
    CHECK (severity IN ('info', 'warning', 'critical')),
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_platform_audit_time ON public.platform_audit_log(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_platform_audit_workspace_time ON public.platform_audit_log(workspace_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_platform_audit_target_time ON public.platform_audit_log(target_user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_platform_notifications_recipient ON public.platform_notifications(recipient_id, read_at, created_at DESC);

ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_workspace_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.platform_admins, public.platform_workspace_state,
  public.platform_settings, public.platform_audit_log, public.platform_notifications
  FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.is_platform_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.platform_admins pa
    WHERE pa.user_id = auth.uid() AND pa.active
  );
$$;

-- Suspension is deliberately included in the existing membership helpers so
-- every newer tenant-scoped RLS policy using them stops granting access.
CREATE OR REPLACE FUNCTION public.get_my_workspace_ids()
RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT wm.workspace_id FROM public.workspace_members wm
  JOIN public.users u ON u.id = wm.user_id AND u.active
  LEFT JOIN public.platform_workspace_state pws ON pws.workspace_id = wm.workspace_id
  WHERE wm.user_id = auth.uid() AND wm.status = 'active'
    AND COALESCE(pws.status, 'active') = 'active';
$$;

CREATE OR REPLACE FUNCTION public.get_my_workspace_role(p_workspace_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER STABLE SET search_path = '' AS $$
  SELECT CASE WHEN wm.role = 'owner' THEN 'owner' ELSE wm.role END
  FROM public.workspace_members wm
  JOIN public.users u ON u.id = wm.user_id AND u.active
  LEFT JOIN public.platform_workspace_state pws ON pws.workspace_id = wm.workspace_id
  WHERE wm.workspace_id = p_workspace_id AND wm.user_id = auth.uid()
    AND wm.status = 'active' AND COALESCE(pws.status, 'active') = 'active';
$$;

CREATE OR REPLACE FUNCTION public.platform_require_admin()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'platform administrator access required'; END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.platform_dashboard()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.platform_require_admin();
  RETURN jsonb_build_object(
    'workspaces', (SELECT count(*) FROM public.factories),
    'active_users', (SELECT count(*) FROM public.users WHERE active),
    'blocked_users', (SELECT count(*) FROM public.users WHERE NOT active),
    'pending_invites', (SELECT count(*) FROM public.workspace_invites WHERE status = 'pending'),
    'maintenance', COALESCE((SELECT value FROM public.platform_settings WHERE key = 'maintenance'), '{"enabled":false}'::jsonb),
    'recent_events', COALESCE((SELECT jsonb_agg(x) FROM (SELECT action, result, occurred_at FROM public.platform_audit_log ORDER BY occurred_at DESC LIMIT 8) x), '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.platform_maintenance_status()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((SELECT value FROM public.platform_settings WHERE key = 'maintenance'), '{"enabled":false}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION public.platform_list_users(p_query text DEFAULT '', p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS TABLE(id uuid, name text, email text, role text, active boolean, factory_id uuid, workspace_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT u.id, u.name, u.email, u.role, u.active, u.factory_id, f.name
  FROM public.users u JOIN public.factories f ON f.id = u.factory_id
  WHERE public.is_platform_admin()
    AND (coalesce(p_query, '') = '' OR u.name ILIKE '%' || p_query || '%' OR u.email ILIKE '%' || p_query || '%' OR f.name ILIKE '%' || p_query || '%')
  ORDER BY u.name NULLS LAST, u.email LIMIT LEAST(GREATEST(p_limit, 1), 100) OFFSET GREATEST(p_offset, 0);
$$;

CREATE OR REPLACE FUNCTION public.platform_list_workspaces(p_query text DEFAULT '', p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS TABLE(id uuid, name text, active boolean, status text, member_count bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT f.id, f.name, f.active, COALESCE(s.status, 'active'), count(wm.id)
  FROM public.factories f LEFT JOIN public.platform_workspace_state s ON s.workspace_id = f.id
  LEFT JOIN public.workspace_members wm ON wm.workspace_id = f.id AND wm.status = 'active'
  WHERE public.is_platform_admin() AND (coalesce(p_query, '') = '' OR f.name ILIKE '%' || p_query || '%')
  GROUP BY f.id, f.name, f.active, s.status ORDER BY f.name
  LIMIT LEAST(GREATEST(p_limit, 1), 100) OFFSET GREATEST(p_offset, 0);
$$;

CREATE OR REPLACE FUNCTION public.platform_set_user_block(p_user_id uuid, p_blocked boolean, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_old boolean;
BEGIN
  PERFORM public.platform_require_admin();
  IF p_user_id = auth.uid() THEN RAISE EXCEPTION 'you cannot block your own platform account'; END IF;
  IF coalesce(btrim(p_reason), '') = '' THEN RAISE EXCEPTION 'a reason is required'; END IF;
  SELECT active INTO v_old FROM public.users WHERE id = p_user_id FOR UPDATE;
  IF v_old IS NULL THEN RAISE EXCEPTION 'user not found'; END IF;
  UPDATE public.users SET active = NOT p_blocked WHERE id = p_user_id;
  INSERT INTO public.platform_audit_log(actor_id,target_user_id,action,result,old_value,new_value,metadata)
  VALUES (auth.uid(),p_user_id,CASE WHEN p_blocked THEN 'user_blocked' ELSE 'user_unblocked' END,'success',jsonb_build_object('active',v_old),jsonb_build_object('active',NOT p_blocked),jsonb_build_object('reason',btrim(p_reason)));
END;
$$;

CREATE OR REPLACE FUNCTION public.platform_set_workspace_status(p_workspace_id uuid, p_status text, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM public.platform_require_admin();
  IF p_status NOT IN ('active','suspended','archived') OR coalesce(btrim(p_reason),'') = '' THEN RAISE EXCEPTION 'a valid status and reason are required'; END IF;
  PERFORM 1 FROM public.factories WHERE id = p_workspace_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'workspace not found'; END IF;
  INSERT INTO public.platform_workspace_state(workspace_id,status,reason,changed_at,changed_by)
  VALUES(p_workspace_id,p_status,btrim(p_reason),now(),auth.uid())
  ON CONFLICT(workspace_id) DO UPDATE SET status=EXCLUDED.status,reason=EXCLUDED.reason,changed_at=EXCLUDED.changed_at,changed_by=EXCLUDED.changed_by;
  INSERT INTO public.platform_audit_log(actor_id,workspace_id,action,result,new_value,metadata)
  VALUES(auth.uid(),p_workspace_id,'workspace_status_changed','success',jsonb_build_object('status',p_status),jsonb_build_object('reason',btrim(p_reason)));
END;
$$;

CREATE OR REPLACE FUNCTION public.platform_set_maintenance(p_enabled boolean, p_title text, p_message text, p_starts_at timestamptz DEFAULT NULL, p_ends_at timestamptz DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_value jsonb;
BEGIN
  PERFORM public.platform_require_admin();
  IF coalesce(btrim(p_title),'') = '' OR coalesce(btrim(p_message),'') = '' THEN RAISE EXCEPTION 'title and message are required'; END IF;
  IF p_ends_at IS NOT NULL AND p_starts_at IS NOT NULL AND p_ends_at <= p_starts_at THEN RAISE EXCEPTION 'end time must be after start time'; END IF;
  v_value := jsonb_build_object('enabled',p_enabled,'title',btrim(p_title),'message',btrim(p_message),'starts_at',p_starts_at,'ends_at',p_ends_at,'bypass_roles',jsonb_build_array('platform_admin'));
  INSERT INTO public.platform_settings(key,value,updated_at,updated_by) VALUES('maintenance',v_value,now(),auth.uid())
  ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value,updated_at=EXCLUDED.updated_at,updated_by=EXCLUDED.updated_by;
  INSERT INTO public.platform_audit_log(actor_id,action,result,new_value) VALUES(auth.uid(),'maintenance_changed','success',v_value);
END;
$$;

CREATE OR REPLACE FUNCTION public.platform_list_audit(p_limit integer DEFAULT 100)
RETURNS TABLE(id uuid, actor_id uuid, target_user_id uuid, workspace_id uuid, action text, result text, occurred_at timestamptz, metadata jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT id,actor_id,target_user_id,workspace_id,action,result,occurred_at,metadata FROM public.platform_audit_log
 WHERE public.is_platform_admin() ORDER BY occurred_at DESC LIMIT LEAST(GREATEST(p_limit,1),100);
$$;

CREATE OR REPLACE FUNCTION public.platform_list_notifications()
RETURNS TABLE(id uuid,title text,body text,severity text,read_at timestamptz,created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
 SELECT id,title,body,severity,read_at,created_at FROM public.platform_notifications
 WHERE recipient_id = auth.uid() AND public.is_platform_admin() ORDER BY created_at DESC LIMIT 100;
$$;

CREATE OR REPLACE FUNCTION public.platform_mark_notification_read(p_notification_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
 PERFORM public.platform_require_admin();
 UPDATE public.platform_notifications SET read_at = coalesce(read_at, now()) WHERE id=p_notification_id AND recipient_id=auth.uid();
END;
$$;

REVOKE ALL ON FUNCTION public.is_platform_admin(), public.platform_require_admin(), public.platform_dashboard(), public.platform_list_users(text,integer,integer), public.platform_list_workspaces(text,integer,integer), public.platform_set_user_block(uuid,boolean,text), public.platform_set_workspace_status(uuid,text,text), public.platform_set_maintenance(boolean,text,text,timestamptz,timestamptz), public.platform_list_audit(integer), public.platform_list_notifications(), public.platform_mark_notification_read(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.platform_maintenance_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_platform_admin(), public.platform_dashboard(), public.platform_list_users(text,integer,integer), public.platform_list_workspaces(text,integer,integer), public.platform_set_user_block(uuid,boolean,text), public.platform_set_workspace_status(uuid,text,text), public.platform_set_maintenance(boolean,text,text,timestamptz,timestamptz), public.platform_list_audit(integer), public.platform_list_notifications(), public.platform_mark_notification_read(uuid), public.platform_maintenance_status() TO authenticated;
