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
