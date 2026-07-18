-- Phase 4: Schema fixes — role constraint, active column, machine_code, stock_adjustments
-- Apply after 202607140001_auth_avatar_otp.sql

-- ── Fix users role constraint to allow 'owner' ────────────────────────────────
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE public.users ADD CONSTRAINT users_role_check
  CHECK (role IN ('owner', 'Admin', 'Production Incharge', 'Store', 'Quality Inspector', 'Viewer'));

-- ── Add active column to factories if missing ─────────────────────────────────
ALTER TABLE public.factories ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT TRUE;

-- ── Add machine_code to machines if missing ───────────────────────────────────
ALTER TABLE public.machines ADD COLUMN IF NOT EXISTS machine_code TEXT;

-- ── stock_adjustments table ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.stock_adjustments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id UUID NOT NULL REFERENCES public.factories(id),
  user_id UUID REFERENCES public.users(id),
  part_id UUID NOT NULL REFERENCES public.parts(id),
  stage TEXT NOT NULL,
  previous_qty NUMERIC NOT NULL DEFAULT 0,
  adjusted_qty NUMERIC NOT NULL,
  new_qty NUMERIC NOT NULL,
  remarks TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sync_status TEXT DEFAULT 'pending'
);

CREATE INDEX IF NOT EXISTS idx_stock_adj_factory ON public.stock_adjustments(factory_id);
CREATE INDEX IF NOT EXISTS idx_stock_adj_part ON public.stock_adjustments(part_id);
CREATE INDEX IF NOT EXISTS idx_stock_adj_created ON public.stock_adjustments(created_at);

ALTER TABLE public.stock_adjustments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "stock_adj_read" ON public.stock_adjustments FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

CREATE POLICY "stock_adj_insert" ON public.stock_adjustments FOR INSERT
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

CREATE POLICY "stock_adj_update_sync" ON public.stock_adjustments FOR UPDATE
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));
