# Database and Sync Rules

## 1. Identifiers
All records use UUID primary keys generated client-side where offline creation is possible. Human batch numbers are unique business identifiers, not primary keys.

## 2. Common columns
Transactional tables should include: id, factory_id, status, business_date, created_at_utc, updated_at_utc, created_by, device_id, client_mutation_id, sync_version, voided_at, voided_by where relevant.

## 3. Essential groups
- Masters: factories, profiles/users, roles, parts, machines, operators, shifts, suppliers, vendors, customers, vehicles, drivers, reasons, targets, alert settings.
- Operations: material_receive, production, downtime, bp_inspection, faco_dispatch, faco_receive, ap_inspection, rtv, rtv_reinspection, final_dispatch, stock_adjustment.
- Integrity: stock_ledger, stock_balance_projection, batch_links, correction_requests, audit_log.
- Offline: sync_queue, sync_attempts, sync_conflicts, app_metadata, draft_forms.
- Support: notifications, photo_attachments, export_history, physical_counts.

## 4. Ledger shape
Each row represents a single signed movement for one part/stage and references its source event. Recommended fields: id, factory_id, part_id, batch_id/batch_number, stage, quantity_delta, event_type, source_table, source_id, event_sequence, business_date, created_at_utc, reversal_of_id, idempotency_key.

A unique constraint on `(factory_id, idempotency_key)` prevents duplicate effect.

## 5. Balance strategy
Server balance is derived through atomic posting and maintained in a projection table for fast reads. Ledger remains auditable source. Projection can be rebuilt from ledger.

## 6. Database constraints
Use check constraints for non-negative quantities and quantity equations. Use foreign keys for all references. Use partial unique indexes for active mutation IDs and batch sequences. Use database functions/triggers only where they centralize integrity clearly and are covered by tests.

## 7. RLS
Every table with factory data has RLS enabled. Policies derive user identity from `auth.uid()` and a profile/membership table. Users can access only their factory and allowed actions. Service role is server-only.

## 8. Migrations
- Every schema change is a numbered migration.
- Never edit an already-deployed migration.
- Migrations are forward-safe and non-destructive by default.
- Add nullable/backfill/enforce pattern for new required fields.
- Local Drift schema version and server migration are documented together.
- Provide rollback or mitigation notes.

## 9. Sync queue states
DRAFT, PENDING, SYNCING, SYNCED, RETRY_WAIT, FAILED, CONFLICT, CANCELLED.

Queue item includes operation, entity_type, entity_id, payload_json, idempotency_key, dependency_ids, attempt_count, next_attempt_at, last_error_code, created_at, updated_at.

## 10. Retry policy
Exponential backoff with jitter. Authentication errors pause and request login. Validation and insufficient-stock responses become Conflict, not infinite retry. Temporary network/server errors retry. A manual retry action remains available.

## 11. Dependency ordering
A child mutation cannot sync before required master or parent records. Queue supports dependencies and topological ordering. Photos sync after the parent event and do not block it.

## 12. Conflict handling
Conflict record stores local payload, server reason, relevant current server state, suggested actions, reviewer, and resolution. Resolution options are domain-specific: cancel local entry, correct quantity, map missing master, or submit correction request. Never silently merge stock events.

## 13. Pull synchronization
Use monotonic server change sequence or a reliable cursor. Pull is factory-scoped and paginated. Tombstones/void statuses are synced so local data does not resurrect deleted/deactivated records.

## 14. Backup and recovery
Supabase managed backups cover server. Local database is recoverable by resync after login, but unsynced records require encrypted app backup/export only if a future policy approves it. Diagnostics must warn before logout/reset when unsynced records exist.

## 15. Index baseline
Indexes on factory_id plus common filters: business_date, part_id, batch_number, status, machine_id, operator_id, vendor_id, customer_id, source_id, created_at. Verify with query plans for high-volume reports.
