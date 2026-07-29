# Testing and Acceptance Strategy

## Test pyramid
1. Domain unit tests
2. Database/repository integration tests
3. Sync and server function tests
4. Widget tests
5. End-to-end golden business flows
6. Manual factory-floor acceptance

## Critical invariant tests
- Negative stock blocked
- Duplicate retry posts once
- Corrections reverse and replace correctly
- Partial dispatch and partial receive
- AP equation and RTV cap
- Final dispatch cannot exceed approved stock
- Draft does not affect ledger
- Conflict does not silently sync
- Multi-part same-day data remains isolated
- Factory RLS isolation

## Offline scenarios
- Create entry offline, restart app, entry survives
- Multiple dependent entries sync in order
- Network drops during sync
- Token expires with unsynced entries
- Photo fails while parent succeeds
- Server rejects quantity because another device consumed stock
- Manual retry after transient failure

## Performance acceptance
- Dashboard cached load under 2 seconds on target device
- Common local search under 1 second
- Lists scroll smoothly at representative record volume
- Sync queue of 500 items processes without UI freeze
- Report queries tested against at least 100,000 transaction rows per major table in staging

## Security acceptance
- RLS denies wrong role and wrong factory
- Service key absent from APK/repository
- Export requires permission
- Audit exists for all sensitive actions
- Signed photo URLs expire

## User acceptance flows
1. Full production-to-final-dispatch flow
2. AP reject and 3-cycle RTV escalation
3. Faco partial return and shortage
4. Same-day correction
5. After-day correction approval
6. Physical reconciliation adjustment
7. Shift handover
8. Offline work and later sync

## Release blocking defects
Any stock corruption, duplicate posting, unauthorized access, data loss, migration failure, unusable offline flow, or missing audit for privileged action blocks release.

## Definition of accepted feature
Requirements mapped, tests passing, permissions verified, offline behavior verified, user-facing errors clear, docs updated, and Product Owner walkthrough completed.
