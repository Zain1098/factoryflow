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
