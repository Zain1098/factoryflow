# Flutter and Backend Coding Standards

## Dart
- Use sound null safety and strict analysis.
- Prefer immutable models and `final` fields.
- No `dynamic` in domain/data contracts unless isolated and validated.
- Use explicit result/error types for expected failures.
- Keep functions small and single-purpose.
- Use UTC timestamps internally and factory date services for business dates.

## Riverpod
- Providers represent dependencies or screen/use-case state, not random global variables.
- Avoid database/network calls directly from widgets.
- Dispose family/temporary providers appropriately.
- Keep side effects in controllers/notifiers/use cases.

## Forms
- Separate draft state from posted entity.
- Validate locally before command submission.
- Preserve form input on navigation/error when safe.
- Disable double submit and rely on idempotency as a second defense.

## Data access
- Repositories expose domain operations, not raw table access to UI.
- DAOs use parameterized queries.
- Batch related database writes in transactions.
- Avoid N+1 queries; prefetch or join intentionally.

## Naming
- Classes: PascalCase
- variables/functions/files: lower_snake_case for files, lowerCamelCase for symbols
- IDs: `<entity>Id`
- quantities: explicit unit or domain meaning, e.g. `approvedQty`
- timestamps: `createdAtUtc`; dates: `businessDate`

## Security
- Secrets never shipped in source/assets.
- Supabase anon key is allowed; service-role key is forbidden in client.
- Tokens stored using secure storage where applicable.
- Authorization verified server-side.

## Tests
- Domain invariants use unit tests.
- Repositories and Drift use integration tests.
- Critical screens use widget tests.
- Full stock flows use end-to-end tests.

## Comments and documentation
Comment why, not what. Public domain services and complex posting logic require concise documentation. No misleading stale comments.

## Formatting and lint
Run formatter and analyzer on every change. New warnings are not accepted. Avoid broad lint suppression.

## Git practices
Small commits with clear intent. Schema, code, tests, and docs for one change belong together. Never mix unrelated refactors with a bug fix.
