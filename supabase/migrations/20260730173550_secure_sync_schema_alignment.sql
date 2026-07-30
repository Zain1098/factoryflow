-- Align the hosted schema with the mobile app's offline-first command model.
-- Forward-safe and additive: existing operational history is not deleted or
-- backfilled. Security-sensitive updates are exposed only through narrow RPCs.

-- ---------------------------------------------------------------------------
-- Tenant and role helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_my_factory_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT u.factory_id
  FROM public.users AS u
  WHERE u.id = auth.uid()
    AND COALESCE(u.active, true)
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE WHEN u.role = 'owner' THEN 'Admin' ELSE u.role END
  FROM public.users AS u
  WHERE u.id = auth.uid()
    AND COALESCE(u.active, true)
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.get_my_workspace_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT wm.workspace_id
  FROM public.workspace_members AS wm
  WHERE wm.user_id = auth.uid()
    AND wm.status = 'active';
$$;

REVOKE ALL ON FUNCTION public.get_my_factory_id() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_role() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_workspace_ids() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_factory_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_workspace_ids() TO authenticated;

-- ---------------------------------------------------------------------------
-- Auth RPC hardening
-- ---------------------------------------------------------------------------

-- Retrying workspace creation must return the caller's existing workspace
-- instead of silently moving the user to a newly-created company.
CREATE OR REPLACE FUNCTION public.create_user_workspace(
  p_profile_name text,
  p_workspace_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_workspace_id uuid;
  v_email text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF COALESCE(btrim(p_profile_name), '') = ''
    OR char_length(btrim(p_profile_name)) > 120
    OR COALESCE(btrim(p_workspace_name), '') = ''
    OR char_length(btrim(p_workspace_name)) > 120
  THEN
    RAISE EXCEPTION 'invalid profile or workspace name';
  END IF;

  SELECT u.factory_id
    INTO v_workspace_id
  FROM public.users AS u
  WHERE u.id = v_user_id
  LIMIT 1;

  IF v_workspace_id IS NOT NULL THEN
    UPDATE public.users
    SET name = btrim(p_profile_name)
    WHERE id = v_user_id;

    RETURN jsonb_build_object(
      'workspace_id', v_workspace_id,
      'user_id', v_user_id,
      'idempotent', true
    );
  END IF;

  SELECT au.email
    INTO v_email
  FROM auth.users AS au
  WHERE au.id = v_user_id;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'authenticated user was not found';
  END IF;

  v_workspace_id := gen_random_uuid();

  INSERT INTO public.factories (id, name, active)
  VALUES (v_workspace_id, btrim(p_workspace_name), true);

  INSERT INTO public.users (id, factory_id, name, email, role, active)
  VALUES (
    v_user_id,
    v_workspace_id,
    btrim(p_profile_name),
    v_email,
    'owner',
    true
  );

  INSERT INTO public.workspace_members (
    id,
    workspace_id,
    user_id,
    role,
    status
  )
  VALUES (
    gen_random_uuid(),
    v_workspace_id,
    v_user_id,
    'owner',
    'active'
  );

  RETURN jsonb_build_object(
    'workspace_id', v_workspace_id,
    'user_id', v_user_id,
    'idempotent', false
  );
END;
$$;

-- OTP calls may only act for the signed-in user. Password values are never
-- stored in otp_codes; the client changes the password through Supabase Auth
-- only after successful verification.
CREATE OR REPLACE FUNCTION public.generate_otp(
  p_user_id uuid,
  p_purpose text,
  p_new_value text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_code text;
  v_random bytea;
  v_number bigint;
  v_stored_value text;
BEGIN
  IF auth.uid() IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_purpose NOT IN ('email_change', 'password_change') THEN
    RAISE EXCEPTION 'invalid OTP purpose';
  END IF;
  IF p_purpose = 'email_change' AND (
    COALESCE(btrim(p_new_value), '') = ''
    OR char_length(btrim(p_new_value)) > 320
    OR position('@' IN p_new_value) <= 1
  ) THEN
    RAISE EXCEPTION 'invalid email';
  END IF;

  v_random := extensions.gen_random_bytes(4);
  v_number :=
      get_byte(v_random, 0)::bigint * 16777216
    + get_byte(v_random, 1)::bigint * 65536
    + get_byte(v_random, 2)::bigint * 256
    + get_byte(v_random, 3)::bigint;
  v_code := lpad((v_number % 1000000)::text, 6, '0');
  v_stored_value := CASE
    WHEN p_purpose = 'password_change' THEN '[password_change]'
    ELSE lower(btrim(p_new_value))
  END;

  UPDATE public.otp_codes
  SET used = true
  WHERE user_id = p_user_id
    AND purpose = p_purpose
    AND used = false;

  INSERT INTO public.otp_codes (
    user_id,
    code,
    purpose,
    new_value,
    expires_at
  )
  VALUES (
    p_user_id,
    v_code,
    p_purpose,
    v_stored_value,
    now() + interval '10 minutes'
  );

  RETURN v_code;
END;
$$;

CREATE OR REPLACE FUNCTION public.verify_otp(
  p_user_id uuid,
  p_code text,
  p_purpose text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_otp public.otp_codes%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_purpose NOT IN ('email_change', 'password_change') THEN
    RAISE EXCEPTION 'invalid OTP purpose';
  END IF;

  SELECT oc.*
    INTO v_otp
  FROM public.otp_codes AS oc
  WHERE oc.user_id = p_user_id
    AND oc.code = p_code
    AND oc.purpose = p_purpose
    AND oc.used = false
    AND oc.expires_at > now()
  ORDER BY oc.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF v_otp.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Invalid or expired OTP'
    );
  END IF;

  UPDATE public.otp_codes
  SET used = true
  WHERE id = v_otp.id
    AND used = false;

  RETURN jsonb_build_object(
    'success', true,
    'new_value', v_otp.new_value
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_user_profile(
  p_user_id uuid,
  p_name text DEFAULT NULL,
  p_avatar_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_name IS NOT NULL AND (
    COALESCE(btrim(p_name), '') = ''
    OR char_length(btrim(p_name)) > 120
  ) THEN
    RAISE EXCEPTION 'invalid profile name';
  END IF;
  IF p_avatar_url IS NOT NULL AND char_length(p_avatar_url) > 2048 THEN
    RAISE EXCEPTION 'invalid avatar URL';
  END IF;

  UPDATE public.users
  SET
    name = COALESCE(btrim(p_name), name),
    avatar_url = COALESCE(p_avatar_url, avatar_url)
  WHERE id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile not found';
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.update_user_email_after_otp(
  p_user_id uuid,
  p_new_email text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF COALESCE(btrim(p_new_email), '') = ''
    OR char_length(btrim(p_new_email)) > 320
    OR position('@' IN p_new_email) <= 1
  THEN
    RAISE EXCEPTION 'invalid email';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.otp_codes AS oc
    WHERE oc.user_id = auth.uid()
      AND oc.purpose = 'email_change'
      AND oc.used = true
      AND oc.new_value = lower(btrim(p_new_email))
      AND oc.created_at >= now() - interval '15 minutes'
  ) THEN
    RAISE EXCEPTION 'verified email change was not found';
  END IF;

  UPDATE public.users
  SET email = lower(btrim(p_new_email))
  WHERE id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile not found';
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_google_auth_user(
  p_user_id uuid,
  p_email text,
  p_name text,
  p_avatar_url text,
  p_workspace_name text DEFAULT 'My Workspace'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_workspace_id uuid;
  v_auth_email text;
BEGIN
  IF auth.uid() IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF COALESCE(btrim(p_name), '') = ''
    OR char_length(btrim(p_name)) > 120
    OR COALESCE(btrim(p_workspace_name), '') = ''
    OR char_length(btrim(p_workspace_name)) > 120
    OR char_length(COALESCE(p_avatar_url, '')) > 2048
  THEN
    RAISE EXCEPTION 'invalid Google profile';
  END IF;

  SELECT au.email
    INTO v_auth_email
  FROM auth.users AS au
  WHERE au.id = auth.uid();

  IF v_auth_email IS NULL THEN
    RAISE EXCEPTION 'authenticated user was not found';
  END IF;

  SELECT u.factory_id
    INTO v_workspace_id
  FROM public.users AS u
  WHERE u.id = auth.uid()
  LIMIT 1;

  IF v_workspace_id IS NOT NULL THEN
    UPDATE public.users
    SET
      name = btrim(p_name),
      email = v_auth_email,
      avatar_url = NULLIF(p_avatar_url, '')
    WHERE id = auth.uid();

    RETURN jsonb_build_object(
      'is_new', false,
      'workspace_id', v_workspace_id
    );
  END IF;

  v_workspace_id := gen_random_uuid();

  INSERT INTO public.factories (id, name, active)
  VALUES (v_workspace_id, btrim(p_workspace_name), true);

  INSERT INTO public.users (
    id,
    factory_id,
    name,
    email,
    role,
    active,
    avatar_url
  )
  VALUES (
    auth.uid(),
    v_workspace_id,
    btrim(p_name),
    v_auth_email,
    'owner',
    true,
    NULLIF(p_avatar_url, '')
  );

  INSERT INTO public.workspace_members (
    id,
    workspace_id,
    user_id,
    role,
    status
  )
  VALUES (
    gen_random_uuid(),
    v_workspace_id,
    auth.uid(),
    'owner',
    'active'
  );

  RETURN jsonb_build_object(
    'is_new', true,
    'workspace_id', v_workspace_id
  );
END;
$$;

-- Harden existing privileged functions without changing their business logic.
ALTER FUNCTION public.admin_update_user_email(uuid, text)
  SET search_path = '';
ALTER FUNCTION public.request_account_deletion(uuid)
  SET search_path = '';
ALTER FUNCTION public.write_stock_ledger_entry(
  uuid, uuid, uuid, text, text, numeric, text, uuid
) SET search_path = '';
ALTER FUNCTION public.post_production_stage(jsonb)
  SET search_path = '';

REVOKE ALL ON FUNCTION public.create_user_workspace(text, text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.generate_otp(uuid, text, text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.verify_otp(uuid, text, text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_user_profile(uuid, text, text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_user_email_after_otp(uuid, text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.handle_google_auth_user(
  uuid, text, text, text, text
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.request_account_deletion(uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.write_stock_ledger_entry(
  uuid, uuid, uuid, text, text, numeric, text, uuid
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.post_production_stage(jsonb)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_update_user_email(uuid, text)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.create_user_workspace(text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_otp(uuid, text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_otp(uuid, text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_profile(uuid, text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_user_email_after_otp(uuid, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.handle_google_auth_user(
  uuid, text, text, text, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_account_deletion(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.write_stock_ledger_entry(
  uuid, uuid, uuid, text, text, numeric, text, uuid
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.post_production_stage(jsonb)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_user_email(uuid, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Schema alignment
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.purchase_orders (
  id uuid PRIMARY KEY,
  factory_id uuid NOT NULL REFERENCES public.factories(id),
  date date NOT NULL,
  time time,
  part_id uuid NOT NULL REFERENCES public.parts(id),
  supplier_id uuid REFERENCES public.suppliers(id),
  ordered_qty numeric NOT NULL CHECK (ordered_qty > 0),
  po_number text,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'received', 'cancelled')),
  remarks text,
  created_by uuid REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.material_receives
  ADD COLUMN IF NOT EXISTS po_ref_id uuid
    REFERENCES public.purchase_orders(id),
  ADD COLUMN IF NOT EXISTS ordered_qty numeric,
  ADD COLUMN IF NOT EXISTS shortfall numeric NOT NULL DEFAULT 0;

ALTER TABLE public.ap_inspections
  ADD COLUMN IF NOT EXISTS rtv_qty numeric NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS public.ap_rejected_actions (
  id uuid PRIMARY KEY,
  factory_id uuid NOT NULL REFERENCES public.factories(id),
  date date NOT NULL,
  part_id uuid NOT NULL REFERENCES public.parts(id),
  qty numeric NOT NULL CHECK (qty > 0),
  action text NOT NULL CHECK (action IN ('scrapped', 'sent_to_faco')),
  vendor_id uuid REFERENCES public.vendors(id),
  remarks text,
  created_by uuid REFERENCES public.users(id)
);

CREATE TABLE IF NOT EXISTS public.dispatch_sessions (
  id uuid PRIMARY KEY,
  factory_id uuid NOT NULL REFERENCES public.factories(id),
  date date NOT NULL,
  time time,
  customer_id uuid NOT NULL REFERENCES public.customers(id),
  vehicle_id uuid REFERENCES public.vehicles(id),
  driver_id uuid REFERENCES public.drivers(id),
  challan_number text,
  remarks text,
  created_by uuid REFERENCES public.users(id)
);

CREATE TABLE IF NOT EXISTS public.dispatch_items (
  id uuid PRIMARY KEY,
  session_id uuid NOT NULL REFERENCES public.dispatch_sessions(id),
  factory_id uuid NOT NULL REFERENCES public.factories(id),
  part_id uuid NOT NULL REFERENCES public.parts(id),
  batch_number text,
  dispatch_qty numeric NOT NULL CHECK (dispatch_qty > 0)
);

ALTER TABLE public.dispatch_items
  ADD COLUMN IF NOT EXISTS batch_number text;

CREATE INDEX IF NOT EXISTS idx_purchase_orders_factory_part_status
  ON public.purchase_orders(factory_id, part_id, status);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_supplier
  ON public.purchase_orders(supplier_id);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_created_by
  ON public.purchase_orders(created_by);
CREATE INDEX IF NOT EXISTS idx_material_receives_po_ref
  ON public.material_receives(po_ref_id);
CREATE INDEX IF NOT EXISTS idx_ap_rejected_actions_factory_part
  ON public.ap_rejected_actions(factory_id, part_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_ap_rejected_actions_part
  ON public.ap_rejected_actions(part_id);
CREATE INDEX IF NOT EXISTS idx_ap_rejected_actions_vendor
  ON public.ap_rejected_actions(vendor_id);
CREATE INDEX IF NOT EXISTS idx_ap_rejected_actions_created_by
  ON public.ap_rejected_actions(created_by);
CREATE INDEX IF NOT EXISTS idx_dispatch_sessions_factory_date
  ON public.dispatch_sessions(factory_id, date DESC, time DESC);
CREATE INDEX IF NOT EXISTS idx_dispatch_sessions_customer
  ON public.dispatch_sessions(customer_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_sessions_vehicle
  ON public.dispatch_sessions(vehicle_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_sessions_driver
  ON public.dispatch_sessions(driver_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_sessions_created_by
  ON public.dispatch_sessions(created_by);
CREATE INDEX IF NOT EXISTS idx_dispatch_items_session
  ON public.dispatch_items(session_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_items_part
  ON public.dispatch_items(part_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_items_factory_part
  ON public.dispatch_items(factory_id, part_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_items_factory_batch_part
  ON public.dispatch_items(factory_id, batch_number, part_id);
CREATE INDEX IF NOT EXISTS idx_receive_from_facos_dispatch_ref
  ON public.receive_from_facos(factory_id, dispatch_ref_id);
CREATE INDEX IF NOT EXISTS idx_rtvs_factory_status_return
  ON public.rtvs(factory_id, status, expected_return_date);
CREATE INDEX IF NOT EXISTS idx_rtv_reinspections_factory_rtv
  ON public.rtv_reinspections(factory_id, rtv_id, date DESC);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'material_receives_ordered_qty_positive'
      AND conrelid = 'public.material_receives'::regclass
  ) THEN
    ALTER TABLE public.material_receives
      ADD CONSTRAINT material_receives_ordered_qty_positive
      CHECK (ordered_qty IS NULL OR ordered_qty > 0)
      NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'material_receives_shortfall_nonnegative'
      AND conrelid = 'public.material_receives'::regclass
  ) THEN
    ALTER TABLE public.material_receives
      ADD CONSTRAINT material_receives_shortfall_nonnegative
      CHECK (shortfall >= 0)
      NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ap_inspections_rtv_within_rejected'
      AND conrelid = 'public.ap_inspections'::regclass
  ) THEN
    ALTER TABLE public.ap_inspections
      ADD CONSTRAINT ap_inspections_rtv_within_rejected
      CHECK (rtv_qty >= 0 AND rtv_qty <= rejected_qty)
      NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ap_inspections_quantity_equation'
      AND conrelid = 'public.ap_inspections'::regclass
  ) THEN
    ALTER TABLE public.ap_inspections
      ADD CONSTRAINT ap_inspections_quantity_equation
      CHECK (approved_qty + rejected_qty = qty_checked)
      NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'rtvs_positive_qty_and_cycle'
      AND conrelid = 'public.rtvs'::regclass
  ) THEN
    ALTER TABLE public.rtvs
      ADD CONSTRAINT rtvs_positive_qty_and_cycle
      CHECK (rtv_qty > 0 AND cycle_number BETWEEN 1 AND 3)
      NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'rtv_reinspections_quantity_equation'
      AND conrelid = 'public.rtv_reinspections'::regclass
  ) THEN
    ALTER TABLE public.rtv_reinspections
      ADD CONSTRAINT rtv_reinspections_quantity_equation
      CHECK (
        quantity_received > 0
        AND ok_qty >= 0
        AND reject_again_qty >= 0
        AND ok_qty + reject_again_qty = quantity_received
      )
      NOT VALID;
  END IF;
END;
$$;

ALTER TABLE public.material_receives
  VALIDATE CONSTRAINT material_receives_ordered_qty_positive;
ALTER TABLE public.material_receives
  VALIDATE CONSTRAINT material_receives_shortfall_nonnegative;
ALTER TABLE public.ap_inspections
  VALIDATE CONSTRAINT ap_inspections_rtv_within_rejected;
ALTER TABLE public.ap_inspections
  VALIDATE CONSTRAINT ap_inspections_quantity_equation;
ALTER TABLE public.rtvs
  VALIDATE CONSTRAINT rtvs_positive_qty_and_cycle;
ALTER TABLE public.rtv_reinspections
  VALIDATE CONSTRAINT rtv_reinspections_quantity_equation;

-- ---------------------------------------------------------------------------
-- RLS and least-privilege Data API grants
-- ---------------------------------------------------------------------------

ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ap_rejected_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispatch_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispatch_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS purchase_orders_read ON public.purchase_orders;
CREATE POLICY purchase_orders_read
  ON public.purchase_orders
  FOR SELECT
  TO authenticated
  USING (factory_id = (SELECT public.get_my_factory_id()));

DROP POLICY IF EXISTS purchase_orders_write ON public.purchase_orders;
CREATE POLICY purchase_orders_write
  ON public.purchase_orders
  FOR INSERT
  TO authenticated
  WITH CHECK (
    factory_id = (SELECT public.get_my_factory_id())
    AND (SELECT public.get_my_role()) IN ('Admin', 'Store')
  );

DROP POLICY IF EXISTS purchase_orders_update ON public.purchase_orders;
CREATE POLICY purchase_orders_update
  ON public.purchase_orders
  FOR UPDATE
  TO authenticated
  USING (
    factory_id = (SELECT public.get_my_factory_id())
    AND (SELECT public.get_my_role()) IN ('Admin', 'Store')
  )
  WITH CHECK (
    factory_id = (SELECT public.get_my_factory_id())
    AND (SELECT public.get_my_role()) IN ('Admin', 'Store')
  );

DROP POLICY IF EXISTS ap_rejected_actions_read
  ON public.ap_rejected_actions;
CREATE POLICY ap_rejected_actions_read
  ON public.ap_rejected_actions
  FOR SELECT
  TO authenticated
  USING (factory_id = (SELECT public.get_my_factory_id()));

DROP POLICY IF EXISTS ap_rejected_actions_write
  ON public.ap_rejected_actions;
CREATE POLICY ap_rejected_actions_write
  ON public.ap_rejected_actions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    factory_id = (SELECT public.get_my_factory_id())
    AND (SELECT public.get_my_role()) IN ('Admin', 'Quality Inspector')
  );

DROP POLICY IF EXISTS dispatch_sessions_read ON public.dispatch_sessions;
CREATE POLICY dispatch_sessions_read
  ON public.dispatch_sessions
  FOR SELECT
  TO authenticated
  USING (factory_id = (SELECT public.get_my_factory_id()));

DROP POLICY IF EXISTS dispatch_sessions_write ON public.dispatch_sessions;
CREATE POLICY dispatch_sessions_write
  ON public.dispatch_sessions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    factory_id = (SELECT public.get_my_factory_id())
    AND (SELECT public.get_my_role()) IN ('Admin', 'Store')
  );

DROP POLICY IF EXISTS dispatch_items_read ON public.dispatch_items;
CREATE POLICY dispatch_items_read
  ON public.dispatch_items
  FOR SELECT
  TO authenticated
  USING (factory_id = (SELECT public.get_my_factory_id()));

DROP POLICY IF EXISTS dispatch_items_write ON public.dispatch_items;
CREATE POLICY dispatch_items_write
  ON public.dispatch_items
  FOR INSERT
  TO authenticated
  WITH CHECK (
    factory_id = (SELECT public.get_my_factory_id())
    AND (SELECT public.get_my_role()) IN ('Admin', 'Store')
    AND EXISTS (
      SELECT 1
      FROM public.dispatch_sessions AS ds
      WHERE ds.id = dispatch_items.session_id
        AND ds.factory_id = dispatch_items.factory_id
    )
  );

REVOKE ALL ON TABLE public.purchase_orders FROM anon;
REVOKE ALL ON TABLE public.ap_rejected_actions FROM anon;
REVOKE ALL ON TABLE public.dispatch_sessions FROM anon;
REVOKE ALL ON TABLE public.dispatch_items FROM anon;

GRANT SELECT, INSERT, UPDATE ON TABLE public.purchase_orders
  TO authenticated;
GRANT SELECT, INSERT ON TABLE public.ap_rejected_actions
  TO authenticated;
GRANT SELECT, INSERT ON TABLE public.dispatch_sessions
  TO authenticated;
GRANT SELECT, INSERT ON TABLE public.dispatch_items
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Controlled RTV state changes
-- ---------------------------------------------------------------------------

-- Quality/Admin status is derived from posted reinspection rows. The caller
-- cannot directly change batch, quantity, cycle, part, vendor, or factory.
CREATE OR REPLACE FUNCTION public.refresh_rtv_status(
  p_rtv_id uuid,
  p_factory_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role text;
  v_part_id uuid;
  v_rtv_qty numeric;
  v_cycle_number integer;
  v_current_status text;
  v_received_qty numeric;
  v_ok_qty numeric;
  v_reject_again_qty numeric;
  v_ledger_out_qty numeric;
  v_ledger_ok_qty numeric;
  v_ledger_reject_qty numeric;
  v_actual_return_date date;
  v_next_status text;
BEGIN
  IF auth.uid() IS NULL
    OR p_factory_id <> public.get_my_factory_id()
  THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_role := public.get_my_role();
  IF v_role NOT IN ('Admin', 'Quality Inspector') THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  SELECT r.part_id, r.rtv_qty, r.cycle_number, r.status
    INTO v_part_id, v_rtv_qty, v_cycle_number, v_current_status
  FROM public.rtvs AS r
  WHERE r.id = p_rtv_id
    AND r.factory_id = p_factory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RTV record not found';
  END IF;
  IF v_current_status IN ('scrapped', 'force_dispatched') THEN
    RETURN jsonb_build_object(
      'success', true,
      'idempotent', true,
      'status', v_current_status
    );
  END IF;

  SELECT
    COALESCE(SUM(rr.quantity_received), 0),
    COALESCE(SUM(rr.ok_qty), 0),
    COALESCE(SUM(rr.reject_again_qty), 0),
    MAX(rr.date)
  INTO
    v_received_qty,
    v_ok_qty,
    v_reject_again_qty,
    v_actual_return_date
  FROM public.rtv_reinspections AS rr
  WHERE rr.factory_id = p_factory_id
    AND rr.rtv_id = p_rtv_id;

  IF v_received_qty <= 0 THEN
    RAISE EXCEPTION 'RTV reinspection was not found';
  END IF;
  IF v_received_qty > v_rtv_qty THEN
    RAISE EXCEPTION 'RTV received quantity exceeds sent quantity';
  END IF;

  SELECT
    COALESCE(SUM(
      CASE
        WHEN sl.stage = 'rtv_stock' AND sl.direction = 'OUT'
          THEN sl.qty
        ELSE 0
      END
    ), 0),
    COALESCE(SUM(
      CASE
        WHEN sl.stage = 'approved_ap' AND sl.direction = 'IN'
          THEN sl.qty
        ELSE 0
      END
    ), 0),
    COALESCE(SUM(
      CASE
        WHEN sl.stage = 'rtv_stock' AND sl.direction = 'IN'
          THEN sl.qty
        ELSE 0
      END
    ), 0)
  INTO
    v_ledger_out_qty,
    v_ledger_ok_qty,
    v_ledger_reject_qty
  FROM public.stock_ledger AS sl
  WHERE sl.factory_id = p_factory_id
    AND sl.part_id = v_part_id
    AND sl.ref_table = 'rtv_reinspections'
    AND sl.ref_id IN (
      SELECT rr.id
      FROM public.rtv_reinspections AS rr
      WHERE rr.factory_id = p_factory_id
        AND rr.rtv_id = p_rtv_id
    );

  IF v_ledger_out_qty <> v_received_qty
    OR v_ledger_ok_qty <> v_ok_qty
    OR v_ledger_reject_qty <> v_reject_again_qty
  THEN
    RAISE EXCEPTION 'RTV ledger effects are not fully synced';
  END IF;

  v_next_status := CASE
    WHEN v_received_qty < v_rtv_qty THEN 'partially_received'
    WHEN v_reject_again_qty > 0 AND v_cycle_number >= 3 THEN 'escalated'
    WHEN v_reject_again_qty > 0 THEN 'rejected_again'
    ELSE 'approved'
  END;

  UPDATE public.rtvs
  SET
    status = v_next_status,
    actual_return_date = CASE
      WHEN v_received_qty = v_rtv_qty THEN v_actual_return_date
      ELSE NULL
    END
  WHERE id = p_rtv_id
    AND factory_id = p_factory_id;

  RETURN jsonb_build_object(
    'success', true,
    'idempotent', v_current_status = v_next_status,
    'status', v_next_status
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_rtv_escalation(
  p_rtv_id uuid,
  p_factory_id uuid,
  p_action text,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_part_id uuid;
  v_resolution_qty numeric;
  v_current_status text;
  v_ledger_out_qty numeric;
  v_ledger_approved_qty numeric;
BEGIN
  IF auth.uid() IS NULL
    OR p_factory_id <> public.get_my_factory_id()
    OR public.get_my_role() <> 'Admin'
  THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_action NOT IN ('scrapped', 'force_dispatched') THEN
    RAISE EXCEPTION 'invalid Admin action';
  END IF;
  IF COALESCE(btrim(p_reason), '') = ''
    OR char_length(btrim(p_reason)) > 1000
  THEN
    RAISE EXCEPTION 'Admin decision reason is required';
  END IF;

  SELECT
    r.part_id,
    r.status,
    COALESCE((
      SELECT SUM(rr.reject_again_qty)
      FROM public.rtv_reinspections AS rr
      WHERE rr.factory_id = r.factory_id
        AND rr.rtv_id = r.id
    ), 0)
  INTO v_part_id, v_current_status, v_resolution_qty
  FROM public.rtvs AS r
  WHERE r.id = p_rtv_id
    AND r.factory_id = p_factory_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RTV record not found';
  END IF;
  IF v_current_status = p_action THEN
    RETURN jsonb_build_object(
      'success', true,
      'idempotent', true,
      'status', p_action
    );
  END IF;
  IF v_current_status <> 'escalated' THEN
    RAISE EXCEPTION 'RTV is not awaiting an Admin decision';
  END IF;
  IF v_resolution_qty <= 0 THEN
    RAISE EXCEPTION 'No escalated RTV quantity is available';
  END IF;

  SELECT
    COALESCE(SUM(
      CASE
        WHEN sl.stage = 'rtv_stock' AND sl.direction = 'OUT'
          THEN sl.qty
        ELSE 0
      END
    ), 0),
    COALESCE(SUM(
      CASE
        WHEN sl.stage = 'approved_ap' AND sl.direction = 'IN'
          THEN sl.qty
        ELSE 0
      END
    ), 0)
  INTO v_ledger_out_qty, v_ledger_approved_qty
  FROM public.stock_ledger AS sl
  WHERE sl.factory_id = p_factory_id
    AND sl.part_id = v_part_id
    AND sl.ref_table = 'rtvs'
    AND sl.ref_id = p_rtv_id;

  IF v_ledger_out_qty <> v_resolution_qty
    OR (
      p_action = 'scrapped'
      AND v_ledger_approved_qty <> 0
    )
    OR (
      p_action = 'force_dispatched'
      AND v_ledger_approved_qty <> v_resolution_qty
    )
  THEN
    RAISE EXCEPTION 'RTV resolution ledger effects are not fully synced';
  END IF;

  UPDATE public.rtvs
  SET
    status = p_action,
    remarks = btrim(p_reason)
  WHERE id = p_rtv_id
    AND factory_id = p_factory_id;

  RETURN jsonb_build_object(
    'success', true,
    'idempotent', false,
    'status', p_action
  );
END;
$$;

DROP POLICY IF EXISTS rtvs_update ON public.rtvs;
DROP POLICY IF EXISTS rtvs_admin_update ON public.rtvs;
DROP POLICY IF EXISTS rtvs_quality_update ON public.rtvs;

REVOKE UPDATE ON TABLE public.rtvs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refresh_rtv_status(uuid, uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resolve_rtv_escalation(
  uuid, uuid, text, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refresh_rtv_status(uuid, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_rtv_escalation(
  uuid, uuid, text, text
) TO authenticated;

-- Rollback/mitigation:
-- 1. Pause sync if verification fails.
-- 2. Restore the previous helper/function definitions and grants from the prior
--    numbered migrations.
-- 3. Restore the previous RTV UPDATE policy only if the mobile RPC routing is
--    rolled back. Added nullable columns/tables remain to avoid data loss.
