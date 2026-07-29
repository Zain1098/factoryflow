# FactoryFlow Product Requirements Document v3.0

## 1. Product vision
FactoryFlow is an offline-first Android manufacturing ERP for recording production, quality inspection, material movement, vendor plating, rejection, RTV, stock, dispatch, downtime, and traceability with minimal typing and no manual stock calculation.

The app is not a generic inventory app. Its core is a transaction-driven stock ledger and batch history.

## 2. Primary outcomes
- Daily operational entry completed in less than 5 minutes for normal work.
- Current stock visible at every stage.
- Every movement traceable by part, batch, date, machine, operator, and user.
- No negative stock and no silent data loss.
- Reports generated from trusted ledger and event data.
- App remains usable without internet.

## 3. Users and roles
- Admin: full configuration, user management, approvals, escalation resolution, audit access.
- Production Incharge: production, downtime, same-day corrections, dashboard and reports.
- Store: material receipt, vendor dispatch/receive, final dispatch, stock view.
- Quality Inspector: BP/AP inspections, RTV, reinspection, reject photos.
- Management: read-only dashboard and reports.
- Operator: master-data entity only, never a login role.

## 4. Canonical workflow
Raw Material Receive -> Bending -> Notching -> End Forming -> BP Inspection -> Dispatch to Faco -> Receive from Faco -> AP Inspection -> Approved AP Stock -> Final Dispatch.

AP reject path: AP Rejected -> RTV -> Receive RTV Back -> Reinspection -> Approved or RTV Again. Maximum automatic RTV cycles: 3, followed by Admin decision.

## 5. Phase 1 modules
1. Authentication and role-based access
2. Dashboard
3. Material Receive
4. Production Entry
5. Machine Downtime
6. BP Inspection
7. Dispatch to Faco
8. Receive from Faco
9. AP Inspection
10. RTV Management
11. RTV Reinspection
12. Final Dispatch
13. Global Search and Batch Timeline
14. Reports
15. Notifications and actionable alerts
16. Correction Requests and Audit Log
17. Master data seeding and limited Admin configuration
18. Offline queue, sync status, retry, and conflict review
19. Photo attachments
20. Backup/export and diagnostics

## 6. Improved features added in v3.0
### 6.1 Batch timeline
A single screen shows the complete history of a batch: production stages, inspection, vendor movements, RTV cycles, final dispatch, corrections, users, timestamps, and photos.

### 6.2 Draft and resume
Long forms can be saved as local drafts automatically. Drafts never affect stock until submitted.

### 6.3 Favorites and smart defaults
The app remembers last-used part, machine, operator, vendor, customer, and shift per user and module. Defaults accelerate entry but never bypass validation.

### 6.4 Shift handover summary
A generated summary shows production, rejects, open downtime, pending vendor material, pending inspection, and unresolved sync conflicts for the next shift.

### 6.5 Physical stock reconciliation
Authorized users can record a physical count. The system shows variance but does not overwrite ledger balance. Adjustment requires Admin approval and creates explicit adjustment ledger entries.

### 6.6 Data-quality dashboard
Admin sees missing masters, duplicate warnings, unsynced records, unresolved conflicts, unusual reject ratios, overdue RTV, and broken batch links.

### 6.7 Controlled exports
Reports may be exported to CSV/PDF with role checks, filters, generation timestamp, factory, and user name. Export is not a substitute for ledger data.

### 6.8 Configurable alert thresholds
Low stock, high reject rate, vendor delay, downtime duration, and target miss thresholds are stored as configuration, not hardcoded.

### 6.9 Device diagnostics
Settings show app version, database version, last successful sync, pending queue count, failed queue count, authenticated user, factory, and connection status.

### 6.10 Idempotency and duplicate safety
Every mutation uses a client-generated UUID and idempotency key so retries cannot create duplicate stock movements.

## 7. Dashboard requirements
Dashboard reads precomputed/current balances from the ledger projection, never live-summing all transaction tables.

Cards:
- Raw Material
- Bending WIP
- Notching WIP
- End Forming/BP Awaiting Inspection
- BP Approved
- At Faco
- Returned Awaiting AP
- AP Approved
- RTV Outstanding
- Final Dispatch Today

KPIs:
- Production vs target
- Machine utilization
- BP reject rate
- AP reject rate
- Vendor turnaround time
- Open downtime
- Unsynced/failed records
- Data-quality alerts

Filters: factory, date, shift, part. Phase 1 has one factory but all queries remain factory-scoped.

## 8. Reports
- Daily, weekly, monthly production
- Part-wise, machine-wise, operator-wise production
- Target achievement
- Machine utilization and downtime
- BP/AP reject analysis by reason
- RTV aging, cycles, and resolution
- Vendor turnaround, shortage, quality, and pending stock
- Current stock by stage
- Inventory movement ledger
- Batch genealogy/timeline
- Dispatch report
- User activity and correction report
- Physical reconciliation variance
- Sync health and data-quality report for Admin

## 9. Search
Search by batch number, part, machine, operator, vendor, customer, PO, challan, date range, status, and free-text remarks where indexed safely. Results must clearly identify entity type and open the correct detail screen.

## 10. Notifications
- Daily target missed
- Machine breakdown exceeding threshold
- RTV overdue
- Faco return delayed
- Low stock
- High reject rate
- Sync conflict or repeated sync failure
- Pending correction approval
- Open downtime at shift end

Notifications must deep-link to the relevant record or filtered list.

## 11. Offline behavior
All operational entry screens work offline. Authentication may use cached session within allowed expiry. New data is stored locally first, then synced. The UI always displays one of: Local Draft, Pending Sync, Syncing, Synced, Conflict, Failed.

## 12. Non-goals for Phase 1
- Payroll, accounting, procurement approval chain, HR, maintenance spare-parts ERP
- iOS app
- Web management dashboard
- Active QR/barcode scanning
- AI prediction affecting stock or automatic quality decisions
- Fully configurable workflow engine
- Multi-factory Admin UI

## 13. Future roadmap
- QR/barcode scanning
- Web dashboard
- iOS build
- Predictive maintenance
- AI-assisted anomaly detection and reject pattern explanation
- Supplier/customer portal
- Multi-factory configuration
- OEE and advanced capacity planning
- Integration with ERP/accounting systems through stable APIs

## 14. Success criteria
- Normal daily entries under 5 minutes.
- 99%+ data accuracy against physical reconciliation.
- No transaction silently lost.
- No duplicate ledger effect after retries.
- Search returns common queries under 1 second locally and 2 seconds remotely.
- Dashboard opens under 2 seconds with cached local data.
- Any batch history retrievable within 5 seconds.
- All stock-changing actions are auditable.
