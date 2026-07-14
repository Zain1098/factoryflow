-- ============================================================
-- FactoryFlow Manufacturing ERP — Supabase Schema
-- PRD v2.4 — Chapter 5 (Database Design)
-- Run this entire script in Supabase SQL Editor
-- ============================================================

-- ─── Extensions ──────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ─── Master Tables ────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS factories (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  address TEXT,
  timezone TEXT DEFAULT 'Asia/Karachi',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  phone TEXT,
  email TEXT,
  role TEXT NOT NULL CHECK (role IN ('Admin','Production Incharge','Store','Quality Inspector','Management')),
  active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS operators (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS parts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  uom TEXT DEFAULT 'PCS',
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS machines (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  sequence_order INTEGER NOT NULL,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS suppliers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  contact TEXT,
  address TEXT,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS vendors (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  contact TEXT,
  address TEXT,
  vendor_type TEXT,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS customers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  contact TEXT,
  address TEXT,
  is_default BOOLEAN DEFAULT FALSE,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS vehicles (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  number_plate TEXT NOT NULL,
  type TEXT,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS drivers (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  license_number TEXT,
  phone TEXT,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS target_master (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  part_id UUID NOT NULL REFERENCES parts(id),
  day_of_week INTEGER NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  target_qty INTEGER NOT NULL,
  effective_from DATE NOT NULL,
  effective_to DATE
);

-- ─── Transaction Tables ───────────────────────────────────────

CREATE TABLE IF NOT EXISTS material_receives (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  date DATE NOT NULL,
  time TIME,
  supplier_id UUID REFERENCES suppliers(id),
  po_id TEXT,
  part_id UUID NOT NULL REFERENCES parts(id),
  qty NUMERIC NOT NULL CHECK (qty > 0),
  remarks TEXT,
  created_by UUID REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS productions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  batch_number TEXT NOT NULL,
  date DATE NOT NULL,
  time TIME,
  shift_id TEXT,
  part_id UUID NOT NULL REFERENCES parts(id),
  machine_id UUID NOT NULL REFERENCES machines(id),
  operator_id UUID REFERENCES operators(id),
  machine_status_id TEXT,
  production_qty NUMERIC NOT NULL CHECK (production_qty >= 0),
  bp_reject_qty NUMERIC DEFAULT 0 CHECK (bp_reject_qty >= 0),
  good_qty NUMERIC GENERATED ALWAYS AS (production_qty - bp_reject_qty) STORED,
  remarks TEXT,
  created_by UUID REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT bp_reject_lte_production CHECK (bp_reject_qty <= production_qty)
);

CREATE TABLE IF NOT EXISTS machine_downtimes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  machine_id UUID NOT NULL REFERENCES machines(id),
  date DATE NOT NULL,
  start_time TIME NOT NULL,
  end_time TIME,
  duration_minutes INTEGER,
  reason TEXT NOT NULL,
  operator_id UUID REFERENCES operators(id),
  photo_url TEXT,
  remarks TEXT,
  created_by UUID REFERENCES users(id),
  CONSTRAINT end_after_start CHECK (end_time IS NULL OR end_time > start_time)
);

CREATE TABLE IF NOT EXISTS bp_inspections (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  batch_number TEXT NOT NULL,
  date DATE NOT NULL,
  part_id UUID NOT NULL REFERENCES parts(id),
  machine_id UUID REFERENCES machines(id),
  bp_reject_qty NUMERIC NOT NULL DEFAULT 0,
  reject_reason_id TEXT,
  inspector_id UUID REFERENCES users(id),
  photo_url TEXT,
  remarks TEXT
);

CREATE TABLE IF NOT EXISTS dispatch_to_facos (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  batch_number TEXT NOT NULL,
  date DATE NOT NULL,
  time TIME,
  part_id UUID NOT NULL REFERENCES parts(id),
  qty NUMERIC NOT NULL CHECK (qty > 0),
  vendor_id UUID NOT NULL REFERENCES vendors(id),
  vehicle_id UUID REFERENCES vehicles(id),
  driver_id UUID REFERENCES drivers(id),
  challan_number TEXT,
  remarks TEXT,
  created_by UUID REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS receive_from_facos (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  batch_number TEXT NOT NULL,
  date DATE NOT NULL,
  part_id UUID NOT NULL REFERENCES parts(id),
  qty_received NUMERIC NOT NULL CHECK (qty_received > 0),
  dispatch_ref_id UUID REFERENCES dispatch_to_facos(id),
  supplier_challan TEXT,
  shortage_flag BOOLEAN DEFAULT FALSE,
  remarks TEXT,
  created_by UUID REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS ap_inspections (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  batch_number TEXT NOT NULL,
  date DATE NOT NULL,
  part_id UUID NOT NULL REFERENCES parts(id),
  qty_checked NUMERIC NOT NULL CHECK (qty_checked > 0),
  approved_qty NUMERIC NOT NULL DEFAULT 0,
  rejected_qty NUMERIC NOT NULL DEFAULT 0,
  reject_reason_id TEXT,
  inspector_id UUID REFERENCES users(id),
  photo_url TEXT,
  remarks TEXT,
  CONSTRAINT ap_split_check CHECK (approved_qty + rejected_qty = qty_checked)
);

CREATE TABLE IF NOT EXISTS rtvs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  batch_number TEXT NOT NULL,
  cycle_number INTEGER NOT NULL DEFAULT 1 CHECK (cycle_number BETWEEN 1 AND 3),
  date DATE NOT NULL,
  part_id UUID NOT NULL REFERENCES parts(id),
  rtv_qty NUMERIC NOT NULL CHECK (rtv_qty > 0),
  reason_id TEXT,
  vendor_id UUID REFERENCES vendors(id),
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending','sent','received','escalated')),
  expected_return_date DATE,
  actual_return_date DATE,
  photo_url TEXT,
  remarks TEXT
);

CREATE TABLE IF NOT EXISTS rtv_reinspections (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  rtv_id UUID NOT NULL REFERENCES rtvs(id),
  date DATE NOT NULL,
  quantity_received NUMERIC NOT NULL,
  ok_qty NUMERIC NOT NULL DEFAULT 0,
  reject_again_qty NUMERIC NOT NULL DEFAULT 0,
  next_action TEXT,
  remarks TEXT,
  CONSTRAINT rtv_reinspect_split CHECK (ok_qty + reject_again_qty = quantity_received)
);

CREATE TABLE IF NOT EXISTS final_dispatches (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  batch_number TEXT NOT NULL,
  date DATE NOT NULL,
  part_id UUID NOT NULL REFERENCES parts(id),
  customer_id UUID NOT NULL REFERENCES customers(id),
  dispatch_qty NUMERIC NOT NULL CHECK (dispatch_qty > 0),
  vehicle_id UUID REFERENCES vehicles(id),
  driver_id UUID REFERENCES drivers(id),
  challan_number TEXT,
  photo_url TEXT,
  remarks TEXT,
  created_by UUID REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS stock_ledger (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  date DATE NOT NULL,
  time TIME,
  part_id UUID NOT NULL REFERENCES parts(id),
  stage TEXT NOT NULL CHECK (stage IN ('raw_material','bp_stock','at_faco','pending_ap','approved_ap','rtv_stock')),
  direction TEXT NOT NULL CHECK (direction IN ('IN','OUT')),
  qty NUMERIC NOT NULL CHECK (qty > 0),
  ref_table TEXT NOT NULL,
  ref_id UUID NOT NULL,
  running_balance NUMERIC NOT NULL CHECK (running_balance >= 0),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS correction_requests (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  table_name TEXT NOT NULL,
  record_id UUID NOT NULL,
  requested_by UUID REFERENCES users(id),
  requested_at TIMESTAMPTZ DEFAULT NOW(),
  reason TEXT NOT NULL,
  old_value_json JSONB,
  proposed_value_json JSONB,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  reviewed_by UUID REFERENCES users(id),
  reviewed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS audit_log (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  table_name TEXT NOT NULL,
  record_id UUID NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
  old_value_json JSONB,
  new_value_json JSONB,
  changed_by UUID REFERENCES users(id),
  changed_at TIMESTAMPTZ DEFAULT NOW(),
  device TEXT
);

CREATE TABLE IF NOT EXISTS backup_records (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  user_id UUID REFERENCES users(id),
  source_table TEXT NOT NULL,
  source_record_id TEXT NOT NULL,
  data_json JSONB NOT NULL,
  backup_reason TEXT,
  backed_up_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sync_status TEXT DEFAULT 'pending'
);

-- ─── Indexes ──────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_ledger_part_stage ON stock_ledger(part_id, stage);
CREATE INDEX IF NOT EXISTS idx_ledger_date ON stock_ledger(date);
CREATE INDEX IF NOT EXISTS idx_ledger_factory ON stock_ledger(factory_id);
CREATE INDEX IF NOT EXISTS idx_batch_productions ON productions(batch_number);
CREATE INDEX IF NOT EXISTS idx_productions_date ON productions(date);
CREATE INDEX IF NOT EXISTS idx_productions_factory ON productions(factory_id);
CREATE INDEX IF NOT EXISTS idx_material_receives_date ON material_receives(date);
CREATE INDEX IF NOT EXISTS idx_final_dispatches_date ON final_dispatches(date);
CREATE INDEX IF NOT EXISTS idx_backup_records_user ON backup_records(user_id);
CREATE INDEX IF NOT EXISTS idx_backup_records_table ON backup_records(source_table);
CREATE INDEX IF NOT EXISTS idx_backup_records_at ON backup_records(backed_up_at);

-- ─── Row Level Security ───────────────────────────────────────
ALTER TABLE factories ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE operators ENABLE ROW LEVEL SECURITY;
ALTER TABLE parts ENABLE ROW LEVEL SECURITY;
ALTER TABLE machines ENABLE ROW LEVEL SECURITY;
ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendors ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE drivers ENABLE ROW LEVEL SECURITY;
ALTER TABLE target_master ENABLE ROW LEVEL SECURITY;
ALTER TABLE material_receives ENABLE ROW LEVEL SECURITY;
ALTER TABLE productions ENABLE ROW LEVEL SECURITY;
ALTER TABLE machine_downtimes ENABLE ROW LEVEL SECURITY;
ALTER TABLE bp_inspections ENABLE ROW LEVEL SECURITY;
ALTER TABLE dispatch_to_facos ENABLE ROW LEVEL SECURITY;
ALTER TABLE receive_from_facos ENABLE ROW LEVEL SECURITY;
ALTER TABLE ap_inspections ENABLE ROW LEVEL SECURITY;
ALTER TABLE rtvs ENABLE ROW LEVEL SECURITY;
ALTER TABLE rtv_reinspections ENABLE ROW LEVEL SECURITY;
ALTER TABLE final_dispatches ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE correction_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE backup_records ENABLE ROW LEVEL SECURITY;

-- Helper function: get current user's factory_id
CREATE OR REPLACE FUNCTION get_my_factory_id()
RETURNS UUID AS $$
  SELECT factory_id FROM users WHERE id = auth.uid();
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

-- Helper function: get current user's role
CREATE OR REPLACE FUNCTION get_my_role()
RETURNS TEXT AS $$
  SELECT role FROM users WHERE id = auth.uid();
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

-- RLS Policies — users can only see their own factory's data
-- Master tables: all authenticated users can read, only Admin can write

CREATE POLICY "factory_read" ON factories FOR SELECT USING (id = get_my_factory_id());

CREATE POLICY "users_read" ON users FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "users_write" ON users FOR ALL USING (get_my_role() = 'Admin');

CREATE POLICY "parts_read" ON parts FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "parts_write" ON parts FOR ALL USING (get_my_role() = 'Admin');

CREATE POLICY "machines_read" ON machines FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "machines_write" ON machines FOR ALL USING (get_my_role() = 'Admin');

CREATE POLICY "operators_read" ON operators FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "operators_write" ON operators FOR ALL USING (get_my_role() = 'Admin');

CREATE POLICY "suppliers_read" ON suppliers FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "suppliers_write" ON suppliers FOR ALL USING (get_my_role() = 'Admin');

CREATE POLICY "vendors_read" ON vendors FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "vendors_write" ON vendors FOR ALL USING (get_my_role() = 'Admin');

CREATE POLICY "customers_read" ON customers FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "customers_write" ON customers FOR ALL USING (get_my_role() = 'Admin');

CREATE POLICY "vehicles_read" ON vehicles FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "vehicles_write" ON vehicles FOR ALL USING (factory_id = get_my_factory_id() AND get_my_role() IN ('Admin','Store'));

CREATE POLICY "drivers_read" ON drivers FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "drivers_write" ON drivers FOR ALL USING (factory_id = get_my_factory_id() AND get_my_role() IN ('Admin','Store'));

CREATE POLICY "target_read" ON target_master FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "target_write" ON target_master FOR ALL USING (get_my_role() = 'Admin');

-- Transaction tables: read all in factory, write based on role
CREATE POLICY "material_receives_read" ON material_receives FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "material_receives_write" ON material_receives FOR INSERT WITH CHECK (factory_id = get_my_factory_id() AND get_my_role() IN ('Admin','Store'));

CREATE POLICY "productions_read" ON productions FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "productions_write" ON productions FOR INSERT WITH CHECK (factory_id = get_my_factory_id() AND get_my_role() IN ('Admin','Production Incharge'));

CREATE POLICY "machine_downtimes_read" ON machine_downtimes FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "machine_downtimes_write" ON machine_downtimes FOR INSERT WITH CHECK (factory_id = get_my_factory_id() AND get_my_role() IN ('Admin','Production Incharge'));

CREATE POLICY "bp_inspections_read" ON bp_inspections FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "bp_inspections_write" ON bp_inspections FOR INSERT WITH CHECK (factory_id = get_my_factory_id() AND get_my_role() IN ('Admin','Quality Inspector'));

CREATE POLICY "dispatch_to_facos_read" ON dispatch_to_facos FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "dispatch_to_facos_write" ON dispatch_to_facos FOR INSERT WITH CHECK (factory_id = get_my_factory_id() AND get_my_role() IN ('Admin','Store'));

CREATE POLICY "receive_from_facos_read" ON receive_from_facos FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "receive_from_facos_write" ON receive_from_facos FOR INSERT WITH CHECK (factory_id = get_my_factory_id() AND get_my_role() IN ('Admin','Store'));

CREATE POLICY "ap_inspections_read" ON ap_inspections FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "ap_inspections_write" ON ap_inspections FOR INSERT WITH CHECK (factory_id = get_my_factory_id() AND get_my_role() IN ('Admin','Quality Inspector'));

CREATE POLICY "rtvs_read" ON rtvs FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "rtvs_write" ON rtvs FOR INSERT WITH CHECK (factory_id = get_my_factory_id() AND get_my_role() IN ('Admin','Store','Quality Inspector'));

CREATE POLICY "rtv_reinspections_read" ON rtv_reinspections FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "rtv_reinspections_write" ON rtv_reinspections FOR INSERT WITH CHECK (factory_id = get_my_factory_id() AND get_my_role() IN ('Admin','Quality Inspector'));

CREATE POLICY "final_dispatches_read" ON final_dispatches FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "final_dispatches_write" ON final_dispatches FOR INSERT WITH CHECK (factory_id = get_my_factory_id() AND get_my_role() IN ('Admin','Store'));

CREATE POLICY "stock_ledger_read" ON stock_ledger FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "stock_ledger_write" ON stock_ledger FOR INSERT WITH CHECK (factory_id = get_my_factory_id());

CREATE POLICY "correction_requests_read" ON correction_requests FOR SELECT USING (factory_id = get_my_factory_id());
CREATE POLICY "correction_requests_write" ON correction_requests FOR ALL USING (factory_id = get_my_factory_id());

CREATE POLICY "audit_log_read" ON audit_log FOR SELECT USING (factory_id = get_my_factory_id() AND get_my_role() = 'Admin');
CREATE POLICY "audit_log_write" ON audit_log FOR INSERT WITH CHECK (factory_id = get_my_factory_id());

CREATE POLICY "backup_records_admin_read" ON backup_records FOR SELECT
  USING (factory_id = get_my_factory_id() AND get_my_role() = 'Admin');
CREATE POLICY "backup_records_insert_own" ON backup_records FOR INSERT
  WITH CHECK (factory_id = get_my_factory_id() AND user_id = auth.uid());
CREATE POLICY "backup_records_update_own_sync" ON backup_records FOR UPDATE
  USING (factory_id = get_my_factory_id() AND user_id = auth.uid())
  WITH CHECK (factory_id = get_my_factory_id() AND user_id = auth.uid());

CREATE OR REPLACE FUNCTION request_account_deletion(p_user_id UUID)
RETURNS VOID AS $$
BEGIN
  IF auth.uid() IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  UPDATE users
  SET active = FALSE
  WHERE id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE ALL ON FUNCTION request_account_deletion(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION request_account_deletion(UUID) TO authenticated;

-- ─── Seed Data ────────────────────────────────────────────────
-- Step 1: Insert factory
INSERT INTO factories (id, name, address, timezone)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'FactoryFlow Plant 1',
  'Pakistan',
  'Asia/Karachi'
) ON CONFLICT (id) DO NOTHING;

-- Step 2: Insert master data
INSERT INTO machines (id, factory_id, name, sequence_order) VALUES
  ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', 'Bending', 1),
  ('00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000001', 'Notching', 2),
  ('00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000001', 'End Forming', 3)
ON CONFLICT (id) DO NOTHING;

INSERT INTO parts (id, factory_id, code, name, uom) VALUES
  ('00000000-0000-0000-0000-000000000020', '00000000-0000-0000-0000-000000000001', 'V21', 'Part V21', 'PCS'),
  ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000001', 'V22', 'Part V22', 'PCS')
ON CONFLICT (id) DO NOTHING;

INSERT INTO suppliers (id, factory_id, name) VALUES
  ('00000000-0000-0000-0000-000000000030', '00000000-0000-0000-0000-000000000001', 'Steel Supplier')
ON CONFLICT (id) DO NOTHING;

INSERT INTO vendors (id, factory_id, name, vendor_type) VALUES
  ('00000000-0000-0000-0000-000000000040', '00000000-0000-0000-0000-000000000001', 'Faco', 'plating')
ON CONFLICT (id) DO NOTHING;

INSERT INTO customers (id, factory_id, name, is_default) VALUES
  ('00000000-0000-0000-0000-000000000050', '00000000-0000-0000-0000-000000000001', 'Thal', TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO operators (id, factory_id, name) VALUES
  ('00000000-0000-0000-0000-000000000060', '00000000-0000-0000-0000-000000000001', 'Operator 1'),
  ('00000000-0000-0000-0000-000000000061', '00000000-0000-0000-0000-000000000001', 'Operator 2')
ON CONFLICT (id) DO NOTHING;

-- Target: 400 PCS per day for V21 (all days Mon-Sat)
INSERT INTO target_master (factory_id, part_id, day_of_week, target_qty, effective_from) VALUES
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000020', 1, 400, '2025-01-01'),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000020', 2, 400, '2025-01-01'),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000020', 3, 400, '2025-01-01'),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000020', 4, 400, '2025-01-01'),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000020', 5, 400, '2025-01-01'),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000020', 6, 400, '2025-01-01')
ON CONFLICT DO NOTHING;

-- ─── IMPORTANT: After running this script ─────────────────────
-- Create your first Admin user:
-- 1. Supabase Dashboard → Authentication → Users → Add User
-- 2. Enter email + password
-- 3. Copy the generated UUID
-- 4. Run this INSERT (replace YOUR_UUID and YOUR_EMAIL):
--
-- INSERT INTO users (id, factory_id, name, email, role)
-- VALUES (
--   'YOUR_UUID_FROM_AUTH',
--   '00000000-0000-0000-0000-000000000001',
--   'Admin User',
--   'YOUR_EMAIL',
--   'Admin'
-- );
-- ─────────────────────────────────────────────────────────────
