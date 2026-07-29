# FactoryFlow Business Rules

## BR-001 Ledger is authoritative
Current stock is derived only from posted ledger movements. Transaction tables describe business events; ledger rows describe stock effect.

## BR-002 No negative balance
No online or offline-approved mutation may cause a stage balance below zero. Offline mutations that conflict at server validation enter Conflict state and require review.

## BR-003 Immutable posted history
Posted stock-changing transactions are never edited in place after the allowed same-day correction window. Corrections create reversal and replacement events.

## BR-004 No hard delete
Transactions use void/cancel/correction status and retain audit history. Master data may be deactivated, not deleted when referenced.

## BR-005 Batch traceability
Every production output unit is associated with a batch number that remains stable through inspections, vendor movement, RTV, dispatch, scrap, and correction.

## BR-006 Machine sequence
Normal sequence is Bending -> Notching -> End Forming. A downstream production entry consumes available upstream WIP. Partial quantities and multiple entries are allowed.

## BR-007 Multi-part and partial-day support
The system never assumes one part per day or all machines active. Targets and calculations are per part, date, and relevant stage.

## BR-008 Quality quantities
- Production BP self-reject <= production quantity.
- Formal BP reject <= quantity inspected.
- AP approved + AP rejected = AP quantity checked.
- RTV reinspection OK + reject again = quantity received.

## BR-009 Vendor movement
Dispatch to Faco cannot exceed BP-approved stock. Receive may be partial. A dispatch may have multiple receives. Shortage remains open and reportable.

## BR-010 RTV
Cumulative RTV quantity cannot exceed AP-rejected quantity available for RTV. Maximum automatic cycle is 3. Further action requires Admin decision with mandatory reason.

## BR-011 Final dispatch
Final dispatch cannot exceed AP-approved stock. Customer is required. Vehicle, driver, and challan are optional.

## BR-012 Drafts
Drafts do not create ledger movements, consume stock, trigger notifications, or appear in operational reports.

## BR-013 Idempotency
Submitting or retrying the same client mutation more than once must produce one business transaction and one logical ledger effect.

## BR-014 Same-day correction
Creator role may correct an entry on the same factory date when permitted. Every change is audit logged. After rollover, correction request approval is mandatory.

## BR-015 Physical reconciliation
Physical count does not overwrite system stock. Variance is recorded. Approved adjustment posts a separate adjustment transaction and ledger movement.

## BR-016 Targets
Targets come from Target Master by part and day-of-week/effective period. Missing target is an Admin configuration warning, not zero production.

## BR-017 Time and timezone
Business dates use factory timezone. Server timestamps are stored in UTC. Local display uses configured factory timezone.

## BR-018 Master data
Referenced master records cannot be deleted. Inactive records remain visible on historical transactions but are hidden from new-entry dropdowns by default.

## BR-019 Photos
Photos are optional unless a later approved policy makes them mandatory for a specific reject category. Photo failure never blocks the underlying transaction.

## BR-020 Reports
Stock reports use ledger/projection. Operational reports use posted events. Draft, voided, and rejected conflicts are excluded unless a report explicitly requests them.

## BR-021 Security context
Every record is scoped by factory_id and authorized role. Client UI convenience does not grant permission.

## BR-022 Notifications
Notifications are derived alerts, not authoritative data. Dismissing an alert never changes a transaction.

## BR-023 Data retention
Audit logs, correction history, and posted ledger events are retained for the product lifetime unless a formal retention policy is approved.
