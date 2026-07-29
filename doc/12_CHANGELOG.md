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
- Enabled `ATOMIC_PRODUCTION_SYNC_ENABLED` by default after post-deployment
  verification. Older pending queue operations remain backward compatible.
- Verified the migration in an isolated PostgreSQL-compatible runtime: schema
  compilation, one event plus three ledger inserts, idempotent retry, duplicate
  conflict, insufficient-stock no-write behavior, anonymous privilege denial,
  and non-member denial all passed before the controlled live deployment.

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
