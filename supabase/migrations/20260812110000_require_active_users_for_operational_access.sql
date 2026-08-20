-- Keep the dashboard's platform controls separate while ensuring that a
-- dashboard-blocked account cannot retain authorization through a membership.

CREATE OR REPLACE FUNCTION public.get_my_workspace_ids()
RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT wm.workspace_id
  FROM public.workspace_members wm
  JOIN public.users u ON u.id = wm.user_id AND u.active
  WHERE wm.user_id = auth.uid() AND wm.status = 'active';
$$;

CREATE OR REPLACE FUNCTION public.get_my_workspace_role(p_workspace_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN wm.role = 'owner' THEN 'owner' ELSE wm.role END
  FROM public.workspace_members wm
  JOIN public.users u ON u.id = wm.user_id AND u.active
  WHERE wm.workspace_id = p_workspace_id
    AND wm.user_id = auth.uid()
    AND wm.status = 'active'
  LIMIT 1;
$$;

-- The original atomic production function checked membership directly. Keep
-- its implementation intact, but place an active-account check in front of it
-- and remove all direct client execution of the legacy implementation. The
-- guard is idempotent because an older project may already have the protected
-- implementation function after a partial/manual deployment.
DO $$
BEGIN
  IF to_regprocedure('public.post_production_stage_active_checked_impl(jsonb)') IS NULL THEN
    IF to_regprocedure('public.post_production_stage(jsonb)') IS NULL THEN
      RAISE EXCEPTION 'post_production_stage(jsonb) is missing';
    END IF;
    ALTER FUNCTION public.post_production_stage(jsonb)
      RENAME TO post_production_stage_active_checked_impl;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.post_production_stage_active_checked_impl(jsonb)
  FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.post_production_stage(p_command jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.active
  ) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  RETURN public.post_production_stage_active_checked_impl(p_command);
END;
$$;
REVOKE ALL ON FUNCTION public.post_production_stage(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_production_stage(jsonb) TO authenticated;

-- Legacy policies that queried workspace_members directly must delegate to
-- helpers above so public.users.active is always part of authorization.
DROP POLICY IF EXISTS ap_reasons_read ON public.ap_reject_reasons;
DROP POLICY IF EXISTS ap_reasons_write ON public.ap_reject_reasons;
CREATE POLICY ap_reasons_read ON public.ap_reject_reasons FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
CREATE POLICY ap_reasons_write ON public.ap_reject_reasons FOR ALL
  USING (public.get_my_workspace_role(factory_id) IN ('Admin', 'owner'))
  WITH CHECK (public.get_my_workspace_role(factory_id) IN ('Admin', 'owner'));

DROP POLICY IF EXISTS bp_reasons_read ON public.bp_reject_reasons;
DROP POLICY IF EXISTS bp_reasons_write ON public.bp_reject_reasons;
CREATE POLICY bp_reasons_read ON public.bp_reject_reasons FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
CREATE POLICY bp_reasons_write ON public.bp_reject_reasons FOR ALL
  USING (public.get_my_workspace_role(factory_id) IN ('Admin', 'owner'))
  WITH CHECK (public.get_my_workspace_role(factory_id) IN ('Admin', 'owner'));

DROP POLICY IF EXISTS rtv_reasons_read ON public.rtv_reasons;
DROP POLICY IF EXISTS rtv_reasons_write ON public.rtv_reasons;
CREATE POLICY rtv_reasons_read ON public.rtv_reasons FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
CREATE POLICY rtv_reasons_write ON public.rtv_reasons FOR ALL
  USING (public.get_my_workspace_role(factory_id) IN ('Admin', 'owner'))
  WITH CHECK (public.get_my_workspace_role(factory_id) IN ('Admin', 'owner'));

DROP POLICY IF EXISTS shifts_factory_read ON public.shifts;
DROP POLICY IF EXISTS shifts_admin_write ON public.shifts;
CREATE POLICY shifts_factory_read ON public.shifts FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
CREATE POLICY shifts_admin_write ON public.shifts FOR ALL
  USING (public.get_my_workspace_role(factory_id) IN ('Admin', 'owner'))
  WITH CHECK (public.get_my_workspace_role(factory_id) IN ('Admin', 'owner'));

DROP POLICY IF EXISTS conflicts_read ON public.sync_conflicts;
DROP POLICY IF EXISTS conflicts_write ON public.sync_conflicts;
CREATE POLICY conflicts_read ON public.sync_conflicts FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
CREATE POLICY conflicts_write ON public.sync_conflicts FOR ALL
  USING (public.get_my_workspace_role(factory_id) IN ('Admin', 'owner'))
  WITH CHECK (public.get_my_workspace_role(factory_id) IN ('Admin', 'owner'));

DROP POLICY IF EXISTS drafts_own ON public.draft_forms;
CREATE POLICY drafts_own ON public.draft_forms FOR ALL
  USING (created_by = auth.uid() AND factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (created_by = auth.uid() AND factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS phys_counts_read ON public.physical_counts;
DROP POLICY IF EXISTS phys_counts_write ON public.physical_counts;
CREATE POLICY phys_counts_read ON public.physical_counts FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
CREATE POLICY phys_counts_write ON public.physical_counts FOR ALL
  USING (public.get_my_workspace_role(factory_id) IN ('Admin', 'owner', 'Store'))
  WITH CHECK (public.get_my_workspace_role(factory_id) IN ('Admin', 'owner', 'Store'));

DROP POLICY IF EXISTS "Active members can read their workspace app update" ON public.app_update_channels;
DROP POLICY IF EXISTS "Workspace admins can create app updates" ON public.app_update_channels;
DROP POLICY IF EXISTS "Workspace admins can update app updates" ON public.app_update_channels;
CREATE POLICY "Active members can read their workspace app update"
  ON public.app_update_channels FOR SELECT TO authenticated
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
CREATE POLICY "Workspace admins can create app updates"
  ON public.app_update_channels FOR INSERT TO authenticated
  WITH CHECK (public.get_my_workspace_role(factory_id) IN ('owner', 'Admin'));
CREATE POLICY "Workspace admins can update app updates"
  ON public.app_update_channels FOR UPDATE TO authenticated
  USING (public.get_my_workspace_role(factory_id) IN ('owner', 'Admin'))
  WITH CHECK (public.get_my_workspace_role(factory_id) IN ('owner', 'Admin'));

DROP POLICY IF EXISTS workspace_members_owner_write ON public.workspace_members;
CREATE POLICY workspace_members_owner_write ON public.workspace_members FOR ALL
  USING (public.get_my_workspace_role(workspace_id) = 'owner')
  WITH CHECK (public.get_my_workspace_role(workspace_id) = 'owner');

DROP POLICY IF EXISTS workspace_members_read_allowed ON public.workspace_members;
CREATE POLICY workspace_members_read_allowed ON public.workspace_members FOR SELECT TO authenticated
  USING (
    (user_id = auth.uid() AND EXISTS (
      SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.active
    )) OR public.can_manage_workspace(workspace_id)
  );
