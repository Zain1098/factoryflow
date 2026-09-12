-- Migration: Unify Google and Email/Password logins by email address
-- Ensures that any login with the same email address maps to the same primary workspace / factory.

-- 1. Create or update resolve_user_workspace RPC
CREATE OR REPLACE FUNCTION public.resolve_user_workspace()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_email text;
  v_target_workspace_id uuid;
  v_workspace_name text;
  v_role text := 'owner';
  v_profile_name text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  -- Look up email from auth.users
  SELECT lower(btrim(email)) INTO v_email
  FROM auth.users
  WHERE id = v_user_id;

  IF v_email IS NULL THEN
    SELECT lower(btrim(email)) INTO v_email
    FROM public.users
    WHERE id = v_user_id;
  END IF;

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'authenticated user email not found';
  END IF;

  -- Find primary workspace for this email:
  -- Priority 1: A workspace with existing parts or productions
  SELECT u.factory_id INTO v_target_workspace_id
  FROM public.users u
  WHERE lower(btrim(u.email)) = v_email
    AND u.factory_id IS NOT NULL
  ORDER BY (
    COALESCE((SELECT count(*) FROM public.parts WHERE factory_id = u.factory_id), 0) +
    COALESCE((SELECT count(*) FROM public.productions WHERE factory_id = u.factory_id), 0)
  ) DESC, u.created_at ASC
  LIMIT 1;

  -- Priority 2: Check workspace_members
  IF v_target_workspace_id IS NULL THEN
    SELECT wm.workspace_id INTO v_target_workspace_id
    FROM public.workspace_members wm
    JOIN public.users u ON u.id = wm.user_id
    WHERE lower(btrim(u.email)) = v_email
      AND wm.status = 'active'
    ORDER BY (
      COALESCE((SELECT count(*) FROM public.parts WHERE factory_id = wm.workspace_id), 0) +
      COALESCE((SELECT count(*) FROM public.productions WHERE factory_id = wm.workspace_id), 0)
    ) DESC
    LIMIT 1;
  END IF;

  -- Priority 3: If completely new account, create a new factory
  IF v_target_workspace_id IS NULL THEN
    v_target_workspace_id := gen_random_uuid();
    INSERT INTO public.factories (id, name, active)
    VALUES (v_target_workspace_id, 'My Workspace', true);
  END IF;

  -- Determine best profile name
  SELECT u.name INTO v_profile_name
  FROM public.users u
  WHERE lower(btrim(u.email)) = v_email
    AND u.name IS NOT NULL
    AND u.name <> ''
  ORDER BY u.created_at ASC
  LIMIT 1;

  IF v_profile_name IS NULL OR v_profile_name = '' THEN
    SELECT COALESCE(raw_user_meta_data->>'full_name', raw_user_meta_data->>'name', raw_user_meta_data->>'profile_name', split_part(v_email, '@', 1))
    INTO v_profile_name
    FROM auth.users
    WHERE id = v_user_id;
  END IF;

  -- Ensure public.users entry exists and points to the primary workspace
  INSERT INTO public.users (id, factory_id, name, email, role, active)
  VALUES (
    v_user_id,
    v_target_workspace_id,
    COALESCE(v_profile_name, split_part(v_email, '@', 1)),
    v_email,
    'owner',
    true
  )
  ON CONFLICT (id) DO UPDATE
  SET factory_id = v_target_workspace_id,
      email = v_email,
      active = true;

  -- Ensure workspace_members entry exists for this auth.uid() in the target workspace
  INSERT INTO public.workspace_members (id, workspace_id, user_id, role, status, joined_at)
  VALUES (gen_random_uuid(), v_target_workspace_id, v_user_id, 'owner', 'active', now())
  ON CONFLICT (workspace_id, user_id) DO UPDATE
  SET status = 'active';

  -- Fetch workspace name
  SELECT name INTO v_workspace_name
  FROM public.factories
  WHERE id = v_target_workspace_id;

  RETURN jsonb_build_object(
    'workspace_id', v_target_workspace_id,
    'workspace_name', COALESCE(v_workspace_name, 'My Workspace'),
    'role', v_role
  );
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_user_workspace() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_user_workspace() TO authenticated;

-- 2. Update create_user_workspace to reuse existing workspace by email
CREATE OR REPLACE FUNCTION public.create_user_workspace(
  p_profile_name text,
  p_workspace_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_workspace_id uuid;
  v_email text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF COALESCE(btrim(p_profile_name), '') = ''
    OR char_length(btrim(p_profile_name)) > 120
    OR COALESCE(btrim(p_workspace_name), '') = ''
    OR char_length(btrim(p_workspace_name)) > 120
  THEN
    RAISE EXCEPTION 'invalid profile or workspace name';
  END IF;

  SELECT au.email
    INTO v_email
  FROM auth.users AS au
  WHERE au.id = v_user_id;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'authenticated user was not found';
  END IF;

  -- 1. Check if user already has a workspace assigned
  SELECT u.factory_id
    INTO v_workspace_id
  FROM public.users AS u
  WHERE u.id = v_user_id
  LIMIT 1;

  -- 2. If not, check if an existing workspace already exists for this email!
  IF v_workspace_id IS NULL THEN
    SELECT u.factory_id
      INTO v_workspace_id
    FROM public.users AS u
    WHERE lower(btrim(u.email)) = lower(btrim(v_email))
      AND u.factory_id IS NOT NULL
    ORDER BY (
      COALESCE((SELECT count(*) FROM public.parts WHERE factory_id = u.factory_id), 0) +
      COALESCE((SELECT count(*) FROM public.productions WHERE factory_id = u.factory_id), 0)
    ) DESC, u.created_at ASC
    LIMIT 1;
  END IF;

  IF v_workspace_id IS NOT NULL THEN
    INSERT INTO public.users (id, factory_id, name, email, role, active)
    VALUES (v_user_id, v_workspace_id, btrim(p_profile_name), v_email, 'owner', true)
    ON CONFLICT (id) DO UPDATE
    SET name = btrim(p_profile_name),
        factory_id = v_workspace_id,
        email = v_email;

    INSERT INTO public.workspace_members (id, workspace_id, user_id, role, status, joined_at)
    VALUES (gen_random_uuid(), v_workspace_id, v_user_id, 'owner', 'active', now())
    ON CONFLICT (workspace_id, user_id) DO UPDATE
    SET status = 'active';

    RETURN jsonb_build_object(
      'workspace_id', v_workspace_id,
      'user_id', v_user_id,
      'idempotent', true
    );
  END IF;

  -- 3. Brand new workspace only if no existing workspace exists for this email
  v_workspace_id := gen_random_uuid();

  INSERT INTO public.factories (id, name, active)
  VALUES (v_workspace_id, btrim(p_workspace_name), true);

  INSERT INTO public.users (id, factory_id, name, email, role, active)
  VALUES (
    v_user_id,
    v_workspace_id,
    btrim(p_profile_name),
    v_email,
    'owner',
    true
  );

  INSERT INTO public.workspace_members (
    id,
    workspace_id,
    user_id,
    role,
    status,
    joined_at
  )
  VALUES (
    gen_random_uuid(),
    v_workspace_id,
    v_user_id,
    'owner',
    'active',
    now()
  );

  RETURN jsonb_build_object(
    'workspace_id', v_workspace_id,
    'user_id', v_user_id,
    'idempotent', false
  );
END;
$$;

-- 3. Update handle_google_auth_user to reuse existing workspace by email
CREATE OR REPLACE FUNCTION public.handle_google_auth_user(
  p_user_id uuid,
  p_email text,
  p_name text,
  p_avatar_url text,
  p_workspace_name text DEFAULT 'My Workspace'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_workspace_id uuid;
  v_auth_email text;
BEGIN
  IF auth.uid() IS NULL OR p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized';
  END IF;
  IF COALESCE(btrim(p_name), '') = ''
    OR char_length(btrim(p_name)) > 120
    OR COALESCE(btrim(p_workspace_name), '') = ''
    OR char_length(btrim(p_workspace_name)) > 120
    OR char_length(COALESCE(p_avatar_url, '')) > 2048
  THEN
    RAISE EXCEPTION 'invalid Google profile';
  END IF;

  SELECT au.email
    INTO v_auth_email
  FROM auth.users AS au
  WHERE au.id = auth.uid();

  IF v_auth_email IS NULL THEN
    v_auth_email := p_email;
  END IF;

  -- 1. Check if user already has a workspace
  SELECT u.factory_id
    INTO v_workspace_id
  FROM public.users AS u
  WHERE u.id = auth.uid()
  LIMIT 1;

  -- 2. If not, check if an existing workspace already exists for this email!
  IF v_workspace_id IS NULL AND v_auth_email IS NOT NULL THEN
    SELECT u.factory_id
      INTO v_workspace_id
    FROM public.users AS u
    WHERE lower(btrim(u.email)) = lower(btrim(v_auth_email))
      AND u.factory_id IS NOT NULL
    ORDER BY (
      COALESCE((SELECT count(*) FROM public.parts WHERE factory_id = u.factory_id), 0) +
      COALESCE((SELECT count(*) FROM public.productions WHERE factory_id = u.factory_id), 0)
    ) DESC, u.created_at ASC
    LIMIT 1;
  END IF;

  IF v_workspace_id IS NOT NULL THEN
    INSERT INTO public.users (id, factory_id, name, email, role, active, avatar_url)
    VALUES (
      auth.uid(),
      v_workspace_id,
      btrim(p_name),
      v_auth_email,
      'owner',
      true,
      NULLIF(p_avatar_url, '')
    )
    ON CONFLICT (id) DO UPDATE
    SET name = btrim(p_name),
        factory_id = v_workspace_id,
        email = v_auth_email,
        avatar_url = NULLIF(p_avatar_url, '');

    INSERT INTO public.workspace_members (id, workspace_id, user_id, role, status, joined_at)
    VALUES (gen_random_uuid(), v_workspace_id, auth.uid(), 'owner', 'active', now())
    ON CONFLICT (workspace_id, user_id) DO UPDATE
    SET status = 'active';

    RETURN jsonb_build_object(
      'is_new', false,
      'workspace_id', v_workspace_id
    );
  END IF;

  v_workspace_id := gen_random_uuid();

  INSERT INTO public.factories (id, name, active)
  VALUES (v_workspace_id, btrim(p_workspace_name), true);

  INSERT INTO public.users (
    id,
    factory_id,
    name,
    email,
    role,
    active,
    avatar_url
  )
  VALUES (
    auth.uid(),
    v_workspace_id,
    btrim(p_name),
    v_auth_email,
    'owner',
    true,
    NULLIF(p_avatar_url, '')
  );

  INSERT INTO public.workspace_members (
    id,
    workspace_id,
    user_id,
    role,
    status,
    joined_at
  )
  VALUES (
    gen_random_uuid(),
    v_workspace_id,
    auth.uid(),
    'owner',
    'active',
    now()
  );

  RETURN jsonb_build_object(
    'is_new', true,
    'workspace_id', v_workspace_id
  );
END;
$$;
