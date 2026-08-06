# Settings Audit and Hardening - 2026-07-30

## Update - 2026-08-06: Settings sync repair

The settings/sync failure path was repaired after a code scan found that
background sync exceptions could escape into the Flutter error surface, manual
sync could report success while records had failed, and the pending queue was
not consistently scoped to the active workspace.

### Implemented in the app

- Native and web queues now keep only the latest pending update for a local
  record, reducing duplicate replay after long offline sessions.
- Pending queue reads and counts are filtered by the active workspace. A queue
  item whose workspace no longer matches is recorded as a conflict instead of
  being sent under the current account.
- Supabase insert, update, and delete operations now request the affected row
  and reject empty results. Deletes include the workspace filter.
- Background and reconnect sync failures are contained and logged instead of
  bubbling into a settings/error page.
- Missing workspace IDs now produce a recoverable save message rather than a
  silent queue drop.
- Web preview mode now maintains a functional in-memory sync queue instead of
  reporting a permanently empty queue.
- Settings master-data actions show a compact local-save/remove confirmation
  or a user-friendly retry message. Raw Supabase/SQL exception text is no
  longer shown in the main master-data screens.
- Production-flow preference writes roll back in-memory state when the local
  preference write fails.
- Sync status copy now describes local-first behavior without claiming that
  every platform uses native SQLite.

### Verification boundary

`git diff --check` passed. Dart formatting and targeted Flutter analysis were
attempted on 2026-08-06 but timed out because of the existing Dart/Flutter
process hang on this laptop. No analyzer or device-runtime pass is claimed
until a fresh Flutter process completes those checks.

Remote Supabase migration history, RLS behavior, Edge Function deployment,
and a real online/offline device CRUD flow still require post-push validation.
The app changes are local code changes until that remote/device verification is
completed.

## Scope

Combined functional, UX, permission, offline, and data-safety review of the
FactoryFlow Settings flow. The installed app was inspected on the connected
TECNO device, and each option was traced through Flutter providers, SQLite,
the sync queue, and the hosted security model.

The captured device screens show the previously installed build. They confirm
the real mobile hierarchy and touch layout, but the new labels and controls
require a new app build/install before visual confirmation.

## Device flow health

1. Settings entry and profile: healthy. The destination is discoverable from
   bottom navigation and the profile card clearly exposes account settings.
2. Factory setup and master data: usable but overexposed in the installed
   build. Non-Admin roles could see controls they were not allowed to use.
3. App settings: visually clear. Theme and batch display settings persist.
   Biometric enable previously did not prove authentication first.
4. System controls: functionally mixed. Sync status was useful, but Stock
   Management was unreachable and destructive controls needed stronger
   factory isolation.
5. Account exit: account deletion was explicit, but normal sign-out did not
   warn about unsynced device work.

## Completed hardening

- Factory Setup, Master Data, Correction Requests, Stock Management, and Erase
  Local Data are visible only to Admin/Owner.
- Customers and Stock Management are now reachable from Settings.
- Vendor and Vehicle edit actions update the selected item.
- Master update, reorder, and deactivate actions queue scoped cloud updates.
- New master inserts use boolean values for the Supabase `active` field.
- Live migration `20260730182909_admin_only_master_writes` restricts writes on
  all eight master tables to Admin/Owner and revokes anonymous master writes.
- Biometric lock requires successful authentication before it is enabled.
- Notification delivery reads the master, sound, vibration, sync, production,
  and downtime preferences saved by Settings.
- Sign-out warns when pending sync mutations exist.
- Backup, record counts, local erase, and sync-queue cancellation operate only
  on the active factory.
- Regression tests cover two-factory erase and queued-mutation isolation.

## Remaining product gaps

These are real missing capabilities, not buttons that should be added without
their backend:

1. Company profile and shared-company member/role management.
2. Configurable shifts and BP/AP/RTV reject-reason masters; some flows still
   use code constants.
3. Workspace export/import and encrypted recovery policy.
4. Dynamic installed-version/build information instead of hardcoded `v1.0.0`.
5. Alert producers for target miss, low stock, pending RTV, and downtime.
   Preference enforcement exists, but most business events do not yet trigger
   these notifications.
6. Remote account hard deletion/admin cleanup. Current mobile flow deactivates
   the app profile and clears local access; it cannot securely delete the
   Supabase Auth identity by itself.
7. Split the large Settings implementation into bounded feature files after
   behavior is stable. This is maintainability work, not a reason to rewrite
   its working state management.

## Verification

- Direct Dart formatting completed for all changed Dart files.
- Targeted Dart analysis found no errors in the new Settings, master-data,
  notification, or erase-safety code.
- The master-write migration passed rollback-only checks: the Owner updated
  three own-factory test rows, while an unaffiliated identity updated zero.
  Post-deployment policies are authenticated-only, include the Admin guard,
  and all existing master row counts are unchanged.
- The new test file compiles and starts loading, but this laptop's existing
  Dart/Flutter build-hook runner stalled before executing the tests.
- Device screenshots were inspected and accepted for the installed build.

## Exact next safe task

Build and install the changed app when the laptop Flutter launcher is healthy,
then repeat the role matrix on-device:

- Owner/Admin sees and can use factory controls.
- Production, Store, Quality, and Management roles see only personal/system
  controls allowed to them.
- Create, edit, reorder, and deactivate one test master online and offline.
- Verify the queue syncs without duplicate or cross-factory effects.
