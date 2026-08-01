-- Migration: dispatch_sessions, dispatch_items, and sync_conflicts on server
-- Aligns server schema with local dispatch_sessions/items model used by Final Dispatch.
-- Also adds sync_conflicts table for conflict review feature.

-- ── dispatch_sessions ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS dispatch_sessions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id      UUID NOT NULL REFERENCES companies(id),
  date            DATE NOT NULL,
  time            TEXT,
  customer_id     UUID REFERENCES customers(id),
  vehicle_id      UUID REFERENCES vehicles(id),
  driver_id       UUID REFERENCES drivers(id),
  challan_number  TEXT,
  remarks         TEXT,
  created_by      UUID REFERENCES profiles(id),
  sync_status     TEXT DEFAULT 'pending',
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dispatch_sessions_factory_date
  ON dispatch_sessions(factory_id, date);

ALTER TABLE dispatch_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "factory_member_read_dispatch_sessions"
  ON dispatch_sessions FOR SELECT
  USING (get_user_factory_id() = factory_id);

CREATE POLICY "store_admin_insert_dispatch_sessions"
  ON dispatch_sessions FOR INSERT
  WITH CHECK (
    get_user_factory_id() = factory_id
    AND get_user_role() IN ('Admin', 'owner', 'Store')
  );

GRANT SELECT, INSERT ON dispatch_sessions TO authenticated;

-- ── dispatch_items ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS dispatch_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id    UUID NOT NULL REFERENCES dispatch_sessions(id) ON DELETE CASCADE,
  factory_id    UUID NOT NULL REFERENCES companies(id),
  part_id       UUID REFERENCES parts(id),
  batch_number  TEXT,
  dispatch_qty  NUMERIC NOT NULL CHECK (dispatch_qty > 0),
  sync_status   TEXT DEFAULT 'pending',
  created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dispatch_items_session
  ON dispatch_items(session_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_items_factory_batch
  ON dispatch_items(factory_id, batch_number);

ALTER TABLE dispatch_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "factory_member_read_dispatch_items"
  ON dispatch_items FOR SELECT
  USING (get_user_factory_id() = factory_id);

CREATE POLICY "store_admin_insert_dispatch_items"
  ON dispatch_items FOR INSERT
  WITH CHECK (
    get_user_factory_id() = factory_id
    AND get_user_role() IN ('Admin', 'owner', 'Store')
  );

GRANT SELECT, INSERT ON dispatch_items TO authenticated;

-- ── sync_conflicts ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sync_conflicts (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id          UUID NOT NULL REFERENCES companies(id),
  entity_type         TEXT NOT NULL,
  entity_id           TEXT NOT NULL,
  local_payload_json  JSONB,
  server_reason       TEXT,
  server_state_json   JSONB,
  suggested_action    TEXT,
  status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'resolved', 'cancelled')),
  reviewer            UUID REFERENCES profiles(id),
  resolved_at         TIMESTAMPTZ,
  created_at          TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sync_conflicts_factory_status
  ON sync_conflicts(factory_id, status);

ALTER TABLE sync_conflicts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "factory_member_read_conflicts"
  ON sync_conflicts FOR SELECT
  USING (get_user_factory_id() = factory_id);

CREATE POLICY "admin_manage_conflicts"
  ON sync_conflicts FOR ALL
  USING (
    get_user_factory_id() = factory_id
    AND get_user_role() IN ('Admin', 'owner')
  );

GRANT SELECT ON sync_conflicts TO authenticated;
GRANT INSERT, UPDATE ON sync_conflicts TO authenticated;
