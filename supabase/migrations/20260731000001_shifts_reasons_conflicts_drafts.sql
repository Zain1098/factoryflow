-- Migration: shifts, reject reasons, sync_conflicts, draft_forms, physical_counts
-- Forward-only, non-destructive. Safe to apply on existing databases.

-- ── Shifts ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS shifts (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id  UUID NOT NULL REFERENCES factories(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  start_time  TEXT,
  end_time    TEXT,
  active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_shifts_factory ON shifts(factory_id);

ALTER TABLE shifts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS shifts_factory_read  ON shifts;
DROP POLICY IF EXISTS shifts_admin_write   ON shifts;
CREATE POLICY shifts_factory_read  ON shifts FOR SELECT USING (
  factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active')
);
CREATE POLICY shifts_admin_write   ON shifts FOR ALL USING (
  factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active'
    AND role IN ('Admin', 'owner'))
);
GRANT SELECT, INSERT, UPDATE ON shifts TO authenticated;

-- ── BP Reject Reasons ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bp_reject_reasons (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id  UUID NOT NULL REFERENCES factories(id) ON DELETE CASCADE,
  reason      TEXT NOT NULL,
  active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_bp_reasons_factory ON bp_reject_reasons(factory_id);

ALTER TABLE bp_reject_reasons ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bp_reasons_read  ON bp_reject_reasons;
DROP POLICY IF EXISTS bp_reasons_write ON bp_reject_reasons;
CREATE POLICY bp_reasons_read  ON bp_reject_reasons FOR SELECT USING (
  factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active')
);
CREATE POLICY bp_reasons_write ON bp_reject_reasons FOR ALL USING (
  factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active'
    AND role IN ('Admin', 'owner'))
);
GRANT SELECT, INSERT, UPDATE ON bp_reject_reasons TO authenticated;

-- ── AP Reject Reasons ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ap_reject_reasons (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id  UUID NOT NULL REFERENCES factories(id) ON DELETE CASCADE,
  reason      TEXT NOT NULL,
  active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_ap_reasons_factory ON ap_reject_reasons(factory_id);

ALTER TABLE ap_reject_reasons ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ap_reasons_read  ON ap_reject_reasons;
DROP POLICY IF EXISTS ap_reasons_write ON ap_reject_reasons;
CREATE POLICY ap_reasons_read  ON ap_reject_reasons FOR SELECT USING (
  factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active')
);
CREATE POLICY ap_reasons_write ON ap_reject_reasons FOR ALL USING (
  factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active'
    AND role IN ('Admin', 'owner'))
);
GRANT SELECT, INSERT, UPDATE ON ap_reject_reasons TO authenticated;

-- ── RTV Reasons ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rtv_reasons (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id  UUID NOT NULL REFERENCES factories(id) ON DELETE CASCADE,
  reason      TEXT NOT NULL,
  active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_rtv_reasons_factory ON rtv_reasons(factory_id);

ALTER TABLE rtv_reasons ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rtv_reasons_read  ON rtv_reasons;
DROP POLICY IF EXISTS rtv_reasons_write ON rtv_reasons;
CREATE POLICY rtv_reasons_read  ON rtv_reasons FOR SELECT USING (
  factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active')
);
CREATE POLICY rtv_reasons_write ON rtv_reasons FOR ALL USING (
  factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active'
    AND role IN ('Admin', 'owner'))
);
GRANT SELECT, INSERT, UPDATE ON rtv_reasons TO authenticated;

-- ── Sync Conflicts ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sync_conflicts (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id          UUID NOT NULL REFERENCES factories(id) ON DELETE CASCADE,
  entity_type         TEXT NOT NULL,
  entity_id           UUID NOT NULL,
  local_payload_json  JSONB,
  server_reason       TEXT,
  server_state_json   JSONB,
  suggested_action    TEXT,
  status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'resolved', 'cancelled')),
  reviewer            UUID REFERENCES auth.users(id),
  resolved_at         TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_sync_conflicts_factory ON sync_conflicts(factory_id, status);

ALTER TABLE sync_conflicts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS conflicts_read   ON sync_conflicts;
DROP POLICY IF EXISTS conflicts_write  ON sync_conflicts;
CREATE POLICY conflicts_read  ON sync_conflicts FOR SELECT USING (
  factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active')
);
CREATE POLICY conflicts_write ON sync_conflicts FOR ALL USING (
  factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active'
    AND role IN ('Admin', 'owner'))
);
GRANT SELECT, INSERT, UPDATE ON sync_conflicts TO authenticated;

-- ── Draft Forms ───────────────────────────────────────────────────────────────
-- Drafts are device-local only; this table exists for future cross-device draft sync.
CREATE TABLE IF NOT EXISTS draft_forms (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id      UUID NOT NULL REFERENCES factories(id) ON DELETE CASCADE,
  module          TEXT NOT NULL,
  form_data_json  JSONB NOT NULL,
  created_by      UUID REFERENCES auth.users(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_drafts_factory_module ON draft_forms(factory_id, module);

ALTER TABLE draft_forms ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS drafts_own ON draft_forms;
CREATE POLICY drafts_own ON draft_forms FOR ALL USING (
  created_by = auth.uid()
  AND factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active')
);
GRANT SELECT, INSERT, UPDATE, DELETE ON draft_forms TO authenticated;

-- ── Physical Counts ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS physical_counts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id   UUID NOT NULL REFERENCES factories(id) ON DELETE CASCADE,
  part_id      UUID NOT NULL REFERENCES parts(id),
  stage        TEXT NOT NULL,
  counted_qty  NUMERIC(12,3) NOT NULL CHECK (counted_qty >= 0),
  system_qty   NUMERIC(12,3) NOT NULL,
  variance     NUMERIC(12,3) GENERATED ALWAYS AS (counted_qty - system_qty) STORED,
  counted_by   UUID REFERENCES auth.users(id),
  counted_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'rejected')),
  approved_by  UUID REFERENCES auth.users(id),
  approved_at  TIMESTAMPTZ,
  remarks      TEXT
);
CREATE INDEX IF NOT EXISTS idx_physical_counts_factory ON physical_counts(factory_id, status);

ALTER TABLE physical_counts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS phys_counts_read   ON physical_counts;
DROP POLICY IF EXISTS phys_counts_write  ON physical_counts;
CREATE POLICY phys_counts_read  ON physical_counts FOR SELECT USING (
  factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active')
);
CREATE POLICY phys_counts_write ON physical_counts FOR ALL USING (
  factory_id IN (SELECT workspace_id FROM workspace_members WHERE user_id = auth.uid() AND status = 'active'
    AND role IN ('Admin', 'owner', 'Store'))
);
GRANT SELECT, INSERT, UPDATE ON physical_counts TO authenticated;

-- ── Seed default shifts for existing factories ────────────────────────────────
INSERT INTO shifts (factory_id, name, start_time, end_time)
SELECT f.id, s.name, s.start_time, s.end_time
FROM factories f
CROSS JOIN (VALUES
  ('A', '06:00', '14:00'),
  ('B', '14:00', '22:00'),
  ('C', '22:00', '06:00')
) AS s(name, start_time, end_time)
WHERE NOT EXISTS (
  SELECT 1 FROM shifts WHERE factory_id = f.id AND name = s.name
);

-- ── Seed default BP reject reasons ───────────────────────────────────────────
INSERT INTO bp_reject_reasons (factory_id, reason)
SELECT f.id, r.reason
FROM factories f
CROSS JOIN (VALUES
  ('Crack'), ('Dimension Out of Tolerance'), ('Bend Angle Error'),
  ('Surface Scratch'), ('Burr/Sharp Edge'), ('Deformation'), ('Incomplete Forming')
) AS r(reason)
WHERE NOT EXISTS (
  SELECT 1 FROM bp_reject_reasons WHERE factory_id = f.id
);

-- ── Seed default AP reject reasons ───────────────────────────────────────────
INSERT INTO ap_reject_reasons (factory_id, reason)
SELECT f.id, r.reason
FROM factories f
CROSS JOIN (VALUES
  ('Plating Peel-off'), ('Uneven Coating'), ('Rust/Corrosion Spot'),
  ('Discoloration'), ('Plating Thickness Out of Spec'), ('Handling Damage')
) AS r(reason)
WHERE NOT EXISTS (
  SELECT 1 FROM ap_reject_reasons WHERE factory_id = f.id
);

-- ── Seed default RTV reasons ──────────────────────────────────────────────────
INSERT INTO rtv_reasons (factory_id, reason)
SELECT f.id, r.reason
FROM factories f
CROSS JOIN (VALUES
  ('Plating Quality Reject'), ('Vendor Processing Delay'),
  ('Damaged in Transit'), ('Wrong Quantity Received')
) AS r(reason)
WHERE NOT EXISTS (
  SELECT 1 FROM rtv_reasons WHERE factory_id = f.id
);
