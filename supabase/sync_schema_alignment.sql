-- Align the hosted schema with the mobile app's offline-first command model.
-- Additive only: existing final_dispatches and operational history stay intact.

-- The mobile app creates the first workspace user as `owner`. On the server an
-- owner has the same authorization ceiling as Admin, while the stored role
-- remains `owner` for product semantics.
CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE WHEN role = 'owner' THEN 'Admin' ELSE role END
  FROM public.users
  WHERE id = auth.uid();
$$;

REVOKE ALL ON FUNCTION public.get_my_role() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_role() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_role() TO authenticated;

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
  ADD COLUMN IF NOT EXISTS po_ref_id uuid REFERENCES public.purchase_orders(id),
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
CREATE INDEX IF NOT EXISTS idx_ap_rejected_actions_factory_part
  ON public.ap_rejected_actions(factory_id, part_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_dispatch_sessions_factory_date
  ON public.dispatch_sessions(factory_id, date DESC, time DESC);
CREATE INDEX IF NOT EXISTS idx_dispatch_items_session
  ON public.dispatch_items(session_id);
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
      CHECK (ordered_qty IS NULL OR ordered_qty > 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'material_receives_shortfall_nonnegative'
      AND conrelid = 'public.material_receives'::regclass
  ) THEN
    ALTER TABLE public.material_receives
      ADD CONSTRAINT material_receives_shortfall_nonnegative
      CHECK (shortfall >= 0);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ap_inspections_rtv_within_rejected'
      AND conrelid = 'public.ap_inspections'::regclass
  ) THEN
    ALTER TABLE public.ap_inspections
      ADD CONSTRAINT ap_inspections_rtv_within_rejected
      CHECK (rtv_qty >= 0 AND rtv_qty <= rejected_qty);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ap_inspections_quantity_equation'
      AND conrelid = 'public.ap_inspections'::regclass
  ) THEN
    ALTER TABLE public.ap_inspections
      ADD CONSTRAINT ap_inspections_quantity_equation
      CHECK (approved_qty + rejected_qty = qty_checked);
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

ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ap_rejected_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispatch_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispatch_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rtvs_update ON public.rtvs;
DROP POLICY IF EXISTS rtvs_admin_update ON public.rtvs;
CREATE POLICY rtvs_admin_update
  ON public.rtvs
  FOR UPDATE
  TO authenticated
  USING (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() = 'Admin'
  )
  WITH CHECK (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() = 'Admin'
  );

DROP POLICY IF EXISTS rtvs_quality_update ON public.rtvs;
CREATE POLICY rtvs_quality_update
  ON public.rtvs
  FOR UPDATE
  TO authenticated
  USING (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() = 'Quality Inspector'
  )
  WITH CHECK (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() = 'Quality Inspector'
    AND status IN (
      'partially_received',
      'approved',
      'rejected_again',
      'escalated'
    )
  );

DROP POLICY IF EXISTS purchase_orders_read ON public.purchase_orders;
CREATE POLICY purchase_orders_read
  ON public.purchase_orders
  FOR SELECT
  TO authenticated
  USING (factory_id = public.get_my_factory_id());

DROP POLICY IF EXISTS purchase_orders_write ON public.purchase_orders;
CREATE POLICY purchase_orders_write
  ON public.purchase_orders
  FOR INSERT
  TO authenticated
  WITH CHECK (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() IN ('Admin', 'Store')
  );

DROP POLICY IF EXISTS purchase_orders_update ON public.purchase_orders;
CREATE POLICY purchase_orders_update
  ON public.purchase_orders
  FOR UPDATE
  TO authenticated
  USING (factory_id = public.get_my_factory_id())
  WITH CHECK (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() IN ('Admin', 'Store')
  );

DROP POLICY IF EXISTS ap_rejected_actions_read ON public.ap_rejected_actions;
CREATE POLICY ap_rejected_actions_read
  ON public.ap_rejected_actions
  FOR SELECT
  TO authenticated
  USING (factory_id = public.get_my_factory_id());

DROP POLICY IF EXISTS ap_rejected_actions_write ON public.ap_rejected_actions;
CREATE POLICY ap_rejected_actions_write
  ON public.ap_rejected_actions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() IN ('Admin', 'Quality Inspector')
  );

DROP POLICY IF EXISTS dispatch_sessions_read ON public.dispatch_sessions;
CREATE POLICY dispatch_sessions_read
  ON public.dispatch_sessions
  FOR SELECT
  TO authenticated
  USING (factory_id = public.get_my_factory_id());

DROP POLICY IF EXISTS dispatch_sessions_write ON public.dispatch_sessions;
CREATE POLICY dispatch_sessions_write
  ON public.dispatch_sessions
  FOR INSERT
  TO authenticated
  WITH CHECK (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() IN ('Admin', 'Store')
  );

DROP POLICY IF EXISTS dispatch_items_read ON public.dispatch_items;
CREATE POLICY dispatch_items_read
  ON public.dispatch_items
  FOR SELECT
  TO authenticated
  USING (factory_id = public.get_my_factory_id());

DROP POLICY IF EXISTS dispatch_items_write ON public.dispatch_items;
CREATE POLICY dispatch_items_write
  ON public.dispatch_items
  FOR INSERT
  TO authenticated
  WITH CHECK (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() IN ('Admin', 'Store')
    AND EXISTS (
      SELECT 1
      FROM public.dispatch_sessions session
      WHERE session.id = dispatch_items.session_id
        AND session.factory_id = dispatch_items.factory_id
    )
  );

REVOKE ALL ON TABLE public.purchase_orders FROM anon;
REVOKE ALL ON TABLE public.ap_rejected_actions FROM anon;
REVOKE ALL ON TABLE public.dispatch_sessions FROM anon;
REVOKE ALL ON TABLE public.dispatch_items FROM anon;

GRANT SELECT, INSERT, UPDATE ON TABLE public.purchase_orders TO authenticated;
GRANT SELECT, INSERT ON TABLE public.ap_rejected_actions TO authenticated;
GRANT SELECT, INSERT ON TABLE public.dispatch_sessions TO authenticated;
GRANT SELECT, INSERT ON TABLE public.dispatch_items TO authenticated;
GRANT UPDATE ON TABLE public.rtvs TO authenticated;
