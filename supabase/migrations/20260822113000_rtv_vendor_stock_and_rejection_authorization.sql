-- Keep RTV hold and vendor-outstanding material as separate, auditable stock
-- locations. Also align final-rejection permissions with the Owner role that
-- can access the mobile quality workflow.

ALTER TABLE public.stock_ledger
  DROP CONSTRAINT IF EXISTS stock_ledger_stage_check;
ALTER TABLE public.stock_ledger
  ADD CONSTRAINT stock_ledger_stage_check CHECK (
    stage IN ('raw_material', 'bp_stock', 'bp_hold', 'bp_rejected',
      'production_rejected', 'quality_hold', 'at_faco', 'pending_ap',
      'approved_ap', 'ap_rejected', 'rtv_stock', 'rtv_at_vendor')
    OR (stage LIKE 'production_wip_%' AND length(stage) > length('production_wip_'))
  );

-- Final rejection must remain traceable to the inspection batch it came from.
ALTER TABLE public.ap_rejected_actions
  ADD COLUMN IF NOT EXISTS batch_number text;
ALTER TABLE public.bp_rejected_actions
  ADD COLUMN IF NOT EXISTS batch_number text;
CREATE INDEX IF NOT EXISTS idx_ap_rejected_actions_factory_part_batch
  ON public.ap_rejected_actions(factory_id, part_id, batch_number);
CREATE INDEX IF NOT EXISTS idx_bp_rejected_actions_factory_part_batch
  ON public.bp_rejected_actions(factory_id, part_id, batch_number);

CREATE OR REPLACE FUNCTION public.write_stock_ledger_entry(
  p_id uuid, p_factory_id uuid, p_part_id uuid, p_stage text,
  p_direction text, p_qty numeric, p_ref_table text, p_ref_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_role text; v_balance numeric := 0; v_next numeric;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authorized'; END IF;
  SELECT wm.role INTO v_role FROM public.workspace_members wm
    WHERE wm.workspace_id=p_factory_id AND wm.user_id=auth.uid() AND wm.status='active' LIMIT 1;
  IF v_role IS NULL THEN SELECT u.role INTO v_role FROM public.users u
    WHERE u.id=auth.uid() AND u.factory_id=p_factory_id AND COALESCE(u.active,true) LIMIT 1; END IF;
  IF lower(COALESCE(v_role,'')) NOT IN ('owner','admin','production incharge','store','quality inspector') THEN RAISE EXCEPTION 'not authorized'; END IF;
  IF p_id IS NULL OR p_factory_id IS NULL OR p_part_id IS NULL OR p_ref_id IS NULL
    OR p_qty IS NULL OR p_qty<=0 OR COALESCE(p_ref_table,'')='' OR p_direction NOT IN ('IN','OUT')
    OR (p_stage NOT IN ('raw_material','bp_stock','bp_hold','bp_rejected','production_rejected','quality_hold','at_faco','pending_ap','approved_ap','ap_rejected','rtv_stock','rtv_at_vendor')
      AND NOT (p_stage LIKE 'production_wip_%' AND length(p_stage)>length('production_wip_')))
  THEN RAISE EXCEPTION 'invalid ledger entry'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.parts p WHERE p.id=p_part_id AND p.factory_id=p_factory_id) THEN RAISE EXCEPTION 'part does not belong to this factory'; END IF;
  IF EXISTS (SELECT 1 FROM public.stock_ledger sl WHERE sl.id=p_id) THEN RETURN jsonb_build_object('success',true,'idempotent',true); END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('ledger|'||p_factory_id::text||'|'||p_part_id::text||'|'||p_stage,0));
  SELECT sl.running_balance INTO v_balance FROM public.stock_ledger sl WHERE sl.factory_id=p_factory_id AND sl.part_id=p_part_id AND sl.stage=p_stage ORDER BY sl.created_at DESC,sl.id DESC LIMIT 1;
  v_balance := COALESCE(v_balance,0); v_next := CASE WHEN p_direction='IN' THEN v_balance+p_qty ELSE v_balance-p_qty END;
  IF v_next<0 THEN RETURN jsonb_build_object('success',false,'conflict',true,'error','Insufficient stock for this movement'); END IF;
  INSERT INTO public.stock_ledger (id,factory_id,date,time,part_id,stage,direction,qty,ref_table,ref_id,running_balance)
  VALUES (p_id,p_factory_id,CURRENT_DATE,LOCALTIME,p_part_id,p_stage,p_direction,p_qty,p_ref_table,p_ref_id,v_next);
  INSERT INTO public.audit_log (factory_id,table_name,record_id,action,old_value_json,new_value_json,changed_by,changed_at)
  VALUES (p_factory_id,'stock_ledger',p_id,'INSERT',NULL,jsonb_build_object('part_id',p_part_id,'stage',p_stage,'direction',p_direction,'qty',p_qty,'running_balance',v_next),auth.uid(),now());
  RETURN jsonb_build_object('success',true,'idempotent',false,'running_balance',v_next);
END; $$;

REVOKE ALL ON FUNCTION public.write_stock_ledger_entry(uuid,uuid,uuid,text,text,numeric,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.write_stock_ledger_entry(uuid,uuid,uuid,text,text,numeric,text,uuid) TO authenticated;

DROP POLICY IF EXISTS ap_rejected_actions_write ON public.ap_rejected_actions;
CREATE POLICY ap_rejected_actions_write ON public.ap_rejected_actions FOR INSERT TO authenticated
  WITH CHECK (factory_id=(SELECT public.get_my_factory_id())
    AND lower((SELECT public.get_my_role())) IN ('owner','admin','quality inspector'));

DROP POLICY IF EXISTS bp_rejected_actions_write ON public.bp_rejected_actions;
CREATE POLICY bp_rejected_actions_write ON public.bp_rejected_actions FOR INSERT TO authenticated
  WITH CHECK (factory_id=(SELECT public.get_my_factory_id())
    AND lower((SELECT public.get_my_role())) IN ('owner','admin','quality inspector'));
