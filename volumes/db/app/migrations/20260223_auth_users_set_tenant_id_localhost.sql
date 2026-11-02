-- =============================================================================
-- Ensure auth.users.raw_app_meta_data contains tenant_id = 'localhost'
-- - Fixes RLS checks that rely on JWT app_metadata.tenant_id
-- - Applies to existing users and new signups
-- =============================================================================

-- 1) Backfill existing users
UPDATE auth.users
SET raw_app_meta_data =
  COALESCE(raw_app_meta_data, '{}'::jsonb)
  || jsonb_build_object('tenant_id', 'localhost')
WHERE COALESCE(raw_app_meta_data->>'tenant_id', '') = '';

-- 2) Auto-set for new users (after insert trigger)
CREATE OR REPLACE FUNCTION public.set_auth_user_tenant_id_localhost()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  -- If tenant_id is missing, add it.
  UPDATE auth.users u
  SET raw_app_meta_data =
    COALESCE(u.raw_app_meta_data, '{}'::jsonb)
    || jsonb_build_object('tenant_id', 'localhost')
  WHERE u.id = NEW.id
    AND COALESCE(u.raw_app_meta_data->>'tenant_id', '') = '';

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_auth_user_tenant_id_localhost ON auth.users;
CREATE TRIGGER trg_set_auth_user_tenant_id_localhost
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.set_auth_user_tenant_id_localhost();

