# FactoryFlow Auth Email Configuration

This app accepts a 6 to 10 digit code for sign-up, password recovery, and
reauthentication. A code is single-use. Do not include both a code and a
clickable verification link in the same sign-up or recovery email: opening the
link can consume the same token before the user enters the code in the app.

## Required Supabase Dashboard settings

In **Authentication > Email Templates**, configure these templates:

### Confirm signup

```html
<h2>Verify your FactoryFlow email</h2>
<p>Enter this verification code in the FactoryFlow app. Do not share it with anyone.</p>
<h1>{{ .Token }}</h1>
<p>If you did not create this account, you can ignore this email.</p>
```

### Reset password

```html
<h2>Reset your FactoryFlow password</h2>
<p>Enter this verification code in the FactoryFlow app. Do not share it with anyone.</p>
<h1>{{ .Token }}</h1>
<p>If you did not request a password reset, you can ignore this email.</p>
```

Do **not** add `{{ .ConfirmationURL }}` to either template. FactoryFlow
validates the code before it displays the new-password form.

### Reauthentication

```html
<h2>FactoryFlow security code</h2>
<p>Use this code to confirm a sensitive account change in FactoryFlow.</p>
<h1>{{ .Token }}</h1>
<p>Do not share this code with anyone.</p>
```

### Change email address

Keep the confirmation link (`{{ .ConfirmationURL }}`) in this template. The
app first requires a reauthentication code sent to the current address, then
Supabase sends a confirmation to the new address. This two-step process
prevents a stolen open session from silently changing an account email.

## Security switches

In **Authentication > Providers > Email**, keep email confirmation enabled.
In **Authentication > Settings**, keep Secure email change enabled and enable
password-change security notifications. Configure a production SMTP provider
before release; the default SMTP sender is rate limited and is not suitable for
a real factory rollout.

## Test checklist

1. Sign up with a new email, enter the latest six-digit code, and confirm a
   workspace is created once.
2. Use Forgot Password, enter the latest code, set a password, then sign in
   with it. A previously sent code must fail after resend.
3. Change password in Settings: enter the reauthentication code sent to the
   current email, then confirm the password-change notification arrives.
4. Change email in Settings: enter the reauthentication code, then confirm the
   email received at the new address before expecting the account email to
   change.
5. Confirm that raw server errors and tokens never appear in the app UI or
   logs shown to end users.

## Account deletion and audit deployment

Account deletion keeps the old `public.users`, `backup_records`, and
`account_audit_log` rows for the admin panel, then removes only the matching
Supabase Auth user so the email can be registered again. The Auth removal is
implemented in the server-only `delete-account` Edge Function; never put a
Supabase secret/service-role key in Flutter or `.env` values shipped to users.

Deploy after applying the latest migration:

```bash
supabase functions deploy delete-account
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=your-server-only-key
```

The function refuses to delete an Auth user unless `public.users.active` is
already false. Profile, email, activation, and deletion changes are recorded
by the `account_audit_log` trigger.
