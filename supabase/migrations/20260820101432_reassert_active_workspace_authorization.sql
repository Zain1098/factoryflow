-- Reassert the shared-workspace gate after the legacy active-user migration.
-- The deployed platform-control schema uses factory_id, not workspace_id.
CREATE OR REPLACE FUNCTION public.get_my_workspace_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT wm.workspace_id
  FROM public.workspace_members AS wm
  JOIN public.users AS u ON u.id = wm.user_id AND u.active
  LEFT JOIN public.platform_workspace_state AS state
    ON state.factory_id = wm.workspace_id
  WHERE wm.user_id = auth.uid()
    AND wm.status = 'active'
    AND COALESCE(state.status, 'active') = 'active';
$$;

CREATE OR REPLACE FUNCTION public.get_my_workspace_role(p_workspace_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE WHEN wm.role = 'owner' THEN 'owner' ELSE wm.role END
  FROM public.workspace_members AS wm
  JOIN public.users AS u ON u.id = wm.user_id AND u.active
  LEFT JOIN public.platform_workspace_state AS state
    ON state.factory_id = wm.workspace_id
  WHERE wm.workspace_id = p_workspace_id
    AND wm.user_id = auth.uid()
    AND wm.status = 'active'
    AND COALESCE(state.status, 'active') = 'active'
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.get_my_workspace_ids() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_workspace_role(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_workspace_ids() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_workspace_role(uuid) TO authenticated;
