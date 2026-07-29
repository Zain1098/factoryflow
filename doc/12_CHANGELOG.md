# Documentation Changelog

## v3.0-dev - 2026-07-29
- Added the Gate 0 repository gap report and safe migration plan.
- Recorded current native sqlite3 divergence from the locked Drift architecture.
- Recommended staged Drift adoption over the existing database file, subject to
  an approved ADR and migration tests.
- Documented data-at-risk, rollback conditions, security requirements, and Gate
  0 exit criteria.
- Added production-page widget regression coverage for narrow mobile rendering
  and actionable parts-loading errors instead of a blank page.
- Scoped production batch helpers, WIP validation, batch trails, and related
  joins by active factory, with in-memory SQLite isolation tests.
- Blocked production posting when no active factory workspace is selected.
- Made local production event, stock-ledger, and sync-queue posting atomic; a
  forced production-insert failure now rolls back all stock and queue writes.
- Routed queued stock-ledger mutations through the server ledger RPC operation
  and added regression coverage for the queue contract.
- Replaced new production sync fan-out with one versioned
  `production_post` command containing the event and every resulting ledger
  movement, while retaining legacy queue handlers for already-pending items.
- Added a forward-only Supabase migration for atomic/idempotent production
  posting, deterministic advisory locks, balanced quantity checks, expanded
  production ledger stages, and workspace-membership-aware authorization.
- Added a persistent local device UUID to production mutation envelopes and
  regression coverage proving one command is queued with all ledger rows.
- Applied the atomic production migration to the live Supabase project as
  migration `20260729174535`. Existing data counts remained 3 production rows
  and 0 ledger rows; the RPC, stage constraint, indexes, and intended
  authenticated-only privileges were verified.
- Kept `ATOMIC_PRODUCTION_SYNC_ENABLED` disabled after deployment because the
  live ledger baseline is empty. This prevents new server-authoritative
  production commands from becoming false insufficient-stock conflicts before
  ledger reconciliation. Older queue operations remain backward compatible.
- Verified the migration in an isolated PostgreSQL-compatible runtime: schema
  compilation, one event plus three ledger inserts, idempotent retry, duplicate
  conflict, insufficient-stock no-write behavior, anonymous privilege denial,
  and non-member denial all passed before the controlled live deployment.
- Added a full client/server/business-flow audit with a connected-device UX
  smoke test and an ordered P0 remediation path.
- Fixed Daily Production master-data lifecycle so selecting a part can open Add
  Machine Entry instead of repeatedly reporting that masters are loading.
- Made shared dropdowns and the automatic good-output row responsive on narrow
  mobile layouts; added a widget flow test that opens the machine-entry form.
- Scoped central local ledger balances, stock totals, target reads, and
  Dashboard operational calculations to the active factory, with a two-factory
  characterization test.
- Updated Dashboard dispatch totals to read the current local
  dispatch-session/item model.
- Upgraded `share_plus` to 13.3.0 and `flutter_secure_storage` to 10.3.1. The
  final AGP 9 debug build completed without the prior plugin-applied Kotlin
  warning.

## v3.0 - 2026-07-29
- Re-established a single source-of-truth hierarchy.
- Separated PRD, business rules, architecture, database/sync, coding, UX, security, testing, roadmap, and AI rules.
- Added batch timeline, drafts, smart defaults, shift handover, physical reconciliation, data-quality dashboard, diagnostics, configurable alerts, and controlled exports.
- Strengthened idempotency, offline conflict handling, migration discipline, RLS, and release gates.
- Clarified that advanced AI, barcode, web, iOS, and workflow engine remain future scope.

## Historical
- v2.4: Vehicle, driver, and challan optional; inline add-new behavior.
- v2.3: Open architectural decisions locked.
- v2.0-v2.2: Android pivot, expanded ERP scope, implementation instructions.
