-- Rejected material remains company inventory until an authorized final
-- rejection/write-off is recorded. This is additive and preserves existing
-- inspection and ledger history.

CREATE TABLE IF NOT EXISTS public.bp_rejected_actions (
  id uuid PRIMARY KEY,
  factory_id uuid NOT NULL REFERENCES public.factories(id),
  date date NOT NULL,
  part_id uuid NOT NULL REFERENCES public.parts(id),
  qty numeric NOT NULL CHECK (qty > 0),
  action text NOT NULL CHECK (action = 'final_rejected'),
  remarks text NOT NULL CHECK (char_length(btrim(remarks)) > 0),
  created_by uuid REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bp_rejected_actions_factory_part_date
  ON public.bp_rejected_actions(factory_id, part_id, date DESC);

ALTER TABLE public.bp_rejected_actions ENABLE ROW LEVEL SECURITY;

CREATE POLICY bp_rejected_actions_read
  ON public.bp_rejected_actions FOR SELECT TO authenticated
  USING (factory_id = (SELECT public.get_my_factory_id()));

CREATE POLICY bp_rejected_actions_write
  ON public.bp_rejected_actions FOR INSERT TO authenticated
  WITH CHECK (
    factory_id = (SELECT public.get_my_factory_id())
    AND (SELECT public.get_my_role()) IN ('Admin', 'Quality Inspector')
  );

REVOKE ALL ON TABLE public.bp_rejected_actions FROM anon;
GRANT SELECT, INSERT ON TABLE public.bp_rejected_actions TO authenticated;

-- The old constraints treated RTV as part of rejected_qty and did not allow
-- AP rejected stock to be independently held for final disposition.
ALTER TABLE public.ap_inspections
  DROP CONSTRAINT IF EXISTS ap_inspections_rtv_within_rejected;
ALTER TABLE public.ap_inspections
  DROP CONSTRAINT IF EXISTS ap_inspections_quantity_equation;
ALTER TABLE public.ap_inspections
  DROP CONSTRAINT IF EXISTS ap_split_check;

-- Under the previous rule RTV was included in rejected_qty. Preserve the
-- original checked total while separating RTV and AP-rejected stock semantics.
UPDATE public.ap_inspections
SET rejected_qty = rejected_qty - rtv_qty
WHERE rtv_qty > 0
  AND approved_qty + rejected_qty = qty_checked;

ALTER TABLE public.ap_inspections
  ADD CONSTRAINT ap_inspections_quantity_equation
  CHECK (
    qty_checked > 0
    AND approved_qty >= 0
    AND rejected_qty >= 0
    AND rtv_qty >= 0
    AND approved_qty + rejected_qty + rtv_qty = qty_checked
  ) NOT VALID;
ALTER TABLE public.ap_inspections
  VALIDATE CONSTRAINT ap_inspections_quantity_equation;

-- BP Hold is a real, visible quality location, so it must be accepted by both
-- the table constraint and the server-side append-only ledger writer.
ALTER TABLE public.stock_ledger
  DROP CONSTRAINT IF EXISTS stock_ledger_stage_check;
ALTER TABLE public.stock_ledger
  ADD CONSTRAINT stock_ledger_stage_check CHECK (
    stage IN (
      'raw_material', 'bp_stock', 'bp_hold', 'bp_rejected',
      'production_rejected', 'quality_hold', 'at_faco', 'pending_ap',
      'approved_ap', 'ap_rejected', 'rtv_stock'
    ) OR (stage LIKE 'production_wip_%' AND length(stage) > length('production_wip_'))
  );

CREATE OR REPLACE FUNCTION public.write_stock_ledger_entry(
  p_id uuid, p_factory_id uuid, p_part_id uuid, p_stage text,
  p_direction text, p_qty numeric, p_ref_table text, p_ref_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_role text;
  v_current_balance numeric := 0;
  v_next_balance numeric;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authorized'; END IF;
  SELECT wm.role INTO v_actor_role FROM public.workspace_members wm
    WHERE wm.workspace_id = p_factory_id AND wm.user_id = auth.uid()
      AND wm.status = 'active' LIMIT 1;
  IF v_actor_role IS NULL THEN
    SELECT u.role INTO v_actor_role FROM public.users u
      WHERE u.id = auth.uid() AND u.factory_id = p_factory_id
        AND COALESCE(u.active, true) LIMIT 1;
  END IF;
  IF lower(COALESCE(v_actor_role, '')) NOT IN
    ('owner', 'admin', 'production incharge', 'store', 'quality inspector') THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_id IS NULL OR p_factory_id IS NULL OR p_part_id IS NULL
    OR p_ref_id IS NULL OR p_qty IS NULL OR p_qty <= 0
    OR COALESCE(p_ref_table, '') = '' OR p_direction NOT IN ('IN', 'OUT')
    OR (p_stage NOT IN ('raw_material', 'bp_stock', 'bp_hold', 'bp_rejected',
      'production_rejected', 'quality_hold', 'at_faco', 'pending_ap',
      'approved_ap', 'ap_rejected', 'rtv_stock')
      AND NOT (p_stage LIKE 'production_wip_%' AND length(p_stage) > length('production_wip_')))
  THEN RAISE EXCEPTION 'invalid ledger entry'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.parts p WHERE p.id = p_part_id AND p.factory_id = p_factory_id)
  THEN RAISE EXCEPTION 'part does not belong to this factory'; END IF;
  IF EXISTS (SELECT 1 FROM public.stock_ledger sl WHERE sl.id = p_id)
  THEN RETURN jsonb_build_object('success', true, 'idempotent', true); END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('ledger|' || p_factory_id::text || '|' || p_part_id::text || '|' || p_stage, 0));
  SELECT sl.running_balance INTO v_current_balance FROM public.stock_ledger sl
    WHERE sl.factory_id = p_factory_id AND sl.part_id = p_part_id AND sl.stage = p_stage
    ORDER BY sl.created_at DESC, sl.id DESC LIMIT 1;
  v_current_balance := COALESCE(v_current_balance, 0);
  v_next_balance := CASE WHEN p_direction = 'IN' THEN v_current_balance + p_qty ELSE v_current_balance - p_qty END;
  IF v_next_balance < 0 THEN
    RETURN jsonb_build_object('success', false, 'conflict', true, 'error', 'Insufficient stock for this movement');
  END IF;
  INSERT INTO public.stock_ledger (id, factory_id, date, time, part_id, stage, direction, qty, ref_table, ref_id, running_balance)
  VALUES (p_id, p_factory_id, CURRENT_DATE, LOCALTIME, p_part_id, p_stage, p_direction, p_qty, p_ref_table, p_ref_id, v_next_balance);
  INSERT INTO public.audit_log (factory_id, table_name, record_id, action, old_value_json, new_value_json, changed_by, changed_at)
  VALUES (p_factory_id, 'stock_ledger', p_id, 'INSERT', NULL,
    jsonb_build_object('part_id', p_part_id, 'stage', p_stage, 'direction', p_direction, 'qty', p_qty, 'running_balance', v_next_balance), auth.uid(), now());
  RETURN jsonb_build_object('success', true, 'idempotent', false, 'running_balance', v_next_balance);
END;
$$;

REVOKE ALL ON FUNCTION public.write_stock_ledger_entry(uuid, uuid, uuid, text, text, numeric, text, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.write_stock_ledger_entry(uuid, uuid, uuid, text, text, numeric, text, uuid)
  TO authenticated;
