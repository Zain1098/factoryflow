# FactoryFlow

FactoryFlow is an offline-first Flutter manufacturing ERP for tracking material
from inward receipt through production, quality inspection, Vendor processing,
rework, and final customer dispatch. Each company workspace is isolated and
operational records synchronise to Supabase when connectivity is available.

## Core workflow

```text
Material Receive → Production → BP Stock → Vendor Dispatch → Vendor Receive
→ AP Inspection → Approved AP → Final Dispatch
```

Quality stock is never silently removed. BP and AP rejections remain visible
until an authorised user records an explicit final disposition. RTV material is
kept distinct from normal Vendor stock and remains auditable through its return
workflow.

## Features

- Company/workspace-based access control and active-user safeguards.
- Local SQLite-first records with a durable sync queue and retry history.
- Material receipt, production, BP and AP inspection, Vendor dispatch/receive,
  RTV, and final dispatch.
- Stage-wise live stock, reject, hold, Vendor-pending, production, and dispatch
  reports.
- Batch traceability for dispatch-eligible finished material and rejected-stock
  disposition; a BP/AP rejection action cannot consume quantity from another
  source batch.
- Owner/Admin stock reconciliation with immutable ledger movements and remarks.
- Android update policy and controlled platform administration.

## Technology

- Flutter and Riverpod
- SQLite (`sqlite3`) for offline storage
- Supabase Auth, Postgres, Row Level Security, and Edge Functions

## Local setup

Prerequisites: Flutter SDK compatible with `pubspec.yaml`, an Android toolchain,
and a Supabase project for cloud synchronisation.

```powershell
flutter pub get
flutter run `
  --dart-define=SUPABASE_URL=https://your-project.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=your-publishable-key
```

The app can operate locally when Supabase is unavailable; queued changes sync
once access and connectivity are restored. Never place a service-role key,
Android signing key, GitHub token, or release token in Flutter code or Git.

## Database migrations

Supabase migrations are stored in `supabase/migrations/`. Review migration
status before applying anything to a linked project:

```powershell
.\tool\deploy_supabase_migrations.ps1
.\tool\deploy_supabase_migrations.ps1 -Apply
```

Do not use `--include-all` or migration repair as a shortcut for history drift.
Compare local and remote migration history first.

## Verification

Run the relevant checks before publishing a change:

```powershell
flutter analyze
flutter test
git diff --check
```

For stock-flow changes, also perform a device smoke test covering stock entry,
Vendor dispatch/receipt, inspection, rejection disposition, report totals, and
final dispatch. A command timeout is not successful verification.

## Android release

The repository includes scripts for a signed APK and release metadata. Keep all
credentials outside Git and review the release workflow before publishing:

```powershell
.\tool\build_signed_apk.ps1 -VersionName 1.2.0 -BuildNumber 120
```

Upload the generated APK only after its version, signature, hash, and runtime
smoke test have been confirmed.

## Repository hygiene

- Keep migrations append-only.
- Stage only reviewed files; do not use broad staging in a dirty worktree.
- Preserve ledger and operational history; correct records through authorised
  reversal/disposition flows rather than direct edits.
- Treat server-side Supabase RLS/RPC checks as authoritative over UI guards.
