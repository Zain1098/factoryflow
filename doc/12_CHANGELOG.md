# Documentation Changelog

## v3.0-dev - 2026-07-30
- Audited the installed Settings flow on the connected TECNO device and traced
  every visible option through its provider, local database, sync queue, and
  role behavior.
- Restricted factory setup, master data, correction review, stock management,
  and erase controls to Admin/Owner while keeping personal device/account
  settings available to all signed-in roles.
- Added Customers and Stock Management to Settings; fixed Vendor and Vehicle
  editing so Save updates the selected record instead of creating a duplicate.
- Made master edits, sequence changes, and deactivation use factory-scoped
  cloud update mutations; new master inserts now send real booleans to
  Supabase while SQLite retains its integer representation.
- Connected notification switches to notification delivery, sound, vibration,
  sync, production/stock/RTV, and downtime preference checks.
- Required a successful device authentication before enabling biometric lock
  and added an unsynced-record warning before sign-out.
- Scoped local backup, count, erase, and queued-mutation cancellation to the
  active factory, with two-company regression coverage.
- Applied live migration `20260730182909_admin_only_master_writes`. Parts,
  Machines, Operators, Suppliers, Vendors, Customers, Vehicles, and Drivers now
  require Admin/Owner authorization for server writes; company-scoped reads
  remain available and anonymous writes are revoked.
- Restored the Android/Gradle files after confirming the latest run failure was
  a laptop/tooling issue; no build-troubleshooting override remains in the app.
- Repaired invalid legacy Production Flow configuration on load and blocked
  production posting when a multi-stage route is empty or unusable.
- Added Production route/stock visibility and zero-stock guidance so the form
  explains why entry is unavailable instead of appearing blank.
- Made Material Receive, Purchase Order status, BP inspection, Faco
  dispatch/partial receive, AP inspection/reject actions, RTV, Final Dispatch,
  downtime, and manual adjustment locally transactional with their ledger and
  sync-queue records.
- Corrected the AP equation to `Approved + Rejected = Checked`; RTV is a subset
  of Rejected and cannot duplicate rejected stock.
- Completed the RTV client flow: AP candidate selection, vendor assignment,
  partial/full return, reinspection, reject-again cycles, cycle-3 escalation,
  and audited Admin Scrap/Force Dispatch resolution.
- Preserved the original Production batch through mandatory BP selection, Faco
  dispatch/receive, AP batch candidates, RTV, and batch-aware Final Dispatch
  items instead of generating unrelated AP/dispatch batch identifiers.
- Factory-scoped operational reports and global search, corrected normalized
  Final Dispatch reporting, and fixed dispatch-specific challan searches.
- Added deterministic offline test connectivity injection and bounded the
  production connectivity probe so a missing platform channel cannot block a
  durable local post.
- Added a read-only local database diagnostic for balances, pending sync,
  production/ledger mismatches, and RTV over-receipts.
- Applied live Supabase migration
  `20260730173550_secure_sync_schema_alignment`: added the missing Purchase
  Order, AP rejected-action, Dispatch session/item schema; validated quantity
  constraints; enabled factory-scoped RLS; and added explicit Data API grants.
- Kept the stored `owner` role while granting it the Admin authorization
  ceiling only inside its own factory. Cross-factory write smoke testing passed.
- Replaced generic RTV table updates with `refresh_rtv_status` and
  `resolve_rtv_escalation`. The server derives status from reinspection and
  ledger rows, while direct authenticated RTV UPDATE is revoked.
- Hardened workspace/profile/Google/OTP RPC identity checks, made workspace
  creation retries idempotent, stopped storing password-change values in OTP
  rows, set privileged function search paths to empty, and removed all 11
  anonymous SECURITY DEFINER advisor warnings.
- Applied follow-up migration
  `20260730173825_index_purchase_orders_part_fk`; the new Purchase Order foreign
  key now has a covering index.
- Routed mobile RTV sync updates through the controlled server RPCs and added
  RPC-selection regression tests.
- Added Production, transaction rollback, partial receive, AP/RTV equation,
  Final Dispatch aggregation, report factory-isolation, and search regression
  coverage. The previously executed 23 targeted tests passed; the newly added
  RTV tests are analyzer-clean but could not execute because the local Flutter
  command itself currently hangs, including `flutter --version`.

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
