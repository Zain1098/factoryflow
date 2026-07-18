-- Phase 1: apply after the baseline supabase_schema.sql on every existing
-- Supabase project. This migration is additive except for replacing unsafe
-- write policies with equivalent factory-scoped policies.

CREATE OR REPLACE FUNCTION public.get_my_factory_id()
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT factory_id FROM public.users WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT role FROM public.users WHERE id = auth.uid();
$$;

CREATE TABLE IF NOT EXISTS public.backup_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id uuid NOT NULL REFERENCES public.factories(id),
  user_id uuid REFERENCES public.users(id),
  source_table text NOT NULL,
  source_record_id text NOT NULL,
  data_json jsonb NOT NULL,
  backup_reason text,
  backed_up_at timestamptz NOT NULL DEFAULT now(),
  sync_status text DEFAULT 'pending'
);

CREATE INDEX IF NOT EXISTS idx_backup_records_user ON public.backup_records(user_id);
CREATE INDEX IF NOT EXISTS idx_backup_records_table ON public.backup_records(source_table);
CREATE INDEX IF NOT EXISTS idx_backup_records_at ON public.backup_records(backed_up_at);

ALTER TABLE public.backup_records ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_write" ON public.users;
DROP POLICY IF EXISTS "parts_write" ON public.parts;
DROP POLICY IF EXISTS "machines_write" ON public.machines;
DROP POLICY IF EXISTS "operators_write" ON public.operators;
DROP POLICY IF EXISTS "suppliers_write" ON public.suppliers;
DROP POLICY IF EXISTS "vendors_write" ON public.vendors;
DROP POLICY IF EXISTS "customers_write" ON public.customers;
DROP POLICY IF EXISTS "vehicles_write" ON public.vehicles;
DROP POLICY IF EXISTS "drivers_write" ON public.drivers;
DROP POLICY IF EXISTS "target_write" ON public.target_master;
DROP POLICY IF EXISTS "stock_ledger_write" ON public.stock_ledger;
DROP POLICY IF EXISTS "backup_records_admin_read" ON public.backup_records;
DROP POLICY IF EXISTS "backup_records_insert_own" ON public.backup_records;
DROP POLICY IF EXISTS "backup_records_update_own_sync" ON public.backup_records;

CREATE POLICY "users_write" ON public.users FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "parts_write" ON public.parts FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "machines_write" ON public.machines FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "operators_write" ON public.operators FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "suppliers_write" ON public.suppliers FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "vendors_write" ON public.vendors FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "customers_write" ON public.customers FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "vehicles_write" ON public.vehicles FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() IN ('Admin', 'Store'))
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() IN ('Admin', 'Store'));
CREATE POLICY "drivers_write" ON public.drivers FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() IN ('Admin', 'Store'))
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() IN ('Admin', 'Store'));
CREATE POLICY "target_write" ON public.target_master FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "backup_records_admin_read" ON public.backup_records FOR SELECT
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "backup_records_insert_own" ON public.backup_records FOR INSERT
  WITH CHECK (factory_id = public.get_my_factory_id() AND user_id = auth.uid());
CREATE POLICY "backup_records_update_own_sync" ON public.backup_records FOR UPDATE
  USING (factory_id = public.get_my_factory_id() AND user_id = auth.uid())
  WITH CHECK (factory_id = public.get_my_factory_id() AND user_id = auth.uid());

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

  UPDATE public.users
  SET active = false
  WHERE id = p_user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.request_account_deletion(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_account_deletion(uuid) TO authenticated;

-- Ledger rows are append-only and may only be written through the function
-- below. The function serializes balance changes per factory/part/stage.
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
