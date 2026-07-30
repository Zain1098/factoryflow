# Implementation Roadmap

## Gate 0 - Recovery and alignment
- Freeze new feature coding.
- Inventory current repository, database, migrations, and implemented screens.
- Compare code against v3 documents.
- Identify data at risk and create backup.
- Decide migration path from native sqlite3 to Drift if current code differs.
- Repair broken tests and establish CI.

Deliverable: signed gap report and safe migration plan.

### Current Gate 0 status - 2026-07-29
- Repository checkpoint pushed at commit `5a55d17`.
- Repository, schema, migrations, screens, and current tests inventoried.
- Gap report and staged migration recommendation documented in
  `16_GATE_0_GAP_REPORT_AND_MIGRATION_PLAN.md`.
- Production blank-screen characterization tests added for narrow mobile layout
  and visible parts-loading failure.
- Production batch, WIP, history, and recent-entry queries hardened to remain
  inside the active factory; missing workspace now blocks production posting.
- Production event, ledger movements, and sync-queue writes now commit or roll
  back in one local SQLite transaction.
- Ledger queue items now use the existing server stock RPC operation instead of
  a direct table upsert.
- New production saves now queue one versioned mutation envelope containing the
  production event and all related ledger rows. A forward Supabase migration
  defines the atomic/idempotent `post_production_stage` RPC and
  membership-aware authorization. The migration was applied live as
  `20260729174535 atomic_production_posting`; post-deployment schema,
  privilege, data-count, and advisor checks passed.
- The atomic production migration compiled and passed isolated PostgreSQL
  behavior checks for first posting, idempotent retry, duplicate-stage
  conflict, insufficient-stock rollback, RPC privileges, and non-member
  authorization. Live preflight still shows 3 production rows, 0 ledger rows,
  and 0 duplicate stage groups.
- `ATOMIC_PRODUCTION_SYNC_ENABLED` remains false because the live server ledger
  currently has no baseline rows. Enabling server-authoritative production
  before stock reconciliation would correctly produce insufficient-stock
  conflicts. Legacy sync remains active until the ledger baseline is proven.
- Pending approval: ADR for staged Drift adoption over the existing SQLite file.
- Pending work: database/ledger characterization tests, backup/restore proof,
  server-ledger baseline reconciliation and atomic rollout activation,
  reviewed authenticated-RPC advisor exceptions, leaked-password protection,
  migration fixture, and CI baseline.
- Full system flow audit is recorded in
  `17_FULL_SYSTEM_FLOW_AUDIT_20260729.md`. Central local stock/dashboard reads
  are now active-factory scoped, Daily Production opens the real machine form
  on the connected TECNO device without render assertions, and the debug build
  no longer emits the plugin-applied Kotlin warning.
- Remaining flow blockers confirmed by the audit include non-atomic
  stock-changing modules outside Production, the Final Dispatch local/server
  table mismatch, unscoped report/search paths, incomplete RTV reinspection,
  and missing sync dependency/conflict-review models.
- Live schema alignment is now applied as
  `20260730173550_secure_sync_schema_alignment`, with missing operational
  tables/columns, validated constraints, explicit grants, RLS, factory-scoped
  Owner authorization, hardened auth RPCs, and controlled RTV transitions.
- The follow-up FK index migration
  `20260730173825_index_purchase_orders_part_fk` is also live. Security Advisor
  anonymous SECURITY DEFINER warnings dropped from 11 to 0. Remaining signed-in
  SECURITY DEFINER notices are intentional RPC surfaces with internal identity,
  factory, role, and input checks; leaked-password protection remains a
  dashboard configuration action.
- Settings hardening now keeps factory configuration, master data, corrections,
  stock adjustments, and local erase controls Admin/Owner-only. Personal
  account, appearance, biometric, notification, sync, and sign-out controls
  remain available to the signed-in user.
- Customers and Stock Management are reachable from Settings. Vendor and
  Vehicle edits now update instead of duplicating records; master updates,
  reordering, and deactivation queue factory-scoped cloud updates.
- Local erase/backup/count operations are scoped to the active factory and
  cancel only that factory's matching queued mutations. This prevents one
  workspace reset from erasing or later uploading another workspace's data.
- Remaining Settings work: shared-company member/role management, configurable
  shifts and reject reasons, full workspace export/import, dynamic app version,
  and end-to-end alert producers for low stock, RTV, targets, and downtime.
- Live migration `20260730182909_admin_only_master_writes` now matches the
  mobile role boundary at the server: all eight master tables remain readable
  inside the user's company, while INSERT/UPDATE/DELETE requires the
  Admin/Owner authorization ceiling. Anonymous master writes are revoked.

## Phase 1 - Foundation
- App shell, routing, themes
- Auth and profiles
- RLS baseline
- Drift schema and migrations
- master data caching
- structured errors/logging
- sync queue framework and diagnostics

## Phase 2 - Core production flow
- Material Receive
- Production stages and WIP consumption
- BP Inspection
- Ledger posting and balances
- Dashboard minimum viable cards

## Phase 3 - Vendor and quality flow
- Dispatch/receive Faco
- AP Inspection
- RTV and reinspection
- Final Dispatch
- Batch timeline

## Phase 4 - Control and reliability
- Corrections/approvals
- Audit log
- Conflict review
- Notifications
- Photos
- Physical reconciliation

## Phase 5 - Reporting and usability
- Reports and export
- Global search
- Smart defaults/favorites
- Shift handover
- Data-quality dashboard

## Phase 6 - Hardening
- Performance profiling
- Security tests
- offline stress tests
- migration tests
- staging seed and UAT
- release checklist

## Priority order
P0: stock integrity, auth/RLS, migrations, offline queue, core flow.
P1: corrections, audit, search, reports, diagnostics.
P2: smart defaults, shift handover, configurable alerts, reconciliation.
P3: barcode, web, AI analytics, advanced OEE.

## Rule
No P2/P3 feature may delay or destabilize P0. Humans love adding dashboards while the foundation is on fire; this roadmap declines that tradition.
