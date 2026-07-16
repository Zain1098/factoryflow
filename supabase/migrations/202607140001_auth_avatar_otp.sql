-- Phase 3: avatar_url, OTP verification, Google auth support
-- Apply after 202607130001_workspace_signup.sql

-- ── Add avatar_url to users table ─────────────────────────────────────────────
ALTER TABLE IF EXISTS public.users ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- ── OTP verification codes table ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.otp_codes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  purpose TEXT NOT NULL CHECK (purpose IN ('email_change', 'password_change')),
  new_value TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  used BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_otp_codes_user ON public.otp_codes(user_id);
CREATE INDEX IF NOT EXISTS idx_otp_codes_expires ON public.otp_codes(expires_at);

ALTER TABLE public.otp_codes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "otp_codes_read_own" ON public.otp_codes FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "otp_codes_insert_own" ON public.otp_codes FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "otp_codes_update_own" ON public.otp_codes FOR UPDATE
  USING (user_id = auth.uid());

-- ── RPC: Generate OTP ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_otp(
  p_user_id UUID,
  p_purpose TEXT,
  p_new_value TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code TEXT;
BEGIN
  -- 6-digit code
  v_code := LPAD(CAST(FLOOR(RANDOM() * 1000000) AS INTEGER)::TEXT, 6, '0');

  INSERT INTO public.otp_codes (user_id, code, purpose, new_value, expires_at)
  VALUES (p_user_id, v_code, p_purpose, p_new_value, NOW() + INTERVAL '10 minutes');

  RETURN v_code;
END;
$$;

REVOKE ALL ON FUNCTION public.generate_otp(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_otp(UUID, TEXT, TEXT) TO authenticated;

-- ── RPC: Verify OTP ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.verify_otp(
  p_user_id UUID,
  p_code TEXT,
  p_purpose TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_otp RECORD;
BEGIN
  SELECT * INTO v_otp FROM public.otp_codes
  WHERE user_id = p_user_id
    AND code = p_code
    AND purpose = p_purpose
    AND used = FALSE
    AND expires_at > NOW()
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_otp.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Invalid or expired OTP');
  END IF;

  UPDATE public.otp_codes SET used = TRUE WHERE id = v_otp.id;

  RETURN jsonb_build_object('success', TRUE, 'new_value', v_otp.new_value);
END;
$$;

REVOKE ALL ON FUNCTION public.verify_otp(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_otp(UUID, TEXT, TEXT) TO authenticated;

-- ── RPC: Update user profile (name + avatar_url) ──────────────────────────────
CREATE OR REPLACE FUNCTION public.update_user_profile(
  p_user_id UUID,
  p_name TEXT DEFAULT NULL,
  p_avatar_url TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users
  SET
    name = COALESCE(p_name, name),
    avatar_url = COALESCE(p_avatar_url, avatar_url)
  WHERE id = p_user_id AND id = auth.uid();

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.update_user_profile(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_user_profile(UUID, TEXT, TEXT) TO authenticated;

-- ── RPC: Update user email (after OTP verified) ───────────────────────────────
CREATE OR REPLACE FUNCTION public.update_user_email_after_otp(
  p_user_id UUID,
  p_new_email TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Update email in public.users
  UPDATE public.users
  SET email = p_new_email
  WHERE id = p_user_id AND id = auth.uid();

  -- Update email in auth.users via the auth API
  -- (this requires service_role key, so we call a separate function)

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.update_user_email_after_otp(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_user_email_after_otp(UUID, TEXT) TO authenticated;

-- ── RPC: Update auth email (service_role only) ────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_update_user_email(
  p_user_id UUID,
  p_new_email TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only service_role can call this
  IF current_setting('role') != 'service_role' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Service role required');
  END IF;

  UPDATE auth.users
  SET email = p_new_email
  WHERE id = p_user_id;

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_update_user_email(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_user_email(UUID, TEXT) TO service_role;

-- ── RPC: Handle Google OAuth user creation/login ──────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_google_auth_user(
  p_user_id UUID,
  p_email TEXT,
  p_name TEXT,
  p_avatar_url TEXT,
  p_workspace_name TEXT DEFAULT 'My Workspace'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_workspace_id UUID;
  v_existing_user RECORD;
BEGIN
  -- Check if user exists already
  SELECT * INTO v_existing_user FROM public.users WHERE id = p_user_id;

  IF v_existing_user.id IS NOT NULL THEN
    -- User exists — update profile from Google
    UPDATE public.users
    SET
      name = COALESCE(p_name, name),
      email = p_email,
      avatar_url = COALESCE(p_avatar_url, avatar_url)
    WHERE id = p_user_id;

    RETURN jsonb_build_object(
      'is_new', FALSE,
      'workspace_id', v_existing_user.factory_id
    );
  ELSE
    -- New user — create workspace and profile
    v_workspace_id := uuid_generate_v4();

    INSERT INTO public.factories (id, name, active)
    VALUES (v_workspace_id, p_workspace_name, TRUE);

    INSERT INTO public.users (id, factory_id, name, email, role, active, avatar_url)
    VALUES (p_user_id, v_workspace_id, p_name, p_email, 'owner', TRUE, p_avatar_url);

    INSERT INTO public.workspace_members (id, workspace_id, user_id, role, status)
    VALUES (uuid_generate_v4(), v_workspace_id, p_user_id, 'owner', 'active');

    RETURN jsonb_build_object(
      'is_new', TRUE,
      'workspace_id', v_workspace_id
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_google_auth_user(UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.handle_google_auth_user(UUID, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- ── Grant usage for net extension if available ─────────────────────────────────
-- Uncomment if supabase_http extension is installed for sending emails:
-- GRANT USAGE ON SCHEMA net TO service_role;
-- GRANT EXECUTE ON FUNCTION net.http_post TO service_role;
