-- ============================================================`n-- FactoryFlow: Full Schema + All Migrations (consolidated)`n-- Paste this entire file into Supabase SQL Editor and Run`n-- ============================================================`n`n-- ============================================================
-- FactoryFlow Manufacturing ERP â€” Supabase Schema
-- PRD v2.4 â€” Chapter 5 (Database Design)
-- Run this entire script in Supabase SQL Editor
-- ============================================================

-- â”€â”€â”€ Extensions â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- gen_random_uuid() is built into PostgreSQL 13+ (no extension needed).
-- uuid-ossp kept as optional fallback only.
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- â”€â”€â”€ Master Tables â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

CREATE TABLE IF NOT EXISTS factories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS parts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  uom TEXT DEFAULT 'PCS',
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS machines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  sequence_order INTEGER NOT NULL,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS suppliers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  contact TEXT,
  address TEXT,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS vendors (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  contact TEXT,
  address TEXT,
  vendor_type TEXT,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  contact TEXT,
  address TEXT,
  is_default BOOLEAN DEFAULT FALSE,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS vehicles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  number_plate TEXT NOT NULL,
  type TEXT,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS drivers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  name TEXT NOT NULL,
  license_number TEXT,
  phone TEXT,
  active BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS target_master (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  part_id UUID NOT NULL REFERENCES parts(id),
  day_of_week INTEGER NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  target_qty INTEGER NOT NULL,
  effective_from DATE NOT NULL,
  effective_to DATE
);

-- â”€â”€â”€ Transaction Tables â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

CREATE TABLE IF NOT EXISTS material_receives (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id UUID NOT NULL REFERENCES factories(id),
  user_id UUID REFERENCES users(id),
  source_table TEXT NOT NULL,
  source_record_id TEXT NOT NULL,
  data_json JSONB NOT NULL,
  backup_reason TEXT,
  backed_up_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sync_status TEXT DEFAULT 'pending'
);

-- â”€â”€â”€ Indexes â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

-- â”€â”€â”€ Row Level Security â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

-- RLS Policies â€” users can only see their own factory's data
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

-- â”€â”€â”€ Seed Data â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

-- â”€â”€â”€ IMPORTANT: After running this script â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Create your first Admin user:
-- 1. Supabase Dashboard â†’ Authentication â†’ Users â†’ Add User
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
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€


-- Phase 1: apply after the baseline supabase_schema.sql on every existing
-- Supabase project. This migration is additive except for replacing unsafe
-- write policies with equivalent factory-scoped policies.

CREATE OR REPLACE FUNCTION public.get_my_factory_id()
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT factory_id FROM public.users WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT role FROM public.users WHERE id = auth.uid();
$$;

CREATE TABLE IF NOT EXISTS public.backup_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  factory_id uuid NOT NULL REFERENCES public.factories(id),
  user_id uuid REFERENCES public.users(id),
  source_table text NOT NULL,
  source_record_id text NOT NULL,
  data_json jsonb NOT NULL,
  backup_reason text,
  backed_up_at timestamptz NOT NULL DEFAULT now(),
  sync_status text DEFAULT 'pending'
);

CREATE INDEX IF NOT EXISTS idx_backup_records_user ON public.backup_records(user_id);
CREATE INDEX IF NOT EXISTS idx_backup_records_table ON public.backup_records(source_table);
CREATE INDEX IF NOT EXISTS idx_backup_records_at ON public.backup_records(backed_up_at);

ALTER TABLE public.backup_records ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_write" ON public.users;
DROP POLICY IF EXISTS "parts_write" ON public.parts;
DROP POLICY IF EXISTS "machines_write" ON public.machines;
DROP POLICY IF EXISTS "operators_write" ON public.operators;
DROP POLICY IF EXISTS "suppliers_write" ON public.suppliers;
DROP POLICY IF EXISTS "vendors_write" ON public.vendors;
DROP POLICY IF EXISTS "customers_write" ON public.customers;
DROP POLICY IF EXISTS "vehicles_write" ON public.vehicles;
DROP POLICY IF EXISTS "drivers_write" ON public.drivers;
DROP POLICY IF EXISTS "target_write" ON public.target_master;
DROP POLICY IF EXISTS "stock_ledger_write" ON public.stock_ledger;
DROP POLICY IF EXISTS "backup_records_admin_read" ON public.backup_records;
DROP POLICY IF EXISTS "backup_records_insert_own" ON public.backup_records;
DROP POLICY IF EXISTS "backup_records_update_own_sync" ON public.backup_records;

CREATE POLICY "users_write" ON public.users FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "parts_write" ON public.parts FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "machines_write" ON public.machines FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "operators_write" ON public.operators FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "suppliers_write" ON public.suppliers FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "vendors_write" ON public.vendors FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "customers_write" ON public.customers FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "vehicles_write" ON public.vehicles FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() IN ('Admin', 'Store'))
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() IN ('Admin', 'Store'));
CREATE POLICY "drivers_write" ON public.drivers FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() IN ('Admin', 'Store'))
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() IN ('Admin', 'Store'));
CREATE POLICY "target_write" ON public.target_master FOR ALL
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin')
  WITH CHECK (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "backup_records_admin_read" ON public.backup_records FOR SELECT
  USING (factory_id = public.get_my_factory_id() AND public.get_my_role() = 'Admin');
CREATE POLICY "backup_records_insert_own" ON public.backup_records FOR INSERT
  WITH CHECK (factory_id = public.get_my_factory_id() AND user_id = auth.uid());
CREATE POLICY "backup_records_update_own_sync" ON public.backup_records FOR UPDATE
  USING (factory_id = public.get_my_factory_id() AND user_id = auth.uid())
  WITH CHECK (factory_id = public.get_my_factory_id() AND user_id = auth.uid());

CREATE OR REPLACE FUNCTION public.request_account_deletion(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  UPDATE public.users
  SET active = false
  WHERE id = p_user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.request_account_deletion(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_account_deletion(uuid) TO authenticated;

-- Ledger rows are append-only and may only be written through the function
-- below. The function serializes balance changes per factory/part/stage.
CREATE OR REPLACE FUNCTION public.write_stock_ledger_entry(
  p_id uuid,
  p_factory_id uuid,
  p_part_id uuid,
  p_stage text,
  p_direction text,
  p_qty numeric,
  p_ref_table text,
  p_ref_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_balance numeric := 0;
  next_balance numeric;
BEGIN
  IF auth.uid() IS NULL OR p_factory_id <> public.get_my_factory_id() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF public.get_my_role() NOT IN ('Admin', 'Production Incharge', 'Store', 'Quality Inspector') THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF p_qty <= 0 OR p_direction NOT IN ('IN', 'OUT') OR
      p_stage NOT IN ('raw_material', 'bp_stock', 'at_faco', 'pending_ap', 'approved_ap', 'rtv_stock') THEN
    RAISE EXCEPTION 'invalid ledger entry';
  END IF;
  IF EXISTS (SELECT 1 FROM public.stock_ledger WHERE stock_ledger.id = p_id) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_factory_id::text || p_part_id::text || p_stage, 0));
  SELECT running_balance INTO current_balance
  FROM public.stock_ledger
  WHERE stock_ledger.factory_id = p_factory_id
    AND stock_ledger.part_id = p_part_id
    AND stock_ledger.stage = p_stage
  ORDER BY created_at DESC
  LIMIT 1;
  current_balance := COALESCE(current_balance, 0);
  next_balance := CASE WHEN p_direction = 'IN' THEN current_balance + p_qty ELSE current_balance - p_qty END;
  IF next_balance < 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Insufficient stock for this movement');
  END IF;

  INSERT INTO public.stock_ledger (
    id, factory_id, date, time, part_id, stage, direction, qty,
    ref_table, ref_id, running_balance
  ) VALUES (
    p_id, p_factory_id, CURRENT_DATE, CURRENT_TIME, p_part_id, p_stage, p_direction, p_qty,
    p_ref_table, p_ref_id, next_balance
  );
  INSERT INTO public.audit_log (
    factory_id, table_name, record_id, action, old_value_json, new_value_json,
    changed_by, changed_at
  ) VALUES (
    p_factory_id, 'stock_ledger', p_id, 'INSERT', NULL,
    jsonb_build_object('part_id', p_part_id, 'stage', p_stage, 'direction', p_direction, 'qty', p_qty, 'running_balance', next_balance)::text,
    auth.uid(), NOW()
  );
  RETURN jsonb_build_object('success', true, 'running_balance', next_balance);
END;
$$;

REVOKE ALL ON FUNCTION public.write_stock_ledger_entry(uuid, uuid, uuid, text, text, numeric, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.write_stock_ledger_entry(uuid, uuid, uuid, text, text, numeric, text, uuid) TO authenticated;


-- Phase 2: workspace_members table + create_user_workspace RPC
-- Apply after 202607120001_phase1_security_and_ledger.sql

-- â”€â”€ workspace_members â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

CREATE TABLE IF NOT EXISTS public.workspace_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.factories(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'owner',
  status text NOT NULL DEFAULT 'active',
  joined_at timestamptz NOT NULL DEFAULT now(),
  sync_status text DEFAULT 'pending',
  UNIQUE(workspace_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_workspace_members_user ON public.workspace_members(user_id);
CREATE INDEX IF NOT EXISTS idx_workspace_members_workspace ON public.workspace_members(workspace_id);

ALTER TABLE public.workspace_members ENABLE ROW LEVEL SECURITY;

-- Members can read their own memberships
CREATE POLICY "workspace_members_read_own" ON public.workspace_members FOR SELECT
  USING (user_id = auth.uid());

-- Owner can insert/update members in their workspace
CREATE POLICY "workspace_members_owner_write" ON public.workspace_members FOR ALL
  USING (
    workspace_id IN (
      SELECT workspace_id FROM public.workspace_members
      WHERE user_id = auth.uid() AND role = 'owner' AND status = 'active'
    )
  )
  WITH CHECK (
    workspace_id IN (
      SELECT workspace_id FROM public.workspace_members
      WHERE user_id = auth.uid() AND role = 'owner' AND status = 'active'
    )
  );

-- â”€â”€ Helper: get all workspace IDs the current user is a member of â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

CREATE OR REPLACE FUNCTION public.get_my_workspace_ids()
RETURNS SETOF uuid
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT workspace_id FROM public.workspace_members
  WHERE user_id = auth.uid() AND status = 'active';
$$;

-- â”€â”€ Update data-table RLS to use workspace membership â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Replace the old single-factory read policies with membership-based ones.

-- parts
DROP POLICY IF EXISTS "parts_read" ON public.parts;
CREATE POLICY "parts_read" ON public.parts FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "parts_write" ON public.parts;
CREATE POLICY "parts_write" ON public.parts FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- machines
DROP POLICY IF EXISTS "machines_read" ON public.machines;
CREATE POLICY "machines_read" ON public.machines FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "machines_write" ON public.machines;
CREATE POLICY "machines_write" ON public.machines FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- operators
DROP POLICY IF EXISTS "operators_read" ON public.operators;
CREATE POLICY "operators_read" ON public.operators FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "operators_write" ON public.operators;
CREATE POLICY "operators_write" ON public.operators FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- suppliers
DROP POLICY IF EXISTS "suppliers_read" ON public.suppliers;
CREATE POLICY "suppliers_read" ON public.suppliers FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "suppliers_write" ON public.suppliers;
CREATE POLICY "suppliers_write" ON public.suppliers FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- vendors
DROP POLICY IF EXISTS "vendors_read" ON public.vendors;
CREATE POLICY "vendors_read" ON public.vendors FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "vendors_write" ON public.vendors;
CREATE POLICY "vendors_write" ON public.vendors FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- customers
DROP POLICY IF EXISTS "customers_read" ON public.customers;
CREATE POLICY "customers_read" ON public.customers FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "customers_write" ON public.customers;
CREATE POLICY "customers_write" ON public.customers FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- vehicles
DROP POLICY IF EXISTS "vehicles_read" ON public.vehicles;
CREATE POLICY "vehicles_read" ON public.vehicles FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "vehicles_write" ON public.vehicles;
CREATE POLICY "vehicles_write" ON public.vehicles FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- drivers
DROP POLICY IF EXISTS "drivers_read" ON public.drivers;
CREATE POLICY "drivers_read" ON public.drivers FOR SELECT
  USING (factory_id IN (SELECT public.get_my_workspace_ids()));

DROP POLICY IF EXISTS "drivers_write" ON public.drivers;
CREATE POLICY "drivers_write" ON public.drivers FOR ALL
  USING (factory_id IN (SELECT public.get_my_workspace_ids()))
  WITH CHECK (factory_id IN (SELECT public.get_my_workspace_ids()));

-- â”€â”€ create_user_workspace RPC â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Called right after Supabase Auth signup.
-- Creates: factories row, users row, workspace_members row.

CREATE OR REPLACE FUNCTION public.create_user_workspace(
  p_profile_name text,
  p_workspace_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_workspace_id uuid := gen_random_uuid();
  v_member_id uuid := gen_random_uuid();
  v_email text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  -- Get email from auth.users
  SELECT email INTO v_email FROM auth.users WHERE id = v_user_id;

  -- Create workspace (factories row)
  INSERT INTO public.factories (id, name, active)
  VALUES (v_workspace_id, p_workspace_name, true)
  ON CONFLICT (id) DO NOTHING;

  -- Create user profile
  INSERT INTO public.users (id, factory_id, name, email, role, active)
  VALUES (v_user_id, v_workspace_id, p_profile_name, v_email, 'owner', true)
  ON CONFLICT (id) DO UPDATE
    SET factory_id = v_workspace_id, name = p_profile_name;

  -- Create workspace membership
  INSERT INTO public.workspace_members (id, workspace_id, user_id, role, status)
  VALUES (v_member_id, v_workspace_id, v_user_id, 'owner', 'active')
  ON CONFLICT (workspace_id, user_id) DO NOTHING;

  RETURN jsonb_build_object(
    'workspace_id', v_workspace_id,
    'user_id', v_user_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_user_workspace(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_user_workspace(text, text) TO authenticated;


-- Phase 3: avatar_url, OTP verification, Google auth support
-- Apply after 202607130001_workspace_signup.sql

-- â”€â”€ Add avatar_url to users table â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
ALTER TABLE IF EXISTS public.users ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- â”€â”€ OTP verification codes table â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
CREATE TABLE IF NOT EXISTS public.otp_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  purpose TEXT NOT NULL CHECK (purpose IN ('email_change', 'password_change')),
  new_value TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  used BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_otp_codes_user ON public.otp_codes(user_id);
CREATE INDEX IF NOT EXISTS idx_otp_codes_expires ON public.otp_codes(expires_at);

ALTER TABLE public.otp_codes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "otp_codes_read_own" ON public.otp_codes FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "otp_codes_insert_own" ON public.otp_codes FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "otp_codes_update_own" ON public.otp_codes FOR UPDATE
  USING (user_id = auth.uid());

-- â”€â”€ RPC: Generate OTP â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
CREATE OR REPLACE FUNCTION public.generate_otp(
  p_user_id UUID,
  p_purpose TEXT,
  p_new_value TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code TEXT;
BEGIN
  -- 6-digit code
  v_code := LPAD(CAST(FLOOR(RANDOM() * 1000000) AS INTEGER)::TEXT, 6, '0');

  INSERT INTO public.otp_codes (user_id, code, purpose, new_value, expires_at)
  VALUES (p_user_id, v_code, p_purpose, p_new_value, NOW() + INTERVAL '10 minutes');

  RETURN v_code;
END;
$$;

REVOKE ALL ON FUNCTION public.generate_otp(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_otp(UUID, TEXT, TEXT) TO authenticated;

-- â”€â”€ RPC: Verify OTP â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
CREATE OR REPLACE FUNCTION public.verify_otp(
  p_user_id UUID,
  p_code TEXT,
  p_purpose TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_otp RECORD;
BEGIN
  SELECT * INTO v_otp FROM public.otp_codes
  WHERE user_id = p_user_id
    AND code = p_code
    AND purpose = p_purpose
    AND used = FALSE
    AND expires_at > NOW()
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_otp.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Invalid or expired OTP');
  END IF;

  UPDATE public.otp_codes SET used = TRUE WHERE id = v_otp.id;

  RETURN jsonb_build_object('success', TRUE, 'new_value', v_otp.new_value);
END;
$$;

REVOKE ALL ON FUNCTION public.verify_otp(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_otp(UUID, TEXT, TEXT) TO authenticated;

-- â”€â”€ RPC: Update user profile (name + avatar_url) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
CREATE OR REPLACE FUNCTION public.update_user_profile(
  p_user_id UUID,
  p_name TEXT DEFAULT NULL,
  p_avatar_url TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users
  SET
    name = COALESCE(p_name, name),
    avatar_url = COALESCE(p_avatar_url, avatar_url)
  WHERE id = p_user_id AND id = auth.uid();

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.update_user_profile(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_user_profile(UUID, TEXT, TEXT) TO authenticated;

-- â”€â”€ RPC: Update user email (after OTP verified) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
CREATE OR REPLACE FUNCTION public.update_user_email_after_otp(
  p_user_id UUID,
  p_new_email TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Update email in public.users
  UPDATE public.users
  SET email = p_new_email
  WHERE id = p_user_id AND id = auth.uid();

  -- Update email in auth.users via the auth API
  -- (this requires service_role key, so we call a separate function)

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.update_user_email_after_otp(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_user_email_after_otp(UUID, TEXT) TO authenticated;

-- â”€â”€ RPC: Update auth email (service_role only) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
CREATE OR REPLACE FUNCTION public.admin_update_user_email(
  p_user_id UUID,
  p_new_email TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only service_role can call this
  IF current_setting('role') != 'service_role' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Service role required');
  END IF;

  UPDATE auth.users
  SET email = p_new_email
  WHERE id = p_user_id;

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_update_user_email(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_user_email(UUID, TEXT) TO service_role;

-- â”€â”€ RPC: Handle Google OAuth user creation/login â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
CREATE OR REPLACE FUNCTION public.handle_google_auth_user(
  p_user_id UUID,
  p_email TEXT,
  p_name TEXT,
  p_avatar_url TEXT,
  p_workspace_name TEXT DEFAULT 'My Workspace'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_workspace_id UUID;
  v_existing_user RECORD;
BEGIN
  -- Check if user exists already
  SELECT * INTO v_existing_user FROM public.users WHERE id = p_user_id;

  IF v_existing_user.id IS NOT NULL THEN
    -- User exists â€” update profile from Google
    UPDATE public.users
    SET
      name = COALESCE(p_name, name),
      email = p_email,
      avatar_url = COALESCE(p_avatar_url, avatar_url)
    WHERE id = p_user_id;

    RETURN jsonb_build_object(
      'is_new', FALSE,
      'workspace_id', v_existing_user.factory_id
    );
  ELSE
    -- New user â€” create workspace and profile
    v_workspace_id := gen_random_uuid();

    INSERT INTO public.factories (id, name, active)
    VALUES (v_workspace_id, p_workspace_name, TRUE);

    INSERT INTO public.users (id, factory_id, name, email, role, active, avatar_url)
    VALUES (p_user_id, v_workspace_id, p_name, p_email, 'owner', TRUE, p_avatar_url);

    INSERT INTO public.workspace_members (id, workspace_id, user_id, role, status)
    VALUES (gen_random_uuid(), v_workspace_id, p_user_id, 'owner', 'active');

    RETURN jsonb_build_object(
      'is_new', TRUE,
      'workspace_id', v_workspace_id
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_google_auth_user(UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.handle_google_auth_user(UUID, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- â”€â”€ Grant usage for net extension if available â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Uncomment if supabase_http extension is installed for sending emails:
-- GRANT USAGE ON SCHEMA net TO service_role;
-- GRANT EXECUTE ON FUNCTION net.http_post TO service_role;


-- Phase 4: Schema fixes â€” role constraint, active column, machine_code, stock_adjustments
-- Apply after 202607140001_auth_avatar_otp.sql

-- â”€â”€ Fix users role constraint to allow 'owner' â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE public.users ADD CONSTRAINT users_role_check
  CHECK (role IN ('owner', 'Admin', 'Production Incharge', 'Store', 'Quality Inspector', 'Viewer'));

-- â”€â”€ Add active column to factories if missing â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
ALTER TABLE public.factories ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT TRUE;

-- â”€â”€ Add machine_code to machines if missing â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
ALTER TABLE public.machines ADD COLUMN IF NOT EXISTS machine_code TEXT;

-- â”€â”€ stock_adjustments table â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

