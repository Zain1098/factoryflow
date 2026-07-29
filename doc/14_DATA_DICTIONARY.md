# Canonical Data Dictionary

## Terms
- BP: Before Plating quality stage.
- AP: After Plating quality stage.
- Faco: plating vendor default name; system supports multiple vendors.
- RTV: Return to Vendor.
- WIP: Work in Progress between machine stages.
- Posted: finalized event that affects ledger.
- Draft: local incomplete form with no stock effect.
- Conflict: server rejected/blocked mutation requiring review.
- Void: business cancellation represented without deleting history.
- Correction: approved reversal plus replacement.

## Stock stages
RAW_MATERIAL, BENDING_WIP, NOTCHING_WIP, END_FORMING_WIP, BP_AWAITING_INSPECTION, BP_APPROVED, AT_FACO, AP_AWAITING_INSPECTION, AP_APPROVED, RTV_OUTSTANDING, SCRAP, DISPATCHED.

## Transaction statuses
DRAFT, POSTED, VOIDED, CORRECTION_PENDING, CORRECTED.

## Sync statuses
LOCAL_DRAFT, PENDING, SYNCING, SYNCED, RETRY_WAIT, FAILED, CONFLICT, CANCELLED.

## RTV statuses
OPEN, SENT, PARTIALLY_RECEIVED, RECEIVED, REINSPECTION_PENDING, APPROVED, REJECTED_AGAIN, ESCALATED, SCRAPPED, FORCE_DISPATCHED, CLOSED.

## Quantity rule
Use integer quantities for PCS. Decimal quantities are permitted only when part UOM explicitly supports them.

## Batch format
`{PartCode}-{YYYYMMDD}-{MachineSeq}-{Sequence}`. Example: `V21-20260711-B-001`.
