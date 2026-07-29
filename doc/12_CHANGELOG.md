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
