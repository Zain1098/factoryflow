# factoryflow

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
# FactoryFlow platform Admin Control

The mobile app now includes the protected `/admin-control` route. It is a
platform-maintenance console, not a production or inventory dashboard. It
contains workspace status, user blocking, maintenance mode, and immutable
privileged-action audit views.

## Deploy the database change

1. Back up the target project and review `supabase/migrations/20260810090000_platform_admin_control.sql`.
2. Apply the migration through the normal Supabase migration workflow. Do not paste a service-role key into the mobile app.
3. Bootstrap the first platform administrator only from a trusted server/database session:

   ```sql
   insert into public.platform_admins (user_id, granted_by, note)
   values ('<existing-public.users-id>', '<existing-public.users-id>', 'initial platform administrator');
   ```

4. Start the app with `--dart-define=SUPABASE_URL=...` and
   `--dart-define=SUPABASE_ANON_KEY=...`, then navigate to `/admin-control`.

The only client key is the Supabase publishable/anon key. Privileged reads and
writes use narrowly granted RPCs; all new tables are RLS-enabled with no direct
client privileges. Workspace suspension is included in the shared membership
helpers so tenant-scoped policies using them no longer authorize suspended
workspaces. Existing factory operational tables and ledger flows are unchanged.

## Automated Android APK releases

The app reads its installed Android build number and, after sign-in/access
verification and on app resume, calls the authenticated
`platform_android_release()` RPC. It compares that value to the server policy:

- newer server build: optional update with **Later** or **Update now**;
- installed build below `minimum_supported_version_code`, or a newer mandatory
  release: non-dismissible **Update required** screen;
- network failure: app continues normally unless the cached forced policy says
  an update is required.

The fixed download URL is:

`https://github.com/Zain1098/factoryflow_app_release_version/releases/download/factoryflow/app-release.apk`

Mobile clients do not contain a GitHub token, release token, signing key, or
Supabase service-role key. Android always asks the user to confirm APK install.

### One-time server setup

1. The existing `platform_android_release()` RPC and `platform_app_releases`
   table are already used; do not create a second update table.
2. Deploy the Edge Function with `supabase functions deploy publish-android-release`.
3. Set the same strong random value as `RELEASE_PUBLISH_TOKEN` in Supabase Edge
   Function secrets and GitHub Actions secrets. Never put it in Flutter code.
4. In `Zain1098/factoryflow_app_release_version`, create (or retain) release tag
   `factoryflow`; the workflow replaces only its `app-release.apk` asset.

### GitHub Actions secrets

Configure these in the repository that contains this workflow:

- `RELEASE_PUBLISH_TOKEN` — shared only with the Edge Function secret.
- `SUPABASE_URL` and `SUPABASE_ANON_KEY` — used only to invoke the deployed
  function; neither is a service-role secret.
- `RELEASE_REPOSITORY_TOKEN` — fine-grained token with **Contents: read/write**
  access limited to `Zain1098/factoryflow_app_release_version`.
- `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, and
  `ANDROID_STORE_PASSWORD` — Android signing material, never committed.

### Run a release

GitHub → **Actions** → **Release Android APK** → **Run workflow**. Enter the
version name, notes, minimum supported build number, and whether it is mandatory.
The workflow sets `version_code` to GitHub's run number, builds `app-release.apk`,
calculates SHA-256, replaces the fixed GitHub Release asset, then publishes the
same metadata through the server-side Edge Function.

### Rollback

Run the same workflow again with a known-good APK/version and a new, higher
GitHub run number. Do not lower `version_code`: installed apps only move forward.
Set `mandatory` false and choose an appropriate minimum supported build number
to remove a forced-update policy.
