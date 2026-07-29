# FactoryFlow — Manufacturing ERP / Production Management System
## Product Requirements Document — v2.4 (Android Mobile App)

**Document purpose:** Written to be handed to any AI coding assistant or human developer with zero additional context, resulting in a correct implementation without guesswork. Every module defines happy path, edge cases, validation rules, and permissions.

### Version History
| Version | Changes |
|---|---|
| v1.0 | Initial PRD — web app scope, core modules, database design, stock ledger, batch traceability |
| v2.0 | Platform pivot: web app → Android (Flutter + Supabase). Roles restructured (Operator removed as login role). Photo attachments, expanded reports/KPIs, correction-request workflow, RTV-vs-AP-reject validation added |
| v2.1 | Added: consolidated Business Rules, Error Handling matrix, Security, Performance Requirements, Data Relationships (with corrected cardinalities), UX Rules (calibrated), Success Criteria, Development Phases |
| v2.2 | Added: AI Implementation Instructions (Chapter 16) — expert-review framing, wireframe/ER/API deliverable phases, mandatory final architecture review before coding |
| v2.3 | All 9 Chapter 15 open questions resolved and locked (see 15.1). No blockers remain before Phase 1 starts. |
| v2.4 | Vehicle, Driver, and Challan Number made optional (nullable) on Dispatch to Faco and Final Dispatch — no forced entry that would block or corrupt fast data entry. Vehicle/Driver support inline "add new" from the entry form instead of requiring a pre-seeded list. Clarified that only Vendor, Customer, and Supplier records (not Vehicle/Driver) are true prerequisites, and none of this blocks starting Phase 1. |

---

## Table of Contents
1. Product Overview
2. User Roles & Permissions
3. Factory Workflow
4. Functional Requirements
5. Database Design
6. Data Relationships
7. Business Rules
8. Error Handling
9. UI/UX Requirements
10. Technical Architecture (incl. Security, Performance)
11. Configurability & Multi-Tenancy Scope
12. Success Criteria
13. Development Strategy (Phases)
14. Future Roadmap
15. Open Questions
16. AI Implementation Instructions

---

## 1. Product Overview

### 1.1 Vision
This project is not a simple inventory application. It is a **production management and manufacturing ERP system** focused on minimizing manual work, maximizing automation, maintaining complete traceability, and providing real-time production visibility.

### 1.2 Problem Statement
A manufacturing plant currently tracks production, quality inspection, plating vendor dispatch/receive, rejection, RTV, and final dispatch manually. This causes: no real-time stock visibility, no traceability of defective batches, manual and error-prone stock calculations, and no historical reporting for decision-making.

### 1.3 Goals
- Eliminate manual stock calculation — all stock derived automatically from transactions.
- Give the Production Incharge a mobile-first tool to complete all daily entries in under 5 minutes.
- Provide real-time dashboard visibility of stock at every stage of the pipeline.
- Provide full batch-level traceability from raw material to final dispatch.
- Keep reference data (parts, machines, vendors, customers) as configurable master data — not hardcoded (see Chapter 11 for exact scope of "configurable").

### 1.4 Scope (Phase 1)
In scope: Material receive, production (3 machines), machine downtime, BP inspection, Faco (plating vendor) dispatch/receive, AP inspection, RTV cycle, final dispatch, dashboard, reports, global search, notifications, audit log with correction/approval workflow, photo attachments, offline-first sync.

Out of scope: active QR/barcode scanning (architecture will support it), iOS build, web dashboard, dynamic business-rule/workflow engine, multi-factory config UI.

### 1.5 Users
Admin, Production Incharge, Store, Quality Inspector, Management (Read Only). See Chapter 2.

---

## 2. User Roles & Permissions

| Role | Description | Key Permissions |
|---|---|---|
| **Admin** | Full system owner | Full CRUD on all masters and transactions, user management, approve correction requests, view audit log, configure targets, resolve RTV escalations |
| **Production Incharge** | Runs daily floor operations, logs production for all machines/operators | Create/edit same-day entries across all transaction modules, view dashboard, view reports, cannot delete after day-lock, cannot edit master data |
| **Store** | Manages physical material movement | Create Material Receive, Dispatch to Faco, Receive from Faco, Final Dispatch entries; view current stock |
| **Quality Inspector** | BP/AP inspection, RTV re-inspection | Create BP Inspection, AP Inspection, RTV, RTV Re-inspection entries; attach photos for rejects |
| **Management** | Read-only oversight | View dashboard, all reports, monthly summaries; no create/edit/delete anywhere |

**Note on Operators:** "Operator" is **not** a login role — it's a master-data dropdown selected on Production entries by whoever is logged in (typically Production Incharge). This still captures operator-wise reporting (4.12) without issuing individual accounts to machine operators.

**Permission rules:**
- Same-day edits: direct, by the creating role, audit-logged. After rollover: requires a Correction Request approved by Admin (7, 8).
- Only Admin can delete records, and only via soft-delete (never a hard delete — see Chapter 7).
- Only Admin manages master data (Parts, Machines, Vendors, Customers, Reasons, Targets).

---

## 3. Factory Workflow

### 3.1 Happy Path
```
Raw Material Receive
    → Production (Bending → Notching → End Forming)
    → BP Inspection (before plating)
    → Dispatch to Faco (plating vendor)
    → Receive from Faco
    → AP Inspection (after plating)
    → [OK] → Final Dispatch to Customer (default: Thal)
    → [Rejected] → RTV → Receive RTV Back → Re-Inspection
                        → [OK] → Final Dispatch
                        → [Reject Again] → RTV again (see 3.3 for cap)
```

### 3.2 Machine Sequence & WIP
Bending → Notching → End Forming. Each machine's output is the next machine's input. Every Production entry references its machine stage and the upstream batch/quantity it consumes, so WIP-in-transit is never silently lost or double-counted.

### 3.3 RTV Cycle Cap
After 3 RTV cycles on the same batch, status auto-flags "Escalated — Awaiting Admin Decision" and blocks further auto-RTV. Admin resolves to Scrap or Force Dispatch (override reason logged).

### 3.4 RTV Cannot Exceed AP Reject
Cumulative RTV quantity against a batch must never exceed that batch's `AP_Inspection.rejected_qty`.

### 3.5 Multi-Variant Day
All production, dashboard, and target logic is per-part-per-day — never assumes a single active part for the day.

### 3.6 Missing Machine / Partial Day
A day may have 1, 2, or 3 active machines. The system never requires all 3 before saving a day's data.

### 3.7 Faco Shortage
`Receive_From_Faco.qty_received` may be less than the linked dispatch quantity — allowed, flagged, reported.

---

## 4. Functional Requirements

Each module: **Fields → Happy Path → Edge Cases → Validation → Permissions**.

### 4.1 Material Receive
**Fields:** id, date, time, supplier, po_number (nullable), part, quantity, remarks, created_by.
**Validation:** Quantity > 0. Warn (not block) if cumulative received > PO ordered qty.
**Permissions:** Store, Admin.

### 4.2 Production
**Fields:** id, batch_number (auto), date, time, shift, part, machine, operator, machine_status, production_qty, bp_reject_qty, good_qty (computed), remarks, created_by.
**Edge cases:** Machine breakdown mid-shift; zero-production entries allowed with a reason.
**Validation:** `bp_reject_qty ≤ production_qty`. `production_qty ≥ 0`.
**Permissions:** Production Incharge, Admin.

### 4.3 Machine Downtime
**Fields:** id, machine, date, start_time, end_time (nullable), duration (computed), reason, operator, photo_url, remarks, created_by.
**Validation:** `end_time > start_time` when present.
**Permissions:** Production Incharge, Admin.

### 4.4 BP Inspection
**Fields:** id, batch_number, date, part, machine, bp_reject_qty, reject_reason, inspector, photo_url, remarks.
> Distinct from `Production.bp_reject_qty` (operator self-reported scrap). This is the formal QC checkpoint on `good_qty` before it moves to Faco.
**Validation:** `bp_reject_qty ≤ quantity being inspected`.
**Permissions:** Quality Inspector.

### 4.5 Dispatch to Faco
**Fields:** id, batch_number, date, time, part, quantity, vendor (required), vehicle (optional), driver (optional), challan_number (optional), remarks, created_by.
**Validation:** `quantity ≤ current BP-approved stock`. Vendor is required (structural — dispatch must go to a known vendor). Vehicle, driver, and challan_number are nullable and never block save — support "select existing or type new" inline, so these lists build up organically instead of needing to be pre-seeded.
**Permissions:** Store, Admin.

### 4.6 Receive from Faco
**Fields:** id, batch_number, date, part, quantity_received, dispatch_ref, supplier_challan, shortage_flag (computed), remarks, created_by.
**Permissions:** Store, Admin.

### 4.7 AP Inspection
**Fields:** id, batch_number, date, part, quantity_checked, approved_qty, rejected_qty, reject_reason, inspector, photo_url, remarks.
**Validation:** `approved_qty + rejected_qty = quantity_checked`.
**Permissions:** Quality Inspector.

### 4.8 RTV
**Fields:** id, batch_number, cycle_number (auto), date, part, rtv_qty, reason, vendor, status, expected_return_date, actual_return_date, photo_url, remarks.
**Validation:** Cap at 3 cycles (3.3). Cumulative `rtv_qty ≤ AP rejected_qty` (3.4).
**Permissions:** Store, Quality Inspector.

### 4.9 RTV Re-Inspection
**Fields:** id, rtv_id, date, quantity_received, ok_qty, reject_again_qty, next_action, remarks.
**Validation:** `ok_qty + reject_again_qty = quantity_received`.
**Permissions:** Quality Inspector.

### 4.10 Final Dispatch
**Fields:** id, batch_number, date, part, customer (default = Thal, required), dispatch_qty, vehicle (optional), driver (optional), challan_number (optional), photo_url, remarks, created_by.
**Validation:** `dispatch_qty ≤ current Approved AP Stock`. Customer is required (structural). Vehicle, driver, and challan_number are nullable and never block save.
**Permissions:** Store, Admin.

### 4.11 Dashboard
Stock cards: Raw Material, BP Stock, At Faco, Pending AP Inspection, Approved AP Stock, RTV Stock.
Production cards: Today's Production, Today's BP Reject, Today's AP Reject, Today's Dispatch, Monthly Production.
KPIs: Today's Target %, Machine Utilization %, Production Efficiency %, Overall Reject %, Pending Faco, Pending RTV, Pending AP Inspection, Low Stock Alerts, Machine Status (live).
All figures read from Stock_Ledger — never live-summed from transaction tables (7.1).

### 4.12 Reports
Daily/Weekly/Monthly Production, Machine-wise, Operator-wise, Machine Efficiency, Operator Efficiency, Target Achievement, Machine Downtime, BP Reject Analysis, AP Reject Analysis, RTV Analysis, Vendor Performance, Dispatch Report, Faco Pending Material, Current Live Stock, Inventory Movement, PO Status Report.

### 4.13 Global Search
By: Batch, Part, Machine, Operator, Date Range, Challan, PO, Vendor, Customer, Status.

### 4.14 Notifications
Daily Target Missed, Machine Breakdown, RTV Pending, Faco Material Delayed, Low Stock, High Reject Alert.

### 4.15 Photo Attachments
On: BP Reject, AP Reject, RTV, Machine Breakdown, Dispatch Evidence. Stored via Supabase Storage. Optional — never blocks submission; queues and syncs like offline data.

---

## 5. Database Design

> `factory_id` on every table for configurability/future-multi-factory readiness (Chapter 11). Phase 1 has exactly one row in `Factories`.

### 5.1 Master Tables
```
Factories: id, name, address, timezone, created_at
Users: id, factory_id, name, phone, email, password_hash, role, active, created_at
Operators: id, factory_id, name, active           -- master-data only, not a login
Parts: id, factory_id, code, name, uom, active
Machines: id, factory_id, name, sequence_order, active
Shifts: id, factory_id, name, start_time, end_time
Suppliers: id, factory_id, name, contact, address, active
Vendors: id, factory_id, name, contact, address, vendor_type, active
Customers: id, factory_id, name, contact, address, is_default, active
Vehicles: id, factory_id, number_plate, type, active
Drivers: id, factory_id, name, license_number, phone, active
BP_Reject_Reasons: id, factory_id, reason, active
AP_Reject_Reasons: id, factory_id, reason, active
RTV_Reasons: id, factory_id, reason, active
Machine_Status_Types: id, name
Target_Master: id, factory_id, part_id, day_of_week, target_qty, effective_from, effective_to
Purchase_Orders: id, factory_id, po_number, supplier_id, part_id, ordered_qty, status, date
```

### 5.2 Transaction Tables
```
Opening_Stock: id, factory_id, part_id, stage, qty, date, entered_by
Material_Receive: id, factory_id, date, time, supplier_id, po_id, part_id, qty, remarks, created_by, created_at
Production: id, factory_id, batch_number, date, time, shift_id, part_id, machine_id, operator_id,
            machine_status_id, production_qty, bp_reject_qty, good_qty, remarks, created_by, created_at
Machine_Downtime: id, factory_id, machine_id, date, start_time, end_time, duration_minutes, reason,
                  operator_id, photo_url, remarks, created_by
BP_Inspection: id, factory_id, batch_number, date, part_id, machine_id, bp_reject_qty, reject_reason_id,
               inspector_id, photo_url, remarks
Dispatch_To_Faco: id, factory_id, batch_number, date, time, part_id, qty, vendor_id, vehicle_id, driver_id,
                   challan_number, remarks, created_by
Receive_From_Faco: id, factory_id, batch_number, date, part_id, qty_received, dispatch_ref_id,
                    supplier_challan, shortage_flag, remarks, created_by
AP_Inspection: id, factory_id, batch_number, date, part_id, qty_checked, approved_qty, rejected_qty,
               reject_reason_id, inspector_id, photo_url, remarks
RTV: id, factory_id, batch_number, cycle_number, date, part_id, rtv_qty, reason_id, vendor_id, status,
     expected_return_date, actual_return_date, photo_url, remarks
RTV_Reinspection: id, factory_id, rtv_id, date, quantity_received, ok_qty, reject_again_qty, next_action, remarks
Final_Dispatch: id, factory_id, batch_number, date, part_id, customer_id, dispatch_qty, vehicle_id, driver_id,
                challan_number, photo_url, remarks, created_by
Stock_Ledger: id, factory_id, date, time, part_id, stage, direction, qty, ref_table, ref_id,
              running_balance, created_at
Correction_Requests: id, factory_id, table_name, record_id, requested_by, requested_at, reason,
                      old_value_json, proposed_value_json, status, reviewed_by, reviewed_at
Audit_Log: id, factory_id, table_name, record_id, action, old_value_json, new_value_json,
           changed_by, changed_at, device
```

### 5.3 Constraints
- `Production.bp_reject_qty ≤ Production.production_qty`
- `AP_Inspection.approved_qty + AP_Inspection.rejected_qty = AP_Inspection.qty_checked`
- `RTV_Reinspection.ok_qty + RTV_Reinspection.reject_again_qty = RTV_Reinspection.quantity_received`
- Cumulative `RTV.rtv_qty` per batch `≤ AP_Inspection.rejected_qty` for that batch
- No transaction may drive any `Stock_Ledger.running_balance` negative
- `RTV.cycle_number` per batch capped at 3

---

## 6. Data Relationships

> A prior review of this PRD proposed several of these as one-to-one (e.g. "One Batch → One Faco Dispatch", "One Dispatch → One Receive"). Locked as one-to-one, the system breaks the first time a **partial dispatch** or a **shortage-driven partial return** happens (see 3.6, 3.7) — which is normal factory behavior, not an edge case. Corrected to one-to-many below wherever a batch can legitimately move in more than one physical shipment.

| Relationship | Cardinality | Why |
|---|---|---|
| Part → Production | 1 : Many | A part is produced across many days/machines/shifts |
| Batch (`batch_number`) → Production entries | 1 : Many | Same batch can have entries across multiple shifts on its production day |
| Batch → BP_Inspection | 1 : Many | Inspection can happen in more than one pass |
| Batch → Dispatch_To_Faco | 1 : Many | A batch can be sent to the vendor in multiple shipments |
| Dispatch_To_Faco → Receive_From_Faco | 1 : Many | One dispatch can come back in partial/shortage-driven shipments |
| Batch → AP_Inspection | 1 : Many | Returned material can be checked in multiple passes |
| AP_Inspection (reject event) → RTV | 1 : Many | Up to 3 RTV cycles per the escalation cap (3.3) |
| RTV → RTV_Reinspection | 1 : Many | Modeled as one-to-many for correction flexibility, typically one per cycle |
| Batch → Final_Dispatch | 1 : Many | Approved stock from a batch can ship to the customer across multiple shipments |
| Part → all transaction tables | 1 : Many | Every transaction table carries `part_id` |
| Factory → everything | 1 : Many | Multi-tenancy scoping (Chapter 11) |

---

## 7. Business Rules

**Core rules (non-negotiable, enforced at the application/DB layer):**
1. Opening Stock is set exactly once per part/stage at initial setup. After that, all stock changes are 100% derived from transactions via Stock_Ledger — never manually recalculated.
2. Negative stock is never allowed at any stage — hard-blocked at save time.
3. Production (and every transaction) is never hard-deleted. Corrections happen via Correction Requests + reversal ledger entries, never an in-place historical edit.
4. Every transaction is immutable once created within its edit window; changes after that go through the formal correction workflow (7.5), always audit-logged.
5. Every unit of output is traceable end-to-end via `batch_number`, from raw material through final dispatch or scrap.
6. RTV cannot exceed 3 cycles per batch without Admin escalation resolution (3.3).
7. RTV quantity can never exceed the AP-rejected quantity for that batch (3.4).

### 7.1 Stock Ledger — Single Source of Truth
No dashboard or report ever live-sums raw transaction tables. Every material movement writes an explicit IN/OUT row to `Stock_Ledger` with a running balance per `(part_id, stage)`.

### 7.2 Batch Numbering
`{PartCode}-{YYYYMMDD}-{MachineSeq}-{Sequence}`, e.g. `V21-20260711-B-001`. Generated at first Production entry for a part/machine/day, unchanged through the pipeline; designed to double as a future QR payload (Chapter 14).

### 7.3 Target Calculation
Read from `Target_Master` by `(part_id, day_of_week)` — never hardcoded. Missing config for a day flags "target not configured" to Admin rather than defaulting to 0.

### 7.4 Efficiency & Reject Formulas
```
Production % = SUM(good_qty) / target_qty
Machine Utilization % = machine running time / shift duration
BP Reject % = SUM(bp_reject_qty) / SUM(production_qty)
AP Reject % = SUM(rejected_qty) / SUM(qty_checked)
```

### 7.5 Correction / Approval Workflow
Same-day edits: direct, audit-logged (old + new value + device). After rollover: `Correction_Requests` row (pending) → Admin reviews → on approval, `Stock_Ledger` gets reversal entries for the old value + new entries for the corrected value. Historical rows never mutated in place. Full correction history queryable via `Correction_Requests` + `Audit_Log`.

### 7.6 Offline-First Sync
Offline entries stored locally (Drift/SQLite) with client-generated UUID, synced on reconnect. Server is authoritative on stock balances — if a sync would drive a balance negative, the entry is flagged "Sync Conflict — Needs Review" rather than silently corrupting stock. Photos queue and upload the same way.

---

## 8. Error Handling

| Scenario | Expected Behavior |
|---|---|
| Internet lost mid-entry | Entry saves to local DB, queued for sync, UI shows "Pending Sync" badge — no data loss |
| Duplicate entry (same machine + date + shift) | Warn, don't hard-block — corrections happen; user confirms if intentional |
| Invalid quantity (negative/non-numeric) | Inline validation error, save blocked |
| Insufficient stock (e.g. dispatch > available) | Hard block, message shows available quantity |
| Session expired | Redirect to login, unsaved local-only entry preserved, not discarded |
| Sync failed after reconnect | Retry with backoff; after repeated failure, flag "Sync Failed — Manual Retry," notify user, never silently drop data |
| Photo upload failed | Entry saves without photo; photo retries upload in background, flagged until successful |

---

## 9. UI/UX Requirements

- Android-first, Material Design 3, large tap targets (min 44dp), dropdown/searchable-select wherever a master table exists.
- Dashboard is the first screen after login — card grid, no extra navigation friction.
- Entry forms: single-screen per module, auto-filled date/time/user, prominent Save action, inline validation errors.
- Camera integration for photo attachments directly from the relevant entry form.
- Dark and Light theme, professional industrial look — no decorative animation on data-entry screens.

### 9.1 UX Rules (calibrated by form complexity)
- **Simple, frequent entries** (Material Receive, single-field confirmations): target ≤ 2 taps to save.
- **Multi-field entries** (BP/AP Inspection, RTV — 5–10 required fields each): a fixed 2-tap rule is not achievable without stripping mandatory fields, which breaks traceability. Target instead: minimum steps = number of required fields, reduced via smart defaults (auto-filled date/time/user, remembered last-used dropdown values, autocomplete).
- Minimum typing everywhere; dropdowns and autocomplete over free text wherever a master table exists.
- Primary quick actions reachable one-handed on standard phone sizes; multi-field forms may reasonably need two-hand use — that's expected and fine.
- Large buttons, Dark Mode support throughout.

---

## 10. Technical Architecture

- **Platform:** Android Mobile Application (primary). Native Android only if a specific performance-critical requirement later demands it.
- **Framework:** Flutter (Dart) — single codebase, future iOS path if ever needed.
- **State Management:** Riverpod.
- **Backend:** Supabase (Postgres, Auth, Storage, Realtime).
- **Offline Local Database:** Drift (SQLite-based) — chosen over Isar; the data model is heavily relational (batch → inspection → dispatch → RTV chains, foreign keys, ledger joins), and Drift's SQL model maps directly onto the Postgres schema. *(Confirm before dev — Open Questions.)*
- **Architecture pattern:** Clean Architecture, feature-first folder structure.
- **File storage:** Supabase Storage for photo attachments.
- **QR/Barcode:** Not built in Phase 1; `batch_number` format (7.2) is scan-ready for when this is added.

### 10.1 Security
- **Authentication:** Supabase Auth (JWT-based session tokens), email/phone + password.
- **Role-based permissions:** enforced server-side via Postgres Row-Level Security policies keyed on `factory_id` and `role` — not only hidden in the app UI.
- **Password reset:** via Supabase Auth's built-in email/OTP flow.
- **Session timeout:** auto-logout after a configurable inactivity period; forced re-auth on token expiry.
- **Local data encryption:** open question — see Chapter 15. Recommendation: standard Android per-app storage sandboxing is sufficient unless there's a specific confidentiality concern (e.g. competitor visibility into vendor rates); SQLCipher adds real overhead for data that isn't PII or financial-secret-grade.

### 10.2 Performance Requirements
- Dashboard load < 2 seconds.
- Search results < 1 second.
- Designed to remain performant beyond 100,000 records per transaction table (indexes on `batch_number`, `date`, `part_id`, `factory_id`).
- Smooth scrolling on list screens, no UI jank.
- Optimistic local UI updates on save — sync happens in the background, not blocking the UI thread.

### 10.3 Non-Functional Requirements
Mobile-first, Android-optimized, responsive across device sizes; automatic backup via Supabase managed Postgres backups; scalable architecture (`factory_id`-scoped queries from day one).

---

## 11. Configurability & Multi-Tenancy Scope

**A. Configurable master data (in scope, Phase 1):** Parts, Machines, Vendors, Customers, Reject Reasons, Targets are database-backed master tables managed through Admin CRUD screens — never hardcoded as enums/constants in code.

**B. Configurable business-rule / workflow engine (explicitly out of scope, Phase 1):** The workflow sequence itself, the RTV cycle cap, and all validation rules in Chapter 7 remain hardcoded in application logic. Making the workflow configurable (different stage sequences, different approval chains per factory) is a fundamentally larger product and is not part of this PRD.

Every table carries `factory_id` so onboarding a second real factory is a data/config exercise later, not a schema rewrite.

---

## 12. Success Criteria
Project is successful when:
- Daily entry workflow completes in under 5 minutes.
- Manual stock calculations = 0.
- Live stock is available at every pipeline stage.
- Any historical record is searchable within 5 seconds.
- Reports generate automatically, with no manual compilation.
- Data accuracy > 99%, measured via periodic physical stock reconciliation against system stock.
- Every unit of finished goods is traceable end-to-end via batch number.

---

## 13. Development Strategy (Phases)
```
Phase 1 — Requirements               (this document)
Phase 2 — Database Design            (Supabase schema + RLS policies)
Phase 3 — UI Design                  (screen-by-screen wireframes)
Phase 4 — Backend Development        (Supabase schema, functions, RLS)
Phase 5 — Flutter Development        (Clean Architecture, feature-first)
Phase 6 — Testing                    (validation rules, offline sync, edge cases)
Phase 7 — Production Deployment
Phase 8 — Future Enhancements        (Chapter 14)
```

---

## 14. Future Roadmap (Explicitly Deferred)
Active QR/barcode scanning (batch_number is scan-ready), iOS build, web dashboard on the same Supabase backend, predictive maintenance/downtime analytics, AI-based reject-pattern insights, configurable workflow/business-rule engine (11B), multi-factory config UI.

---

## 15. Resolved Decisions (formerly Open Questions)

All 9 items below are locked. An AI implementation agent must treat these as final — do not re-ask, do not re-litigate. If a genuine new conflict is found, follow the Change Control process in `AI_AGENT_RULES.md` Section 4.

| # | Question | Decision |
|---|---|---|
| 1 | Drift vs Isar | **Drift.** Final. |
| 2 | Saturday target | **400 PCS** (same as Friday), stored in `Target_Master` — changeable via data, not code, if wrong. |
| 3 | Target measurement stage | **End Forming** (final machine) output — this is the completed-production figure that feeds BP Inspection. |
| 4 | Faco vendor cardinality | System supports multiple vendors (already in schema). **Seed one vendor, "Faco," for now.** |
| 5 | PO tracking depth | **Lightweight** — `po_number` reference + warn-only over-receipt check. No strict ordered/received reconciliation blocking. |
| 6 | UOM scope | **PCS by default**, per-part `uom` field already supports other units if raw material is ever tracked in KG/coils — no schema change needed. |
| 7 | RTV escalation reason | **Mandatory.** Admin must enter a reason in the `remarks` field when resolving an Escalated RTV (Scrap or Force-Dispatch). |
| 8 | Master data admin UI on day 1 | **No.** Seed master data directly via SQL/script initially (15.2). Build Admin CRUD screens in a later sprint once core transactional flows work. |
| 9 | Local data encryption | **No.** Standard Android per-app storage sandboxing is sufficient for Phase 1. |

### 15.1 Still Needs Product Owner Input (not architectural — this is real company data)
Only the following are structural prerequisites (a dispatch/receive record cannot exist without knowing who it's to/from) — everything else is optional and can be added later through the app itself, with no impact on starting development:
- Real supplier name(s) for Material Receive
- Confirm plating vendor's exact name (default: "Faco")
- Confirm customer default is "Thal" and whether other customers exist

**Not required, ever, as a blocker:** Vehicle and Driver names. These are optional fields (4.5, 4.10) that can be typed in ad-hoc the first time a specific vehicle/driver is used — no pre-seeded list needed. Challan number is likewise optional, since paperwork sometimes arrives after the physical dispatch.

None of the above is needed before Phase 1 (wireframes) or Phase 2 (schema) — it only matters once real data entry/testing begins.

### 15.2 Starter Master Data (for initial seed script — edit/confirm before use)

**BP_Reject_Reasons (pre-plating defects):**
Crack, Dimension Out of Tolerance, Bend Angle Error, Surface Scratch, Burr/Sharp Edge, Deformation, Incomplete Forming

**AP_Reject_Reasons (post-plating defects):**
Plating Peel-off, Uneven Coating, Rust/Corrosion Spot, Discoloration, Plating Thickness Out of Spec, Handling Damage

**RTV_Reasons:**
Plating Quality Reject, Vendor Processing Delay, Damaged in Transit, Wrong Quantity Received

**Machine_Status_Types:**
Running, Breakdown, Maintenance, Idle

*(These are standard categories for this exact process — bending/notching/end-forming plus plating. Review and edit before seeding; add/remove based on what you actually see on the floor.)*

### 15.3 First Admin User (Bootstrap)
The app itself cannot create the first Admin, since no user with permission exists yet. Create the first Admin user directly in the **Supabase dashboard** (Auth → add user, then insert a matching row in the `Users` table with `role = Admin`) before the app is used for the first time. This is a one-time manual step, not a feature to build.

---

## 16. AI Implementation Instructions

> **Note before using this chapter:** This chapter directs whichever AI coding assistant picks up this PRD next. Two things must be reconciled with the rest of this document before it starts:
> 1. **Chapter 15 is resolved as of v2.3** — all 9 decisions are locked. The only remaining input needed is 15.1 (real company data: supplier/vendor/vehicle/driver names), which the product owner supplies before seeding, not the AI.
> 2. **Phase ordering here vs. Chapter 13:** the phases below (UI Wireframes → ER Diagram → API Docs) describe *design deliverables to produce within an implementation session*, not the project's macro phase order. Chapter 13 already establishes Database Design before UI Design at the project level, and Chapter 5 already contains a full first-pass schema. Phase 2 below should **validate and extend** that existing schema, not redesign it from scratch — and Phase 1 wireframes should be built against the fields already defined in Chapter 4, not invented independently.

### Important Instructions

Before writing any code, implementing any feature, or generating any project files, you must behave as a team of highly experienced professionals consisting of:

- Senior Product Manager
- Senior Software Architect
- Senior Manufacturing ERP Consultant
- Senior Flutter Developer
- Senior Backend Engineer
- Senior Database Architect
- Senior UI/UX Designer
- Senior QA Engineer

Your responsibility is to critically review this entire PRD instead of blindly following it.

You must identify missing requirements, edge cases, business logic problems, scalability issues, security concerns, performance risks, database flaws, workflow gaps, and UI/UX improvements.

Never assume the PRD is perfect.

Challenge every requirement and improve it where necessary.

If something is ambiguous, stop and ask questions instead of making assumptions.

Do NOT start coding until the architecture is fully reviewed and approved.

---

### Phase 1 — UI Wireframes

Create complete low-fidelity mobile wireframes for the entire application.

Include every major screen, including but not limited to:

- Login
- Dashboard
- Material Receive
- Production Entry
- BP Inspection
- Dispatch to Faco
- Receive from Faco
- AP Inspection
- RTV Management
- Final Dispatch
- Reports
- Search
- Notifications
- Settings
- User Management

For each screen provide:

- Purpose
- User Flow
- Navigation
- Layout
- Components
- Input Fields
- Buttons
- Dropdowns
- Validation Messages
- Empty States
- Error States
- Loading States
- Success States
- Mobile UX Best Practices

The design should prioritize:

- One-hand mobile operation
- Large touch targets
- Minimal typing
- Maximum automation
- Fast daily data entry
- Industrial workflow optimization

---

### Phase 2 — ER Diagram & Database Architecture

Design a production-grade relational database.

Create:

- Complete ER Diagram
- Entity Relationships
- Primary Keys
- Foreign Keys
- Constraints
- Indexes
- Unique Keys
- Cascade Rules
- Stock Ledger Design
- Batch Tracking Design
- Work-In-Progress (WIP) Tracking
- Audit Log
- User Permissions
- Transaction Flow

Explain why each table exists and how it connects to the rest of the system.

Validate that the database can support years of production data without redesign.

---

### Phase 3 — API Documentation

After the database is finalized, design REST APIs for the complete application.

For every endpoint include:

- Endpoint URL
- HTTP Method
- Purpose
- Authentication Requirement
- Request Body
- Response Body
- Validation Rules
- Error Responses
- Status Codes
- Pagination
- Filtering
- Searching
- Sorting
- Security Considerations

Use REST API best practices.

Ensure the APIs are scalable, secure, and optimized for Flutter applications.

---

### Final Architecture Review

Before starting implementation, perform a complete architecture review.

Identify:

- Missing Features
- Missing Tables
- Missing Business Rules
- Security Risks
- Performance Bottlenecks
- Scalability Issues
- Manufacturing Workflow Problems
- UI/UX Problems
- Data Integrity Risks

Then provide recommendations and improve the architecture until it reaches production-grade quality.

Do not compromise quality for speed.

The goal is to produce a maintainable, scalable, secure, enterprise-grade Android application that follows modern software engineering principles and can eventually evolve into a full Manufacturing ERP platform.

---

*End of PRD v2.2. Next: Resolve Chapter 15 Open Questions → Chapter 16 Phase 1 (Wireframes) → Phase 2 (ER Diagram, building on Chapter 5) → Phase 3 (API Docs) → Final Architecture Review → development.*
