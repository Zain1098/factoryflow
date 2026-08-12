-- Shared workspace access model: workspace_members is the authorization source.
-- Existing factory_id stays in place as the workspace/company scope so current
-- operational and ledger records do not need a risky column rename.

CREATE OR REPLACE FUNCTION public.get_my_workspace_role(p_workspace_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE WHEN wm.role = 'owner' THEN 'owner' ELSE wm.role END
  FROM public.workspace_members AS wm
  WHERE wm.workspace_id = p_workspace_id
    AND wm.user_id = auth.uid()
    AND wm.status = 'active'
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.can_manage_workspace(p_workspace_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT public.get_my_workspace_role(p_workspace_id) IN ('owner', 'Admin')),
    false
  );
$$;

REVOKE ALL ON FUNCTION public.get_my_workspace_role(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.can_manage_workspace(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_workspace_role(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_manage_workspace(uuid) TO authenticated;

-- A user may see their own memberships. Owner/Admin can see the company roster;
-- this supports the member-management screen without exposing another company.
DROP POLICY IF EXISTS "workspace_members_read_own" ON public.workspace_members;
DROP POLICY IF EXISTS "workspace_members_read_allowed" ON public.workspace_members;
CREATE POLICY "workspace_members_read_allowed"
  ON public.workspace_members FOR SELECT TO authenticated
  USING (
    user_id = (SELECT auth.uid())
    OR (SELECT public.can_manage_workspace(workspace_id))
  );

-- Stock adjustments are reconciliations, not normal transactions. Only company
-- Owner/Admin can add one; no client may edit or delete historical adjustments.
ALTER TABLE public.stock_adjustments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "stock_adj_read" ON public.stock_adjustments;
DROP POLICY IF EXISTS "stock_adj_insert" ON public.stock_adjustments;
DROP POLICY IF EXISTS "stock_adj_update_sync" ON public.stock_adjustments;
DROP POLICY IF EXISTS "stock_adj_read_workspace" ON public.stock_adjustments;
DROP POLICY IF EXISTS "stock_adj_insert_manager" ON public.stock_adjustments;
CREATE POLICY "stock_adj_read_workspace"
  ON public.stock_adjustments FOR SELECT TO authenticated
  USING ((SELECT public.get_my_workspace_role(factory_id)) IS NOT NULL);
CREATE POLICY "stock_adj_insert_manager"
  ON public.stock_adjustments FOR INSERT TO authenticated
  WITH CHECK (
    user_id = (SELECT auth.uid())
    AND (SELECT public.can_manage_workspace(factory_id))
  );

-- Correction requests are immutable evidence. A requester supplies a snapshot
-- and proposed values; only a manager can review via the narrow RPC below.
CREATE TABLE IF NOT EXISTS public.correction_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id uuid NOT NULL REFERENCES public.factories(id),
  table_name text NOT NULL,
  record_id uuid NOT NULL,
  requested_by uuid NOT NULL REFERENCES public.users(id),
  requested_at timestamptz NOT NULL DEFAULT now(),
  reason text NOT NULL,
  old_value_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  proposed_value_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected', 'applied')),
  reviewed_by uuid REFERENCES public.users(id),
  reviewed_at timestamptz,
  review_remarks text,
  applied_at timestamptz,
  sync_status text DEFAULT 'pending'
);

ALTER TABLE public.correction_requests
  ADD COLUMN IF NOT EXISTS review_remarks text;

CREATE INDEX IF NOT EXISTS idx_correction_requests_workspace_status
  ON public.correction_requests(factory_id, status, requested_at DESC);
CREATE INDEX IF NOT EXISTS idx_correction_requests_requester
  ON public.correction_requests(requested_by, requested_at DESC);

ALTER TABLE public.correction_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "correction_requests_read_workspace" ON public.correction_requests;
DROP POLICY IF EXISTS "correction_requests_insert_own" ON public.correction_requests;
CREATE POLICY "correction_requests_read_workspace"
  ON public.correction_requests FOR SELECT TO authenticated
  USING ((SELECT public.get_my_workspace_role(factory_id)) IS NOT NULL);
CREATE POLICY "correction_requests_insert_own"
  ON public.correction_requests FOR INSERT TO authenticated
  WITH CHECK (
    requested_by = (SELECT auth.uid())
    AND (SELECT public.get_my_workspace_role(factory_id)) IN
      ('owner', 'Admin', 'Production Incharge', 'Store', 'Quality Inspector')
    AND status = 'pending'
  );

CREATE OR REPLACE FUNCTION public.review_correction_request(
  p_id uuid,
  p_status text,
  p_remarks text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_factory_id uuid;
BEGIN
  IF p_status NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'invalid correction decision';
  END IF;
  SELECT factory_id INTO v_factory_id
  FROM public.correction_requests
  WHERE id = p_id AND status = 'pending'
  FOR UPDATE;
  IF v_factory_id IS NULL THEN
    RAISE EXCEPTION 'correction request is unavailable or already reviewed';
  END IF;
  IF NOT public.can_manage_workspace(v_factory_id) THEN
    RAISE EXCEPTION 'not authorized to review this correction';
  END IF;
  UPDATE public.correction_requests
  SET status = p_status,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      review_remarks = left(coalesce(p_remarks, ''), 1000)
  WHERE id = p_id;
  RETURN jsonb_build_object('success', true, 'status', p_status);
END;
$$;

REVOKE ALL ON FUNCTION public.review_correction_request(uuid, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_correction_request(uuid, text, text)
  TO authenticated;
