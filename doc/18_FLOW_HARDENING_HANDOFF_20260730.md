# FactoryFlow Flow Hardening Handoff

Date: 2026-07-30
Branch: `codex/production-v3-checkpoint`
Status: Local implementation complete for this slice; controlled server rollout
and device acceptance remain.

## Outcome

The Production blank-page failure is handled at its source. Legacy accounts
with multi-machine mode enabled but an empty machine sequence are repaired from
the active machine order. An invalid route cannot post stock, and the screen
shows route, raw/WIP availability, loading failures, and zero-stock guidance.

The connected stock flow now follows:

`Material Receive -> Production/WIP -> BP -> Faco -> AP -> RTV/Approved -> Final Dispatch`

Every changed local stock action writes its business event, ledger movements,
and sync queue inside one SQLite transaction. A failed event, ledger movement,
or queue write rolls the whole action back and shows a non-destructive error.

## Completed local work

- Production route readiness, legacy repair, stock visibility, and repository
  guard.
- Factory-scoped Material Receive and Purchase Order update.
- Factory-scoped BP inspection and Faco dispatch.
- Cumulative partial Faco receive with over-receipt blocking.
- AP equation: `Approved + Rejected = Checked`; `RTV <= Rejected`.
- RTV candidate assignment without double-consuming stock.
- Partial/full RTV return and reinspection:
  `OK + Reject Again = Received`.
- Reject-again quantity becomes eligible for the next cycle.
- Third-cycle rejection becomes `escalated`.
- Admin/Owner resolution requires a reason and posts either Scrap or approved
  dispatch override with an audit record.
- Final Dispatch aggregates duplicate part rows before checking stock.
- BP requires a matching Production batch/part/machine; Faco dispatch only
  offers BP-inspected batch balances; AP consumes the original Faco-return
  batch; and each Final Dispatch item stores that same batch number.
- Downtime and manual stock adjustment are transaction-safe.
- Reports, live stock, ledger, Faco pending, dispatch report, and global search
  use active factory scope and the current dispatch session/item schema.
- Update sync operations require both record ID and factory ID.
- Connectivity checks are bounded and injectable for deterministic tests.
- Read-only local reconciliation tool:
  `dart run tool/inspect_local_database.dart <database-path>`.

## Verification

- Production-focused suites: 15 tests passed before this continuation.
- Transaction/report suites: 8 tests passed before this continuation.
- Total previously executed targeted tests: 23 passed.
- Added three RTV tests covering assignment/no double-use, partial return stock
  split, and third-cycle Admin resolution/idempotency.
- Direct Dart analysis of all changed core and flow files reports no syntax or
  type errors. Remaining findings are existing style infos and one unused
  legacy Production layout method.
- `git diff --check` passes.
- Flutter test/device rerun is pending because the laptop Flutter launcher
  hangs even on `flutter --version`. Android/Gradle configuration was not
  changed to work around that machine issue.

## Hosted Supabase rollout pending approval

`supabase/sync_schema_alignment.sql` is prepared but not applied. It is
forward-only and preserves existing history. It adds:

- `purchase_orders`, `ap_rejected_actions`, `dispatch_sessions`, and
  `dispatch_items`;
- missing Material Receive and AP RTV columns;
- Final Dispatch and operational indexes;
- quantity constraints;
- RLS/grants for new tables;
- scoped RTV update policies for Quality Inspector and Admin;
- server authorization mapping where stored role `owner` has Admin authority.

The live server currently has an `owner` user but its role helper returns
`owner`, while existing write policies expect `Admin`. Until the prepared
migration is explicitly approved and applied, an Owner's local entries can
remain queued and fail hosted RLS authorization.

Read-only hosted reconciliation on 2026-07-30 found 3 Production rows and 3
total ledger rows, but all 3 Production rows still have no ledger row linked by
`ref_table = productions` and `ref_id`; there are no orphan Production ledger
rows. The existing ledger rows therefore do not make Production reconciliation
complete.

## Release blockers that remain

1. Product Owner explicitly approves the hosted Supabase migration.
2. Apply it through migration tooling, record the returned migration version,
   and verify constraints, RLS, grants, and advisors.
3. Reconcile trusted device ledger rows with hosted Production history before
   enabling atomic Production sync. Do not invent/backfill balances from event
   rows alone.
4. Convert non-Production hosted event plus ledger fan-out to idempotent atomic
   server commands. Local atomicity is complete; hosted cross-table atomicity
   is not yet complete.
5. Run the full Flutter suite and connected-device golden workflow when the
   local Flutter launcher is healthy.
6. Complete conflict review/dependency ordering and the separately approved
   SQLite-to-Drift architecture decision.

## Safe next action

After explicit approval, apply and verify the prepared hosted migration. Then
run the local reconciliation export against the trusted phone database before
changing `ATOMIC_PRODUCTION_SYNC_ENABLED`.
