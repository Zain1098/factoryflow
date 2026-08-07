-- Safe, code-based onboarding for an existing company workspace.
-- No service-role key or client-side direct membership write is used.

CREATE TABLE IF NOT EXISTS public.workspace_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.factories(id) ON DELETE CASCADE,
  email text NOT NULL,
  role text NOT NULL CHECK (role IN ('Admin', 'Production Incharge', 'Store', 'Quality Inspector', 'Viewer')),
  code text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'cancelled')),
  created_by uuid NOT NULL REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  accepted_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_workspace_invites_workspace_status
  ON public.workspace_invites(workspace_id, status, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_workspace_invites_one_pending_email
  ON public.workspace_invites(workspace_id, lower(email)) WHERE status = 'pending';

ALTER TABLE public.workspace_invites ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.create_workspace_invite(p_email text, p_role text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_workspace_id uuid;
  v_email text := lower(btrim(p_email));
  v_code text;
BEGIN
  SELECT u.factory_id INTO v_workspace_id FROM public.users u WHERE u.id = auth.uid();
  IF v_workspace_id IS NULL OR NOT public.can_manage_workspace(v_workspace_id) THEN
    RAISE EXCEPTION 'not authorized to invite members';
  END IF;
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN RAISE EXCEPTION 'invalid email'; END IF;
  IF p_role NOT IN ('Admin', 'Production Incharge', 'Store', 'Quality Inspector', 'Viewer') THEN
    RAISE EXCEPTION 'invalid workspace role';
  END IF;
  UPDATE public.workspace_invites SET status = 'cancelled'
   WHERE workspace_id = v_workspace_id AND lower(email) = v_email AND status = 'pending';
  v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  INSERT INTO public.workspace_invites(workspace_id, email, role, code, created_by)
  VALUES (v_workspace_id, v_email, p_role, v_code, auth.uid());
  RETURN jsonb_build_object('code', v_code, 'email', v_email, 'role', p_role);
END;
$$;

CREATE OR REPLACE FUNCTION public.accept_workspace_invite(
  p_profile_name text, p_code text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_email text;
  v_invite public.workspace_invites%ROWTYPE;
BEGIN
  IF v_user_id IS NULL OR coalesce(btrim(p_profile_name), '') = '' THEN
    RAISE EXCEPTION 'invalid authenticated user or profile';
  END IF;
  SELECT lower(email) INTO v_email FROM auth.users WHERE id = v_user_id;
  SELECT * INTO v_invite FROM public.workspace_invites
   WHERE code = upper(btrim(p_code)) AND status = 'pending' FOR UPDATE;
  IF v_invite.id IS NULL OR v_invite.email <> v_email THEN
    RAISE EXCEPTION 'invite is invalid, already used, or for another email';
  END IF;
  IF EXISTS (SELECT 1 FROM public.users WHERE id = v_user_id) THEN
    RAISE EXCEPTION 'this account already belongs to a workspace';
  END IF;
  INSERT INTO public.users(id, factory_id, name, email, role, active)
  VALUES (v_user_id, v_invite.workspace_id, left(btrim(p_profile_name), 120), v_email, v_invite.role, true);
  INSERT INTO public.workspace_members(workspace_id, user_id, role, status)
  VALUES (v_invite.workspace_id, v_user_id, v_invite.role, 'active');
  UPDATE public.workspace_invites SET status = 'accepted', accepted_at = now() WHERE id = v_invite.id;
  RETURN jsonb_build_object(
    'workspace_id', v_invite.workspace_id,
    'role', v_invite.role,
    'workspace_name', (SELECT name FROM public.factories WHERE id = v_invite.workspace_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_workspace_members()
RETURNS TABLE(id uuid, user_id uuid, name text, email text, role text, status text, joined_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT wm.id, wm.user_id, u.name, u.email, wm.role, wm.status, wm.joined_at
  FROM public.workspace_members wm JOIN public.users u ON u.id = wm.user_id
  WHERE wm.workspace_id = public.get_my_factory_id() AND public.can_manage_workspace(wm.workspace_id)
  ORDER BY CASE WHEN wm.role = 'owner' THEN 0 ELSE 1 END, u.name;
$$;

CREATE OR REPLACE FUNCTION public.update_workspace_member(p_member_id uuid, p_role text, p_status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_workspace_id uuid; v_target_user uuid; v_role text;
BEGIN
  SELECT workspace_id, user_id, role INTO v_workspace_id, v_target_user, v_role FROM public.workspace_members WHERE id = p_member_id FOR UPDATE;
  IF v_workspace_id IS NULL OR NOT public.can_manage_workspace(v_workspace_id) THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF v_role = 'owner' THEN RAISE EXCEPTION 'owner membership cannot be changed here'; END IF;
  IF p_role NOT IN ('Admin', 'Production Incharge', 'Store', 'Quality Inspector', 'Viewer') OR p_status NOT IN ('active', 'inactive') THEN RAISE EXCEPTION 'invalid member update'; END IF;
  UPDATE public.workspace_members SET role = p_role, status = p_status WHERE id = p_member_id;
  UPDATE public.users SET role = p_role, active = (p_status = 'active') WHERE id = v_target_user;
END;
$$;

REVOKE ALL ON TABLE public.workspace_invites FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.create_workspace_invite(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.accept_workspace_invite(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_workspace_members() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_workspace_member(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_workspace_invite(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_workspace_invite(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_workspace_members() TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_workspace_member(uuid, text, text) TO authenticated;
