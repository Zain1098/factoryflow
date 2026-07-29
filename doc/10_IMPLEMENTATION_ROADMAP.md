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
  membership-aware authorization; live deployment remains pending controlled
  migration verification. The client path is guarded by
  `ATOMIC_PRODUCTION_SYNC_ENABLED=false` until that deployment is verified, so
  current production sync remains backward compatible.
- Pending approval: ADR for staged Drift adoption over the existing SQLite file.
- Pending work: database/ledger characterization tests, backup/restore proof,
  Supabase migration staging/RLS verification, live SECURITY DEFINER privilege
  cleanup from the advisor baseline, migration fixture, and CI baseline.

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
