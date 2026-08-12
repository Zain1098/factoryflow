-- Global Android release policy. The mobile app can only read this through
-- platform_android_release(); release publishing is server-side only.
CREATE TABLE IF NOT EXISTS public.platform_app_releases (
  channel text PRIMARY KEY CHECK (channel = 'android'),
  version_name text NOT NULL CHECK (char_length(btrim(version_name)) BETWEEN 1 AND 80),
  version_code integer NOT NULL CHECK (version_code > 0),
  minimum_supported_version_code integer NOT NULL CHECK (minimum_supported_version_code > 0 AND minimum_supported_version_code <= version_code),
  download_url text NOT NULL CHECK (download_url = 'https://github.com/Zain1098/factoryflow_app_release_version/releases/download/factoryflow/app-release.apk'),
  release_notes text NOT NULL DEFAULT '' CHECK (char_length(release_notes) <= 4000),
  sha256 text CHECK (sha256 IS NULL OR sha256 ~ '^[A-Fa-f0-9]{64}$'),
  is_mandatory boolean NOT NULL DEFAULT false,
  published_at timestamptz NOT NULL DEFAULT now(),
  published_by text NOT NULL DEFAULT 'release-automation'
);

ALTER TABLE public.platform_app_releases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.platform_app_releases FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.platform_android_release()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
    WHEN auth.uid() IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.active
    ) THEN NULL
    ELSE (
      SELECT jsonb_build_object(
        'version_name', r.version_name,
        'version_code', r.version_code,
        'minimum_supported_version_code', r.minimum_supported_version_code,
        'download_url', r.download_url,
        'release_notes', r.release_notes,
        'sha256', r.sha256,
        'is_mandatory', r.is_mandatory,
        'published_at', r.published_at
      )
      FROM public.platform_app_releases r
      WHERE r.channel = 'android'
    )
  END;
$$;

REVOKE ALL ON FUNCTION public.platform_android_release() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.platform_android_release() TO authenticated;
