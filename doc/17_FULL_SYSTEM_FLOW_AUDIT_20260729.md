# FactoryFlow Full System Flow Audit

Date: 2026-07-29  
Status: Active Gate 0 audit  
Scope: Flutter client, local SQLite data flow, sync queue, live Supabase baseline,
Android build, connected TECNO CG6j smoke test, and current automated tests.

## 1. Executive result

The app launches, the Dashboard and Entries navigation work, and Daily Production
now renders and opens its machine-entry form on the target phone without the
previous semantics, infinite-width, or RenderFlex errors.

The full business system is not release-ready yet. Production is currently the
only stock-changing module with an atomic local event + ledger + queue
transaction and a deployed atomic server RPC. Other stock-changing modules can
still leave partial local state if a ledger, event, or queue write fails.

The highest remaining P0 risks are:

1. Reconcile the trusted phone ledger with the empty live server ledger before
   enabling atomic production sync.
2. Make every stock-changing module atomic and idempotent.
3. Align Final Dispatch local tables with the live server schema.
4. Factory-scope reports, searches, and remaining operational queries.
5. Complete conflict review, dependency ordering, versioned local migrations,
   and the approved Drift migration decision.

## 2. Verification evidence

- Connected device: TECNO CG6j, 720 x 1600, Android package
  `com.proflow.factoryflow`.
- Fresh debug APK built and installed with existing app data preserved.
- Daily Production opened, part selected, and Add Machine Entry opened.
- Form was scrolled through its responsive lower section.
- Filtered device logs contained no Flutter assertion, BoxConstraints,
  RenderFlex, semantics, or fatal exception during the verified flow.
- Full Flutter suite: 13 tests passed.
- Targeted Dart analysis found no errors in the changed slice. Repository-wide
  analysis still has pre-existing warning/info debt and the Flutter analyzer
  wrapper can exceed the current execution timeout.
- Live Supabase: 3 production rows, 0 stock-ledger rows, 3 production events
  without ledger rows, 0 duplicate production-stage groups, 0 negative latest
  balances, and 2 active workspace memberships.
- Live database has RLS enabled on all listed public operational tables.
- Supabase advisors currently report 25 security notices and 155 performance
  notices. The security set includes 11 anonymous-executable SECURITY DEFINER
  functions and disabled leaked-password protection.

## 3. Flow connection matrix

| Flow | Current connection | Health | Main gap |
|---|---|---:|---|
| Auth -> workspace -> local masters | Active workspace scopes master reads | Partial | Local/server workspace migration and role tests remain |
| Material Receive -> Raw Material | Event and ledger exist | At risk | Event, ledger, PO status, and queue are not one transaction |
| Raw Material -> Production/WIP -> BP stock | Atomic locally; server RPC deployed | Gated | Server ledger baseline is empty; rollout flag must stay off |
| BP Inspection -> BP rejected/available BP | Ledger movement exists | At risk | Non-atomic; inspected/approved quantity model is incomplete |
| BP stock -> Faco dispatch | Ledger transfer exists | At risk | Non-atomic and some batch/factory reads are unscoped |
| At Faco -> Faco receive -> Pending AP | Ledger transfer exists | At risk | Partial receives are not reconciled cumulatively; over-receive cap missing |
| Pending AP -> AP approved/rejected/RTV | Split ledger exists | Conflict | Current equation includes RTV separately, diverging from BR-008 |
| AP reject -> RTV -> return/reinspection | RTV outbound exists | Incomplete | Return/reinspection/Admin cycle-resolution flow is missing |
| AP approved -> Final Dispatch | Local session/item ledger exists | Blocked | Live server has `final_dispatches`, not local `dispatch_sessions/items` |
| Ledger -> Dashboard | Central reads now factory-scoped | Improved | Projection/read-model and performance proof remain |
| Events/Ledger -> Reports/Search | Screens exist | At risk | Report provider has no active factory filter; search audit remains open |
| Local queue -> Supabase | Retry/backoff and production conflict handling exist | Partial | Dependency graph and complete conflict-review records are absent |

## 4. Changes completed in this audit slice

### Daily Production reliability

- Machines and operators now start loading while the production screen is open,
  rather than restarting as an unwatched FutureProvider on every button tap.
- Add Machine Entry stays disabled with an honest loading/error state until its
  required masters are ready.
- Shared dropdowns use bounded expanded width.
- The automatic good-output row reflows on narrow devices.
- A widget test now selects a part and opens the real machine-entry form.

### Factory-safe stock and dashboard calculations

- Latest part/stage balance, stage totals, per-part balances, all-stage totals,
  daily production summary, daily target, and target list are scoped to the
  active factory.
- Dashboard production, rejection, dispatch, machine, downtime, weekly trend,
  and pending-correction reads are scoped to the active factory.
- Dashboard final-dispatch total now reads the local session/item model that the
  current Final Dispatch feature actually writes.
- A two-factory characterization test proves that the same part/stage cannot
  leak the other factory's latest balance.

### Android dependency/build health

- `share_plus` upgraded from 12.0.2 to 13.3.0.
- `flutter_secure_storage` upgraded from 9.2.4 to 10.3.1 to keep the shared
  `win32` dependency compatible.
- The final AGP 9 debug build completed without the previous plugin-applied KGP
  warning.

## 5. UX and accessibility audit

### Confirmed strengths

- Daily Production has a clear title, shift selector, part context, progressive
  machine entry, automatic good quantity, and one primary add action.
- Stock movement copy explains input/output locations and rejection behavior.
- Disabled states prevent premature save and duplicate taps.
- The narrow production form now fits the target device without clipped
  dropdowns or calculation rows.

### Risks and opportunities

- The part picker is a large untitled bottom sheet with no search or selected
  state. It should use a compact searchable master picker.
- The Dashboard machine cards expose a partially visible third card. A clear
  horizontal-scroll affordance or responsive wrap is needed.
- Some copy is inconsistent, for example `Machines Running status`; user-facing
  strings are not yet centralized for future Urdu localization.
- Sync state is not visible on every operational form as required by the UX
  rules.
- Accessibility was visually checked for clipping and touch layout only.
  TalkBack reading order, semantic labels, text scaling, and contrast still need
  dedicated device tests.

## 6. Data, security, and rollout constraints

- No live business data was changed during this audit.
- No server migration was applied.
- `ATOMIC_PRODUCTION_SYNC_ENABLED` must remain false until ledger reconciliation
  proves a valid server opening balance.
- The live production rows must not be auto-backfilled from event tables alone;
  the trusted phone ledger and pending queue are required to prevent invented
  balances.
- Supabase SECURITY DEFINER grants need a separate function-by-function
  authorization migration. Authenticated execution of the two intentional stock
  RPCs is expected; anonymous execution is not.
- The secure-storage major upgrade preserves the existing Flutter API used by
  the app, but authentication/session recovery needs a device login/logout
  regression before release.

## 7. Ordered next work

1. Add a read-only ledger reconciliation diagnostic/export showing local latest
   balances, pending ledger/production commands, and matching server balances.
2. Review that report with the Product Owner; create explicit opening-balance
   or replay migrations only from proven source records.
3. Enable atomic production sync behind the existing flag and test offline
   replay/conflict behavior.
4. Make Material Receive atomic locally and add server-side idempotent posting.
5. Continue the same vertical-slice pattern through BP, Faco, AP, RTV, and Final
   Dispatch.
6. Resolve the Final Dispatch table-model mismatch before testing full
   production-to-customer flow.
7. Factory-scope reports/search, then add the full golden business-flow tests.

## 8. Rollback

This slice has no schema or live-data mutation. If a regression is found, revert
the code/dependency commit and reinstall the previous debug APK. Do not erase
the phone database because unsynced local records may be the only trusted stock
evidence.
