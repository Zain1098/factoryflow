# Gate 0 Gap Report and Safe Migration Plan

Date: 2026-07-29
Status: Draft for approval
Baseline commit: `5a55d17`

## 1. Scope

This report compares the current FactoryFlow repository with the v3.0 controlled
documents. Gate 0 freezes new feature work while stock integrity, local database,
sync, migration, and test risks are understood.

No runtime behavior or database schema is changed by this report.

## 2. Current repository inventory

- Flutter Android application using Riverpod and GoRouter.
- Local persistence uses native `sqlite3` and the existing
  `factoryflow.sqlite` file.
- Supabase remains the remote Auth/Postgres/Storage platform.
- Six forward Supabase migration files are present; the newest atomic
  production-posting migration is local-only pending controlled staging.
- Operational modules exist for material receive, production, downtime, BP/AP
  inspection, Faco dispatch/receive, RTV, final dispatch, reports, search,
  corrections, notifications, settings, and dashboard.
- Stock movement is centralized through `StockLedgerService`. Production event,
  ledger, and sync-queue writes are now one local transaction; other
  stock-changing flows still require the same audit and characterization.
- Local schema is created with `CREATE TABLE IF NOT EXISTS` plus compatibility
  `ALTER TABLE` checks. There is no formal local schema version.
- Automated coverage currently consists of configuration/offline-startup tests;
  critical ledger, repository, sync, database migration, and production widget
  tests are missing.

## 3. Source-of-truth conflicts and gaps

| Priority | Requirement | Current state | Risk |
|---|---|---|---|
| P0 | Drift is the locked local database | App directly uses `sqlite3` | Unapproved architecture divergence and no generated migration model |
| P0 | Atomic event + ledger + projection + queue posting | Production is atomic locally and has a staged server RPC behind a disabled rollout flag; other flows still perform separate writes | Partial failure can leave orphan ledger or event data until the server migration is verified and outside production |
| P0 | Idempotent mutation envelope | Production now carries command UUID, device/user/factory/time/schema/app metadata; other mutations and dependency metadata remain incomplete | Duplicate effect or ambiguous retry outside the migrated slice |
| P0 | Domain-aware conflict review | Queue can mark conflict, but no complete `sync_conflicts` record/reviewer/resolution model exists | Conflict cannot be safely reviewed or audited |
| P0 | Versioned local migrations | Compatibility checks mutate schema without a schema-version contract | Upgrade behavior cannot be reliably tested or rolled back |
| P0 | Factory isolation | Most writes are scoped; selected batch/helper/report queries still need a complete audit | Cross-workspace data mixing |
| P0 | Ledger-only stock truth | Ledger service exists; some reporting/query paths require proof that they do not calculate an alternative balance | Inconsistent stock display |
| P0 | SECURITY DEFINER privileges | Live Supabase advisors report anonymous execution grants on existing RPCs; the staged production migration revokes anonymous access only for the two ledger/production posting RPCs | Exposed privileged function surface requires a separate full privilege audit |
| P1 | Typed domain/application errors | Many repositories and widgets use maps, strings, and generic exceptions | Weak validation and unclear recovery actions |
| P1 | Draft separation | No canonical `draft_forms` persistence/status model | Long form recovery and no-stock draft guarantee are absent |
| P1 | Structured diagnostics | Basic sync history exists; device/schema/mutation correlation is incomplete | Slow production support and weak audit evidence |
| P1 | Required test pyramid | Only basic tests exist | Stock, migration, offline, retry, and RLS regressions are not gated |

## 4. Data at risk during migration

The following data must be backed up and reconciled before changing the local
database adapter:

- Pending, retrying, failed, or conflict sync-queue items.
- Posted stock-ledger rows and their running balances.
- Production/WIP batch history and stage links.
- Active workspace and membership settings.
- Correction requests, audit logs, backup records, and stock adjustments.
- Unsynced photo/file references.

Migration must preserve the existing database filename and record UUIDs. It must
not create a second independent stock database or dual-write stock mutations.

## 5. Architecture decision required

### Option A: Big-bang Drift rewrite

Replace native SQLite access and all repositories together.

- Advantage: reaches the target architecture quickly.
- Risk: highest chance of data loss, stock divergence, and long app downtime.
- Recommendation: reject.

### Option B: Staged Drift adoption over the existing SQLite file

Model the current schema in Drift, add schema-version/migration tests, preserve
the existing file and IDs, then switch one verified data boundary at a time.
Keep the old adapter available only as a temporary rollback path; never
dual-write stock.

- Advantage: preserves data and supports parity testing.
- Risk: temporary adapter complexity and careful legacy-schema mapping.
- Recommendation: approve.

### Option C: Keep native sqlite3 permanently

Update Architecture and the locked decision through an approved ADR.

- Advantage: smallest immediate code change.
- Risk: contradicts the current v3.0 architecture and gives up Drift migration
  tooling unless equivalent tooling is designed.
- Recommendation: use only if Product Owner explicitly supersedes the Drift
  decision.

## 6. Recommended safe sequence

1. Approve ADR for Option B and record rollback criteria.
2. Add current-schema characterization tests using a temporary database.
3. Add fixtures for legacy database upgrades and pending sync/ledger records.
4. Define typed mutation, sync-status, and domain-error contracts without
   changing posted data.
5. Add Drift dependencies and schema definitions matching the existing file.
6. Introduce a numbered local schema version and non-destructive migrations.
7. Verify row counts, IDs, ledger balances, queue states, and workspace scope
   before and after migration.
8. Switch repositories in small vertical slices, starting with read-only master
   data and diagnostics.
9. Move one stock-changing flow only after atomic posting and duplicate-retry
   integration tests pass.
10. Remove the legacy adapter only after full parity, offline restart, migration,
    and rollback acceptance tests pass.

## 7. Security and stock-integrity requirements

- Never place service-role credentials in the Flutter app or migration fixtures.
- Preserve RLS and factory membership checks on every remote mutation.
- Do not silently merge or last-write-win stock conflicts.
- Never edit or hard-delete posted ledger/history rows.
- Validate non-negative balance locally and atomically again on the server.
- Use one idempotency key for one logical stock effect.
- Keep unsynced records recoverable through failed migration/rollback.

## 8. Required test gates

- Legacy SQLite database opens and migrates without row loss.
- Fresh install creates the expected versioned schema.
- Ledger balance before and after migration is identical.
- Duplicate mutation/retry creates one logical ledger effect.
- Event, ledger, projection, and queue either all commit or all roll back.
- Offline entry survives restart and later syncs.
- Server insufficient-stock response becomes a reviewable conflict.
- Wrong-factory and wrong-role access is denied.
- Production screen renders, preserves input on failure, and reports actionable
  errors instead of a blank page.

## 9. Rollback and stop conditions

Before adapter cutover, create a recoverable copy of the exact local database.
Abort and restore the previous app/database adapter if any row count, record ID,
ledger balance, queue payload, workspace scope, or posted-event relationship
changes unexpectedly.

Any stock corruption, duplicate posting, lost unsynced record, destructive
migration, or cross-factory access is a release blocker.

## 10. Gate 0 exit criteria

- ADR for the local database migration is approved.
- Current schema and critical flows have characterization tests.
- Backup/restore and migration rollback are demonstrated.
- CI runs formatter, analyzer, and tests.
- P0 gaps have owners and ordered implementation slices.
- Product Owner accepts this report and migration direction.

## 11. Atomic production migration verification

The committed `20260729143549_atomic_production_posting.sql` migration was
executed against an isolated PostgreSQL-compatible runtime on 2026-07-29.

Verified:

- Migration SQL compiled successfully.
- One production event inserted exactly three related ledger movements.
- Retrying the same command UUID returned idempotent success without duplicates.
- A second UUID for the same batch/machine returned a conflict.
- Insufficient raw-material stock returned a conflict and inserted no rows.
- Anonymous execution was revoked while authenticated execution remained.
- A user without active membership or the transitional factory fallback was
  denied.

The live Supabase preflight contained 3 production rows, 0 stock-ledger rows,
and no duplicate factory/batch/machine groups. Product Owner authorization was
received and the migration was applied as `20260729174535
atomic_production_posting`. Post-deployment checks confirmed unchanged row
counts, the expanded stage constraint, both composite indexes, the new RPC, and
authenticated-only execution for both stock-writing RPCs.

`ATOMIC_PRODUCTION_SYNC_ENABLED` now defaults to true. Legacy queue handlers
remain in place for already-pending pre-deployment mutations.
