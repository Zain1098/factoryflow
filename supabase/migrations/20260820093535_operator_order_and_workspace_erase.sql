-- Keep the saved production-operator order consistent on every device.
ALTER TABLE public.operators
  ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 0;

WITH ranked AS (
  SELECT id, row_number() OVER (
    PARTITION BY factory_id ORDER BY sort_order, name, id
  ) AS next_order
  FROM public.operators
)
UPDATE public.operators AS operator
SET sort_order = ranked.next_order
FROM ranked
WHERE ranked.id = operator.id AND operator.sort_order = 0;

CREATE INDEX IF NOT EXISTS idx_operators_factory_sort_order
  ON public.operators (factory_id, sort_order, name);

-- Erase All must clear source records and derived stock rows. The server is
-- authoritative, preventing another device from hydrating stale stock later.
CREATE OR REPLACE FUNCTION public.erase_workspace_transaction_data(
  p_factory_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_factory_id IS NULL OR NOT public.can_manage_workspace(p_factory_id) THEN
    RAISE EXCEPTION 'You are not allowed to erase this workspace data';
  END IF;

  DELETE FROM public.dispatch_items WHERE factory_id = p_factory_id;
  DELETE FROM public.dispatch_sessions WHERE factory_id = p_factory_id;
  DELETE FROM public.rtv_reinspections WHERE factory_id = p_factory_id;
  DELETE FROM public.ap_rejected_actions WHERE factory_id = p_factory_id;
  DELETE FROM public.stock_adjustments WHERE factory_id = p_factory_id;
  DELETE FROM public.stock_ledger WHERE factory_id = p_factory_id;
  DELETE FROM public.final_dispatches WHERE factory_id = p_factory_id;
  DELETE FROM public.rtvs WHERE factory_id = p_factory_id;
  DELETE FROM public.ap_inspections WHERE factory_id = p_factory_id;
  DELETE FROM public.receive_from_facos WHERE factory_id = p_factory_id;
  DELETE FROM public.dispatch_to_facos WHERE factory_id = p_factory_id;
  DELETE FROM public.bp_inspections WHERE factory_id = p_factory_id;
  DELETE FROM public.machine_downtimes WHERE factory_id = p_factory_id;
  DELETE FROM public.productions WHERE factory_id = p_factory_id;
  DELETE FROM public.material_receives WHERE factory_id = p_factory_id;
  DELETE FROM public.purchase_orders WHERE factory_id = p_factory_id;
  DELETE FROM public.physical_counts WHERE factory_id = p_factory_id;
  DELETE FROM public.correction_requests WHERE factory_id = p_factory_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.erase_workspace_transaction_data(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.erase_workspace_transaction_data(uuid) TO authenticated;
