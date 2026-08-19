-- Manual AP-OK reconciliations remain tied to an existing production batch.
-- This preserves the batch trail used by Final Dispatch while allowing an
-- owner/admin to correct the verified balance of that batch.
ALTER TABLE public.stock_adjustments
  ADD COLUMN IF NOT EXISTS batch_number text;

CREATE INDEX IF NOT EXISTS idx_stock_adjustments_batch_reconciliation
  ON public.stock_adjustments (factory_id, part_id, stage, batch_number)
  WHERE batch_number IS NOT NULL;
