-- Preserve user lifecycle history independently from Supabase Auth.
-- The public.users row is intentionally retained after account deletion so
-- old backups and audit records remain addressable by the admin panel.

CREATE TABLE IF NOT EXISTS public.account_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  factory_id uuid,
  email text,
  action text NOT NULL,
  old_data jsonb,
  new_data jsonb,
  changed_by uuid,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  metadata jsonb
);

CREATE INDEX IF NOT EXISTS idx_account_audit_user
  ON public.account_audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_account_audit_factory
  ON public.account_audit_log(factory_id);
CREATE INDEX IF NOT EXISTS idx_account_audit_time
  ON public.account_audit_log(occurred_at);

ALTER TABLE public.account_audit_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.account_audit_log FROM PUBLIC, anon;
GRANT SELECT ON public.account_audit_log TO authenticated;

DROP POLICY IF EXISTS "account_audit_admin_read" ON public.account_audit_log;
CREATE POLICY "account_audit_admin_read"
  ON public.account_audit_log FOR SELECT
  TO authenticated
  USING (
    factory_id = public.get_my_factory_id()
    AND public.get_my_role() = 'Admin'
  );

CREATE OR REPLACE FUNCTION public.audit_user_profile_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.account_audit_log (
    user_id,
    factory_id,
    email,
    action,
    old_data,
    new_data,
    changed_by,
    metadata
  )
  VALUES (
    COALESCE(NEW.id, OLD.id),
    COALESCE(NEW.factory_id, OLD.factory_id),
    COALESCE(NEW.email, OLD.email),
    CASE
      WHEN TG_OP = 'INSERT' THEN 'account_created'
      WHEN TG_OP = 'DELETE' THEN 'account_profile_deleted'
      WHEN OLD.active IS TRUE AND NEW.active IS FALSE THEN 'account_deleted'
      ELSE 'user_profile_updated'
    END,
    CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END,
    CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END,
    auth.uid(),
    jsonb_build_object('source', 'public.users trigger')
  );
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS users_account_audit_trigger ON public.users;
CREATE TRIGGER users_account_audit_trigger
  AFTER INSERT OR UPDATE OR DELETE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.audit_user_profile_changes();

-- The Flutter client updates Auth email after reauthentication. Keep the
-- public profile in sync through one audited, ownership-checked RPC.
CREATE OR REPLACE FUNCTION public.sync_user_email(
  p_user_id uuid,
  p_new_email text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF COALESCE(btrim(p_new_email), '') = ''
    OR char_length(btrim(p_new_email)) > 320
    OR position('@' IN btrim(p_new_email)) <= 1
  THEN
    RAISE EXCEPTION 'invalid email';
  END IF;

  UPDATE public.users
  SET email = lower(btrim(p_new_email))
  WHERE id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile not found';
  END IF;
  RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.sync_user_email(uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sync_user_email(uuid, text)
  TO authenticated;

-- Deactivation is recorded by the trigger. The Auth row is removed only by
-- the server-side delete-account Edge Function, never by the Flutter client.
CREATE OR REPLACE FUNCTION public.request_account_deletion(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  UPDATE public.users
  SET active = false
  WHERE id = auth.uid();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile not found';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.request_account_deletion(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_account_deletion(uuid)
  TO authenticated;
