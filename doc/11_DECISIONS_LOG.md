# Architecture Decision and Locked Decisions Log

## Locked product decisions
- Android Flutter is the primary client.
- Riverpod remains state management.
- Drift remains the local database.
- Supabase remains backend/auth/storage.
- Offline-first local write then sync.
- Stock Ledger is authoritative.
- No hard deletes for posted transactions.
- Operator is master data, not login role.
- Saturday target initially 400 PCS, configurable in data.
- Target measured at End Forming output.
- Multiple Faco vendors supported; seed Faco.
- PO tracking is lightweight and over-receipt is warning-only.
- Default UOM is PCS, part field supports others.
- Admin reason mandatory for RTV escalation resolution.
- Vehicle, driver, challan optional.
- Local SQLCipher encryption not required in Phase 1.

## ADR template
### ADR-XXX: Title
- Date:
- Status: Proposed / Accepted / Superseded
- Problem:
- Constraints:
- Options considered:
- Decision:
- Consequences:
- Migration impact:
- Security impact:
- Test requirements:
- Supersedes:

## New v3 decisions
### ADR-001: Transaction event plus ledger model
Status: Accepted
Decision: Posted operational events are immutable; stock effect is represented by idempotent ledger rows and reversible correction events.

### ADR-002: Conflict policy
Status: Accepted
Decision: Stock conflicts never use last-write-wins. They require domain-aware review.

### ADR-003: Draft separation
Status: Accepted
Decision: Draft forms live separately and never affect stock or reports.

### ADR-004: Physical reconciliation
Status: Accepted
Decision: Physical counts record variance; only approved adjustments change ledger.

### ADR-005: Workspace Owner authorization ceiling
- Date: 2026-07-30
- Status: Accepted
- Problem: Self-service workspace creation stores `owner`, while the original
  server policies authorize full-control operations as `Admin`.
- Decision: Keep the stored product role `owner`, but map it to `Admin` inside
  the server role helper. Every affected operation remains restricted to the
  caller's active `factory_id`; Owner never receives cross-factory access.
- Consequences: A workspace creator can sync Admin-authorized operations for
  their own company without changing the role displayed by the client.
- Migration impact: Applied in `20260730173550_secure_sync_schema_alignment`.
- Security impact: Role lookup requires an authenticated, active user and an
  empty function search path; anonymous execution is revoked.
- Test requirements: Owner mapping, own-factory write, cross-factory denial,
  function grants, and RLS must pass.

### ADR-006: RTV state changes use controlled server commands
- Date: 2026-07-30
- Status: Accepted
- Problem: A table-level RTV UPDATE grant would allow an authorized Quality
  user to alter fields beyond the intended status and return date.
- Decision: Revoke direct Data API UPDATE on RTV rows. Reinspection status is
  derived by `refresh_rtv_status`; Admin escalation uses
  `resolve_rtv_escalation`. Both verify factory, role, quantities, and synced
  ledger effects.
- Consequences: The sync worker routes RTV updates through the correct RPC;
  batch, part, quantity, cycle, vendor, and factory remain immutable.
- Migration impact: Applied in `20260730173550_secure_sync_schema_alignment`.
- Security impact: Least-privilege server authorization replaces generic row
  updates.
- Test requirements: RPC routing, direct UPDATE denial, factory isolation,
  role enforcement, quantity equations, and ledger matching must pass.
