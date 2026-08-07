-- Migration: dispatch_sessions, dispatch_items, and sync_conflicts on server
-- Aligns server schema with local dispatch_sessions/items model used by Final Dispatch.
-- Also adds sync_conflicts table for conflict review feature.

-- ── dispatch_sessions ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.dispatch_sessions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id      UUID NOT NULL REFERENCES public.factories(id),
  date            DATE NOT NULL,
  time            TEXT,
  customer_id     UUID REFERENCES public.customers(id),
  vehicle_id      UUID REFERENCES public.vehicles(id),
  driver_id       UUID REFERENCES public.drivers(id),
  challan_number  TEXT,
  remarks         TEXT,
  created_by      UUID REFERENCES public.users(id),
  sync_status     TEXT DEFAULT 'pending',
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dispatch_sessions_factory_date
  ON public.dispatch_sessions(factory_id, date);

ALTER TABLE public.dispatch_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "factory_member_read_dispatch_sessions"
  ON public.dispatch_sessions FOR SELECT TO authenticated
  USING (factory_id = public.get_my_factory_id());

CREATE POLICY "store_admin_insert_dispatch_sessions"
  ON public.dispatch_sessions FOR INSERT TO authenticated
  WITH CHECK (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() IN ('Admin', 'Store')
  );

GRANT SELECT, INSERT ON public.dispatch_sessions TO authenticated;

-- ── dispatch_items ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.dispatch_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id    UUID NOT NULL REFERENCES public.dispatch_sessions(id) ON DELETE CASCADE,
  factory_id    UUID NOT NULL REFERENCES public.factories(id),
  part_id       UUID REFERENCES public.parts(id),
  batch_number  TEXT,
  dispatch_qty  NUMERIC NOT NULL CHECK (dispatch_qty > 0),
  sync_status   TEXT DEFAULT 'pending',
  created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dispatch_items_session
  ON public.dispatch_items(session_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_items_factory_batch
  ON public.dispatch_items(factory_id, batch_number);

ALTER TABLE public.dispatch_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "factory_member_read_dispatch_items"
  ON public.dispatch_items FOR SELECT TO authenticated
  USING (factory_id = public.get_my_factory_id());

CREATE POLICY "store_admin_insert_dispatch_items"
  ON public.dispatch_items FOR INSERT TO authenticated
  WITH CHECK (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() IN ('Admin', 'Store')
  );

GRANT SELECT, INSERT ON public.dispatch_items TO authenticated;

-- ── sync_conflicts ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.sync_conflicts (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id          UUID NOT NULL REFERENCES public.factories(id),
  entity_type         TEXT NOT NULL,
  entity_id           TEXT NOT NULL,
  local_payload_json  JSONB,
  server_reason       TEXT,
  server_state_json   JSONB,
  suggested_action    TEXT,
  status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'resolved', 'cancelled')),
  reviewer            UUID REFERENCES public.users(id),
  resolved_at         TIMESTAMPTZ,
  created_at          TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sync_conflicts_factory_status
  ON public.sync_conflicts(factory_id, status);

ALTER TABLE public.sync_conflicts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "factory_member_read_conflicts"
  ON public.sync_conflicts FOR SELECT TO authenticated
  USING (factory_id = public.get_my_factory_id());

CREATE POLICY "admin_manage_conflicts"
  ON public.sync_conflicts FOR ALL TO authenticated
  USING (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() = 'Admin'
  )
  WITH CHECK (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() = 'Admin'
  );

GRANT SELECT ON public.sync_conflicts TO authenticated;
GRANT INSERT, UPDATE ON public.sync_conflicts TO authenticated;
