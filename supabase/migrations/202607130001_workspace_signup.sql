-- Phase 2: workspace_members table + create_user_workspace RPC
-- Apply after 202607120001_phase1_security_and_ledger.sql

-- ── workspace_members ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.workspace_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.factories(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'owner',
  status text NOT NULL DEFAULT 'active',
  joined_at timestamptz NOT NULL DEFAULT now(),
  sync_status text DEFAULT 'pending',
  UNIQUE(workspace_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_workspace_members_user ON public.workspace_members(user_id);
CREATE INDEX IF NOT EXISTS idx_workspace_members_workspace ON public.workspace_members(workspace_id);

ALTER TABLE public.workspace_members ENABLE ROW LEVEL SECURITY;

-- Members can read their own memberships
CREATE POLICY "workspace_members_read_own" ON public.workspace_members FOR SELECT
  USING (user_id = auth.uid());

-- Owner can insert/update members in their workspace
CREATE POLICY "workspace_members_owner_write" ON public.workspace_members FOR ALL
  USING (
    workspace_id IN (
      SELECT workspace_id FROM public.workspace_members
      WHERE user_id = auth.uid() AND role = 'owner' AND status = 'active'
    )
  )
  WITH CHECK (
    workspace_id IN (
      SELECT workspace_id FROM public.workspace_members
      WHERE user_id = auth.uid() AND role = 'owner' AND status = 'active'
    )
  );

-- ── Helper: get all workspace IDs the current user is a member of ─────────────

CREATE OR REPLACE FUNCTION public.get_my_workspace_ids()
RETURNS SETOF uuid
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT workspace_id FROM public.workspace_members
  WHERE user_id = auth.uid() AND status = 'active';
$$;

-- ── Update data-table RLS to use workspace membership ─────────────────────────
-- Replace the old single-factory read policies with membership-based ones.

-- parts
DROP POLICY IF EXISTS "parts_read" ON public.parts;
CREATE POLICY "parts_read" ON public.parts FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "parts_write" ON public.parts;
CREATE POLICY "parts_write" ON public.parts FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- machines
DROP POLICY IF EXISTS "machines_read" ON public.machines;
CREATE POLICY "machines_read" ON public.machines FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "machines_write" ON public.machines;
CREATE POLICY "machines_write" ON public.machines FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- operators
DROP POLICY IF EXISTS "operators_read" ON public.operators;
CREATE POLICY "operators_read" ON public.operators FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "operators_write" ON public.operators;
CREATE POLICY "operators_write" ON public.operators FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- suppliers
DROP POLICY IF EXISTS "suppliers_read" ON public.suppliers;
CREATE POLICY "suppliers_read" ON public.suppliers FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "suppliers_write" ON public.suppliers;
CREATE POLICY "suppliers_write" ON public.suppliers FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- vendors
DROP POLICY IF EXISTS "vendors_read" ON public.vendors;
CREATE POLICY "vendors_read" ON public.vendors FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "vendors_write" ON public.vendors;
CREATE POLICY "vendors_write" ON public.vendors FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- customers
DROP POLICY IF EXISTS "customers_read" ON public.customers;
CREATE POLICY "customers_read" ON public.customers FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "customers_write" ON public.customers;
CREATE POLICY "customers_write" ON public.customers FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- vehicles
DROP POLICY IF EXISTS "vehicles_read" ON public.vehicles;
CREATE POLICY "vehicles_read" ON public.vehicles FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "vehicles_write" ON public.vehicles;
CREATE POLICY "vehicles_write" ON public.vehicles FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- drivers
DROP POLICY IF EXISTS "drivers_read" ON public.drivers;
CREATE POLICY "drivers_read" ON public.drivers FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "drivers_write" ON public.drivers;
CREATE POLICY "drivers_write" ON public.drivers FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- ── create_user_workspace RPC ─────────────────────────────────────────────────
-- Called right after Supabase Auth signup.
-- Creates: factories row, users row, workspace_members row.

CREATE OR REPLACE FUNCTION public.create_user_workspace(
  p_profile_name text,
  p_workspace_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_workspace_id uuid := gen_random_uuid();
  v_member_id uuid := gen_random_uuid();
  v_email text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  -- Get email from auth.users
  SELECT email INTO v_email FROM auth.users WHERE id = v_user_id;

  -- Create workspace (factories row)
  INSERT INTO public.factories (id, name, active)
  VALUES (v_workspace_id, p_workspace_name, true)
  ON CONFLICT (id) DO NOTHING;

  -- Create user profile
  INSERT INTO public.users (id, factory_id, name, email, role, active)
  VALUES (v_user_id, v_workspace_id, p_profile_name, v_email, 'owner', true)
  ON CONFLICT (id) DO UPDATE
    SET factory_id = v_workspace_id, name = p_profile_name;

  -- Create workspace membership
  INSERT INTO public.workspace_members (id, workspace_id, user_id, role, status)
  VALUES (v_member_id, v_workspace_id, v_user_id, 'owner', 'active')
  ON CONFLICT (workspace_id, user_id) DO NOTHING;

  RETURN jsonb_build_object(
    'workspace_id', v_workspace_id,
    'user_id', v_user_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_user_workspace(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_user_workspace(text, text) TO authenticated;
