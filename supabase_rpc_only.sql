-- ============================================================
-- ProFlow — RPCs / Functions only
-- Safe to run on a live Supabase project where tables already exist.
-- Run in Supabase SQL Editor (paste & execute).
-- ============================================================

-- ── 1. get_my_factory_id ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_factory_id()
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT factory_id FROM public.users WHERE id = auth.uid();
$$;

-- ── 2. get_my_role ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT role FROM public.users WHERE id = auth.uid();
$$;

-- ── 3. get_my_workspace_ids ──────────────────────────────────
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

-- ── 4. create_user_workspace ─────────────────────────────────
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

  SELECT email INTO v_email FROM auth.users WHERE id = v_user_id;

  INSERT INTO public.factories (id, name, active)
  VALUES (v_workspace_id, p_workspace_name, true)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.users (id, factory_id, name, email, role, active)
  VALUES (v_user_id, v_workspace_id, p_profile_name, v_email, 'owner', true)
  ON CONFLICT (id) DO UPDATE
    SET factory_id = v_workspace_id, name = p_profile_name;

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

-- ── 5. handle_google_auth_user ───────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_google_auth_user(
  p_user_id UUID,
  p_email TEXT,
  p_name TEXT,
  p_avatar_url TEXT,
  p_workspace_name TEXT DEFAULT 'My Workspace'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_workspace_id UUID;
  v_existing_user RECORD;
BEGIN
  SELECT * INTO v_existing_user FROM public.users WHERE id = p_user_id;

  IF v_existing_user.id IS NOT NULL THEN
    UPDATE public.users
    SET
      name = COALESCE(p_name, name),
      email = p_email,
      avatar_url = COALESCE(p_avatar_url, avatar_url)
    WHERE id = p_user_id;

    RETURN jsonb_build_object(
      'is_new', FALSE,
      'workspace_id', v_existing_user.factory_id
    );
  ELSE
    v_workspace_id := gen_random_uuid();

    INSERT INTO public.factories (id, name, active)
    VALUES (v_workspace_id, p_workspace_name, TRUE);

    INSERT INTO public.users (id, factory_id, name, email, role, active, avatar_url)
    VALUES (p_user_id, v_workspace_id, p_name, p_email, 'owner', TRUE, p_avatar_url);

    INSERT INTO public.workspace_members (id, workspace_id, user_id, role, status)
    VALUES (gen_random_uuid(), v_workspace_id, p_user_id, 'owner', 'active');

    RETURN jsonb_build_object(
      'is_new', TRUE,
      'workspace_id', v_workspace_id
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_google_auth_user(UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.handle_google_auth_user(UUID, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- ── 6. generate_otp ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_otp(
  p_user_id UUID,
  p_purpose TEXT,
  p_new_value TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code TEXT;
BEGIN
  v_code := LPAD(CAST(FLOOR(RANDOM() * 1000000) AS INTEGER)::TEXT, 6, '0');

  INSERT INTO public.otp_codes (user_id, code, purpose, new_value, expires_at)
  VALUES (p_user_id, v_code, p_purpose, p_new_value, NOW() + INTERVAL '10 minutes');

  RETURN v_code;
END;
$$;

REVOKE ALL ON FUNCTION public.generate_otp(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_otp(UUID, TEXT, TEXT) TO authenticated;

-- ── 7. verify_otp ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.verify_otp(
  p_user_id UUID,
  p_code TEXT,
  p_purpose TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_otp RECORD;
BEGIN
  SELECT * INTO v_otp FROM public.otp_codes
  WHERE user_id = p_user_id
    AND code = p_code
    AND purpose = p_purpose
    AND used = FALSE
    AND expires_at > NOW()
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_otp.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Invalid or expired OTP');
  END IF;

  UPDATE public.otp_codes SET used = TRUE WHERE id = v_otp.id;

  RETURN jsonb_build_object('success', TRUE, 'new_value', v_otp.new_value);
END;
$$;

REVOKE ALL ON FUNCTION public.verify_otp(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_otp(UUID, TEXT, TEXT) TO authenticated;

-- ── 8. update_user_profile ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_user_profile(
  p_user_id UUID,
  p_name TEXT DEFAULT NULL,
  p_avatar_url TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users
  SET
    name = COALESCE(p_name, name),
    avatar_url = COALESCE(p_avatar_url, avatar_url)
  WHERE id = p_user_id AND id = auth.uid();

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.update_user_profile(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_user_profile(UUID, TEXT, TEXT) TO authenticated;

-- ── 9. update_user_email_after_otp ───────────────────────────
CREATE OR REPLACE FUNCTION public.update_user_email_after_otp(
  p_user_id UUID,
  p_new_email TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users
  SET email = p_new_email
  WHERE id = p_user_id AND id = auth.uid();

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.update_user_email_after_otp(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_user_email_after_otp(UUID, TEXT) TO authenticated;

-- ── 10. admin_update_user_email (service_role only) ──────────
CREATE OR REPLACE FUNCTION public.admin_update_user_email(
  p_user_id UUID,
  p_new_email TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF current_setting('role') != 'service_role' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Service role required');
  END IF;

  UPDATE auth.users SET email = p_new_email WHERE id = p_user_id;

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_update_user_email(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_user_email(UUID, TEXT) TO service_role;

-- ── 11. write_stock_ledger_entry ─────────────────────────────
CREATE OR REPLACE FUNCTION public.write_stock_ledger_entry(
  p_id uuid,
  p_factory_id uuid,
  p_part_id uuid,
  p_stage text,
  p_direction text,
  p_qty numeric,
  p_ref_table text,
  p_ref_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_balance numeric := 0;
  next_balance numeric;
BEGIN
  IF auth.uid() IS NULL OR p_factory_id <> public.get_my_factory_id() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF public.get_my_role() NOT IN ('Admin', 'Production Incharge', 'Store', 'Quality Inspector') THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_qty <= 0 OR p_direction NOT IN ('IN', 'OUT') OR
      p_stage NOT IN ('raw_material', 'bp_stock', 'at_faco', 'pending_ap', 'approved_ap', 'rtv_stock') THEN
    RAISE EXCEPTION 'invalid ledger entry';
  END IF;
  IF EXISTS (SELECT 1 FROM public.stock_ledger WHERE stock_ledger.id = p_id) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_factory_id::text || p_part_id::text || p_stage, 0));
  SELECT running_balance INTO current_balance
  FROM public.stock_ledger
  WHERE stock_ledger.factory_id = p_factory_id
    AND stock_ledger.part_id = p_part_id
    AND stock_ledger.stage = p_stage
  ORDER BY created_at DESC
  LIMIT 1;
  current_balance := COALESCE(current_balance, 0);
  next_balance := CASE WHEN p_direction = 'IN' THEN current_balance + p_qty ELSE current_balance - p_qty END;
  IF next_balance < 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Insufficient stock for this movement');
  END IF;

  INSERT INTO public.stock_ledger (
    id, factory_id, date, time, part_id, stage, direction, qty,
    ref_table, ref_id, running_balance
  ) VALUES (
    p_id, p_factory_id, CURRENT_DATE, CURRENT_TIME, p_part_id, p_stage, p_direction, p_qty,
    p_ref_table, p_ref_id, next_balance
  );
  INSERT INTO public.audit_log (
    factory_id, table_name, record_id, action, old_value_json, new_value_json,
    changed_by, changed_at
  ) VALUES (
    p_factory_id, 'stock_ledger', p_id, 'INSERT', NULL,
    jsonb_build_object('part_id', p_part_id, 'stage', p_stage, 'direction', p_direction, 'qty', p_qty, 'running_balance', next_balance)::text,
    auth.uid(), NOW()
  );
  RETURN jsonb_build_object('success', true, 'running_balance', next_balance);
END;
$$;

REVOKE ALL ON FUNCTION public.write_stock_ledger_entry(uuid, uuid, uuid, text, text, numeric, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.write_stock_ledger_entry(uuid, uuid, uuid, text, text, numeric, text, uuid) TO authenticated;

-- ── 12. request_account_deletion ─────────────────────────────
CREATE OR REPLACE FUNCTION public.request_account_deletion(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  UPDATE public.users SET active = false WHERE id = p_user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.request_account_deletion(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_account_deletion(uuid) TO authenticated;

-- ── RLS policies that depend on the functions above ──────────
-- These use DROP IF EXISTS so re-running is safe.

-- workspace_members
DROP POLICY IF EXISTS "workspace_members_read_own" ON public.workspace_members;
CREATE POLICY "workspace_members_read_own" ON public.workspace_members FOR SELECT
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "workspace_members_owner_write" ON public.workspace_members;
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

-- otp_codes
DROP POLICY IF EXISTS "otp_codes_read_own" ON public.otp_codes;
CREATE POLICY "otp_codes_read_own" ON public.otp_codes FOR SELECT
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "otp_codes_insert_own" ON public.otp_codes;
CREATE POLICY "otp_codes_insert_own" ON public.otp_codes FOR INSERT
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "otp_codes_update_own" ON public.otp_codes;
CREATE POLICY "otp_codes_update_own" ON public.otp_codes FOR UPDATE
  USING (user_id = auth.uid());

-- stock_adjustments
DROP POLICY IF EXISTS "stock_adj_read" ON public.stock_adjustments;
CREATE POLICY "stock_adj_read" ON public.stock_adjustments FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "stock_adj_insert" ON public.stock_adjustments;
CREATE POLICY "stock_adj_insert" ON public.stock_adjustments FOR INSERT
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "stock_adj_update_sync" ON public.stock_adjustments;
CREATE POLICY "stock_adj_update_sync" ON public.stock_adjustments FOR UPDATE
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- backup_records
DROP POLICY IF EXISTS "backup_records_admin_read" ON public.backup_records;
CREATE POLICY "backup_records_admin_read" ON public.backup_records FOR SELECT
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');

DROP POLICY IF EXISTS "backup_records_insert_own" ON public.backup_records;
CREATE POLICY "backup_records_insert_own" ON public.backup_records FOR INSERT
  WITH CHECK (factory_id = public.get_my_factory_id() AND user_id = auth.uid());

DROP POLICY IF EXISTS "backup_records_update_own_sync" ON public.backup_records;
CREATE POLICY "backup_records_update_own_sync" ON public.backup_records FOR UPDATE
  USING (factory_id = public.get_my_factory_id() AND user_id = auth.uid())
  WITH CHECK (factory_id = public.get_my_factory_id() AND user_id = auth.uid());

-- data tables — workspace-membership-based read/write
DROP POLICY IF EXISTS "parts_read" ON public.parts;
CREATE POLICY "parts_read" ON public.parts FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
DROP POLICY IF EXISTS "parts_write" ON public.parts;
CREATE POLICY "parts_write" ON public.parts FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "machines_read" ON public.machines;
CREATE POLICY "machines_read" ON public.machines FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
DROP POLICY IF EXISTS "machines_write" ON public.machines;
CREATE POLICY "machines_write" ON public.machines FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "operators_read" ON public.operators;
CREATE POLICY "operators_read" ON public.operators FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
DROP POLICY IF EXISTS "operators_write" ON public.operators;
CREATE POLICY "operators_write" ON public.operators FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "suppliers_read" ON public.suppliers;
CREATE POLICY "suppliers_read" ON public.suppliers FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
DROP POLICY IF EXISTS "suppliers_write" ON public.suppliers;
CREATE POLICY "suppliers_write" ON public.suppliers FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "vendors_read" ON public.vendors;
CREATE POLICY "vendors_read" ON public.vendors FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
DROP POLICY IF EXISTS "vendors_write" ON public.vendors;
CREATE POLICY "vendors_write" ON public.vendors FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "customers_read" ON public.customers;
CREATE POLICY "customers_read" ON public.customers FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
DROP POLICY IF EXISTS "customers_write" ON public.customers;
CREATE POLICY "customers_write" ON public.customers FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "vehicles_read" ON public.vehicles;
CREATE POLICY "vehicles_read" ON public.vehicles FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
DROP POLICY IF EXISTS "vehicles_write" ON public.vehicles;
CREATE POLICY "vehicles_write" ON public.vehicles FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "drivers_read" ON public.drivers;
CREATE POLICY "drivers_read" ON public.drivers FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));
DROP POLICY IF EXISTS "drivers_write" ON public.drivers;
CREATE POLICY "drivers_write" ON public.drivers FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));
