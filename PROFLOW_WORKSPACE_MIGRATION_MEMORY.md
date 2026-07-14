# ProFlow Workspace Migration Memory

Last updated: 2026-07-14 (Session 4 — Back Button + Sync + Settings Fixes)

## Goal

Move ProFlow away from a fixed admin/role/default-factory app into a professional workspace/company model.

Target behavior:
- Any normal user can create an account and log in.
- New signup gets a fresh private workspace/company automatically.
- User can add their own parts, machines, operators, suppliers, vendors, customers, and transaction data.
- Data is always scoped to that user's active workspace/company.
- Future: export/import workspace snapshot, shared live workspace with role-based permissions.
- Future: owner/admin dashboard (service-role backend, not mobile app).

## Current Code State — ALL CORE WORK COMPLETE

### Key files:
- `lib/features/auth/auth_providers.dart`: signIn (sets activeWorkspaceId on login), signUp (creates workspace+profile via RPC), getLocalSession, signOut.
- `lib/features/auth/login_screen.dart`: sign-in + sign-up UI with toggle. Sign-up collects name, workspace name, email, password.
- `lib/core/models/app_user.dart`: AppUser with factoryId (= workspaceId) and role.
- `lib/core/constants/user_roles.dart`: owner, admin, productionIncharge, store, qualityInspector, management. owner has full access same as admin.
- `lib/core/providers/master_data_providers.dart`: all insert/update methods use `_db.activeWorkspaceId`. All update payloads now include `factory_id`. syncMasterDataFromSupabase uses activeWorkspaceId.
- `lib/core/database/database_service_native.dart`: workspaces + workspace_members tables. activeWorkspaceId getter (returns '' if not set). setActiveWorkspaceId. All read queries filter by activeWorkspaceId. writeAuditLog uses activeWorkspaceId.
- `lib/core/services/stock_ledger_service.dart`: uses `_db.activeWorkspaceId` for all ledger writes and sync payloads.
- ALL transaction providers (production, material_receive, final_dispatch, bp_inspection, dispatch_faco, receive_faco, ap_inspection, rtv, machine_downtime): use `_db.activeWorkspaceId` — NO hardcoded defaultFactoryId anywhere.
- `lib/core/router/app_router.dart`: owner role gets full module access same as admin.
- `lib/core/network/sync_service.dart`: pushes queued records to Supabase with exponential backoff. `queueInsert` now guards against empty `factory_id` — skips sync if workspace not set (prevents RLS failures).
- `supabase/migrations/202607120001_phase1_security_and_ledger.sql`: backup_records, factory-scoped RLS, request_account_deletion RPC, write_stock_ledger_entry RPC.
- `supabase/migrations/202607130001_workspace_signup.sql`: workspace_members table, membership-based RLS on all data tables, get_my_workspace_ids() helper, create_user_workspace RPC.

## Design Decision

Keep column name `factory_id` — treat it as workspace_id. Rename later in a controlled migration.

## Signup Flow (COMPLETE)

1. User taps "Create Account" on login screen.
2. Fills: name, company/workspace name, email, password.
3. `CurrentUserNotifier.signUp()` → `AuthRepository.signUp()`.
4. `AuthRepository.signUp()`:
   - `client.auth.signUp(email, password)`
   - RPC `create_user_workspace(p_profile_name, p_workspace_name)` → creates factories + users + workspace_members rows.
   - Locally: upserts workspace + member rows, sets active_workspace_id in app_settings.
   - Saves AppUser to local session.
5. App opens fresh workspace.

## Login Flow (COMPLETE)

- `CurrentUserNotifier.signIn()` → `AuthRepository.signIn()` → fetches AppUser from Supabase.
- After login: `db.setActiveWorkspaceId(user.factoryId)` — ensures new device always has correct workspace set.
- Falls back to local session if offline.

## RLS Model (COMPLETE — migration 202607130001)

- `get_my_workspace_ids()`: returns all workspace IDs where current user is active member.
- All data tables use membership-based RLS: `factory_id IN (SELECT get_my_workspace_ids())`.
- workspace_members: members read own rows; owners manage members.

## Back Button Behavior (FIXED — Session 4)

- `lib/core/widgets/app_shell.dart`: Converted from `ConsumerWidget` to `ConsumerStatefulWidget`.
- Uses `PopScope(canPop: false)` with `onPopInvokedWithResult`.
- Logic:
  - If current route != `/dashboard` → navigate to `/dashboard` (back goes to home, not exit).
  - If on `/dashboard` → first back press shows "Press back again to exit" snackbar.
  - Second back press within 2 seconds → `SystemNavigator.pop()` (exits app).

## Sync Fix (Session 4)

- `queueInsert` in `sync_service.dart` now checks `factory_id` in payload — if empty, skips enqueue entirely. Prevents RLS failures from uninitialized workspace.
- All `updatePart`, `updateOperator`, `updateMachine` payloads now include `factory_id: _db.activeWorkspaceId`.

## Settings Fix (Session 4)

- `_confirmDeleteAccount` in `settings_screen.dart`: Fixed `BuildContext` async gap warning — `context.go('/login')` moved after try/catch block with proper `mounted` check.
- `ReorderableListView.onReorderItem` — confirmed working in Flutter 3.44.6.
- `flutter analyze` shows 0 errors in settings_screen.dart after fix.

## What Still Needs Manual Action

1. **Apply Supabase migrations** — run both SQL files on the Supabase project:
   - `supabase/migrations/202607120001_phase1_security_and_ledger.sql`
   - `supabase/migrations/202607130001_workspace_signup.sql`

2. **Supabase email confirmation** — for dev/testing, disable "Confirm email" in Supabase Auth settings. If enabled, `create_user_workspace` RPC will fail because user is not authenticated yet.

3. **`factories` table schema** — verify `factories` table has `active` column (used in create_user_workspace RPC). If not, add: `ALTER TABLE factories ADD COLUMN active boolean DEFAULT true;`

## Future Work (not blocking current use)

- Export/import workspace snapshot service.
- Workspace switcher UI (for users in multiple workspaces).
- Invite flow (owner invites user by email/code).
- Suppliers/Vendors/Customers management UI in Settings (currently only Operators, Parts, Machines have UI).
- Admin dashboard (service-role backend, separate from mobile app).

## Known Notes

- `AppConstants.defaultFactoryId` is still defined in app_constants.dart but NO longer used anywhere in the app logic. It can be removed in a future cleanup.
- `activeWorkspaceId` returns empty string '' if not set (new install before first login). This is safe — queries will return empty results until user logs in. Sync queue also skips records with empty factory_id.
- Dev login in debug mode uses hardcoded factoryId '00000000-0000-0000-0000-000000000001' — only for development, not production.
- `dart format` and `flutter analyze` may hang in tool wrapper on this machine — run from IDE terminal.
- Cross-drive Kotlin bug: `kotlin.incremental=false` in `android/gradle.properties` — permanent fix, no need for `flutter clean`.
- Flutter version: 3.44.6 (stable), Dart 3.12.2.

## Session 4 Summary — What Was Done

**Problems reported:**
1. Android back button closes app instead of navigating within app.
2. Data not saving properly per user (workspace scoping).
3. Sync failing repeatedly.
4. Settings → Operator add → error. Settings → Parts → error.

**Root causes found:**
1. `AppShell` was `ConsumerWidget` with no back button handling — Android back went straight to OS.
2. `updatePart/updateOperator/updateMachine` payloads missing `factory_id` → Supabase RLS rejects upsert.
3. `queueInsert` had no guard for empty `factory_id` — queued records that would always fail RLS.
4. `_confirmDeleteAccount` had `BuildContext` async gap (warning, not crash).

**Files changed:**
- `lib/core/widgets/app_shell.dart` — full rewrite to `ConsumerStatefulWidget` with `PopScope`.
- `lib/core/providers/master_data_providers.dart` — added `factory_id` to `updatePart`, `updateOperator`, `updateMachine` payloads.
- `lib/core/network/sync_service.dart` — added `factory_id` empty guard in `queueInsert`.
- `lib/features/settings/settings_screen.dart` — fixed `BuildContext` async gap in `_confirmDeleteAccount`.
- `PROFLOW_WORKSPACE_MIGRATION_MEMORY.md` — this file updated.
