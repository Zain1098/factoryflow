# Release Checklist

## Product
- Acceptance criteria approved
- No unapproved scope changes
- Critical workflows tested with realistic factory data

## Database
- Server migrations applied in staging
- Drift migration tested from previous released version
- Backup and recovery tested
- Constraints and indexes verified

## Stock integrity
- Negative stock tests pass
- Duplicate/retry tests pass
- Correction/reversal tests pass
- Projection rebuild matches ledger

## Security
- RLS enabled and tested
- Role/factory isolation tested
- No secrets in repository or APK
- Photo access private and expiring

## Offline and sync
- Offline create/edit flow passes
- Dependency ordering passes
- Conflict review passes
- Failed/retry visibility works
- Logout/reset warns about unsynced data

## Quality
- Analyzer clean
- Unit/integration/widget/E2E suites pass
- Performance targets checked on target Android device
- No release-blocking defects

## Operations
- App version and schema version set
- Changelog complete
- Seed data reviewed
- First Admin bootstrap documented
- Rollback/mitigation plan ready
- Support diagnostics verified
