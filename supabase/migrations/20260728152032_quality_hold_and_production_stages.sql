-- Quality Hold is a batch-level, auditable stock state. This migration is
-- additive and also permits the dynamic production WIP stages used by mobile.

CREATE TABLE IF NOT EXISTS public.quality_holds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id uuid NOT NULL REFERENCES public.factories(id),
  batch_number text NOT NULL,
  part_id uuid NOT NULL REFERENCES public.parts(id),
  qty numeric NOT NULL CHECK (qty > 0),
  reason text NOT NULL,
  status text NOT NULL DEFAULT 'hold'
    CHECK (status IN ('hold', 'released')),
  inspector_id uuid REFERENCES public.users(id),
  held_at timestamptz NOT NULL DEFAULT now(),
  released_by uuid REFERENCES public.users(id),
  released_at timestamptz,
  release_remarks text,
  sync_status text DEFAULT 'pending'
);

CREATE INDEX IF NOT EXISTS idx_quality_holds_factory_status
  ON public.quality_holds(factory_id, status, held_at DESC);
CREATE INDEX IF NOT EXISTS idx_quality_holds_part
  ON public.quality_holds(part_id);

ALTER TABLE public.quality_holds ENABLE ROW LEVEL SECURITY;

CREATE POLICY "quality_holds_read" ON public.quality_holds FOR SELECT
  USING (factory_id = public.get_my_factory_id());

CREATE POLICY "quality_holds_insert" ON public.quality_holds FOR INSERT
  WITH CHECK (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() IN ('owner', 'Admin', 'Quality Inspector')
  );

CREATE POLICY "quality_holds_update" ON public.quality_holds FOR UPDATE
  USING (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() IN ('owner', 'Admin', 'Quality Inspector')
  )
  WITH CHECK (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() IN ('owner', 'Admin', 'Quality Inspector')
  );

GRANT SELECT, INSERT, UPDATE ON public.quality_holds TO authenticated;

-- Allow the mobile application's append-only ledger to use the production
-- stages added after the original Phase 1 migration.
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
  IF public.get_my_role() NOT IN ('owner', 'Admin', 'Production Incharge', 'Store', 'Quality Inspector') THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_qty <= 0 OR p_direction NOT IN ('IN', 'OUT') OR (
    p_stage NOT IN (
      'raw_material', 'bp_stock', 'bp_rejected', 'production_rejected',
      'quality_hold', 'at_faco', 'pending_ap', 'approved_ap',
      'ap_rejected', 'rtv_stock'
    ) AND p_stage NOT LIKE 'production_wip_%'
  ) THEN
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
