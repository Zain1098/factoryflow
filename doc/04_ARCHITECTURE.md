# FactoryFlow Technical Architecture

## 1. Stack
- Flutter/Dart Android application
- Riverpod for dependency injection and state management
- Drift/SQLite for relational offline storage
- Supabase Auth, Postgres, Storage, Realtime where useful
- Clean Architecture with feature-first modules

## 2. Layers
### Presentation
Screens, widgets, form controllers, view state, navigation. No SQL, no stock rules.

### Application
Use cases/commands/queries, validation orchestration, permissions checks for UX, transaction coordination.

### Domain
Entities, value objects, statuses, business invariants, domain services, typed failures.

### Data
Repository implementations, local Drift DAOs, Supabase data sources, DTO mapping, sync queue.

### Infrastructure
Connectivity, secure storage, device identity, logging, clock, file compression, photo upload, background scheduling.

## 3. Feature modules
`auth`, `dashboard`, `masters`, `material_receive`, `production`, `downtime`, `bp_inspection`, `faco_dispatch`, `faco_receive`, `ap_inspection`, `rtv`, `final_dispatch`, `stock`, `search`, `reports`, `notifications`, `corrections`, `audit`, `sync`, `settings`, `diagnostics`, `reconciliation`.

## 4. Recommended folder structure
```text
lib/
  app/
  core/
    database/
    errors/
    network/
    security/
    sync/
    utilities/
  features/
    production/
      domain/
      application/
      data/
      presentation/
```

## 5. Command/query separation
Writes are commands with validation and idempotency. Reads are queries optimized for screens and reports. Dashboard uses local projections/materialized read models rather than expensive joins on every rebuild.

## 6. Stock posting
A stock-changing use case posts one atomic business operation:
1. Validate role and fields.
2. Validate available balance.
3. Insert business event.
4. Insert balanced ledger movement(s).
5. Update local projection.
6. Add sync queue item in the same local database transaction.

Server repeats validation atomically in a Postgres function/transaction. Client calculations are not trusted for final server balances.

## 7. Offline-first flow
UI -> application command -> local transaction -> optimistic UI -> queue -> sync worker -> server RPC -> acknowledgement/conflict -> local status update.

## 8. Sync model
Use push-first for queued mutations, then pull changes using server sequence or `updated_at` cursor. Do not use last-write-wins for stock-changing transactions. Master data can use controlled server-authoritative merging.

## 9. Read models
Maintain local read models for dashboard balances, pending queues, batch timeline summaries, and report filters. Rebuild tools are available for diagnostics but not normal operation.

## 10. Navigation
Use typed routes. Role guards prevent unauthorized routes. Deep links from notifications verify permission before opening.

## 11. Error model
Use typed categories: Validation, Permission, InsufficientStock, Conflict, Network, Authentication, Storage, Server, Unexpected. UI messages remain actionable and preserve unsaved input.

## 12. Logging
Structured logs with event name, user, factory, device, record UUID, sync attempt, and safe error details. Never log passwords, tokens, service keys, or sensitive photo URLs.

## 13. Performance
- Index common filters.
- Paginate lists.
- Avoid N+1 queries.
- Cache master dropdowns locally.
- Debounce search.
- Perform heavy export/image work off the UI isolate.
- Keep dashboard query count small and measured.

## 14. Extensibility
Use stable domain statuses and IDs so web/iOS clients and APIs can be added later. Do not introduce a generic workflow engine in Phase 1.
