-- Per-user device token and last-access state used by the web/mobile clients.

CREATE TABLE IF NOT EXISTS public.user_devices (
    user_email text PRIMARY KEY,
    device_token text,
    access_page text,
    last_access_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.user_devices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_devices_select_own ON public.user_devices;
CREATE POLICY user_devices_select_own
ON public.user_devices
FOR SELECT
TO authenticated
USING (lower(user_email) = lower(COALESCE(auth.jwt()->>'email', '')));

DROP POLICY IF EXISTS user_devices_insert_own ON public.user_devices;
CREATE POLICY user_devices_insert_own
ON public.user_devices
FOR INSERT
TO authenticated
WITH CHECK (lower(user_email) = lower(COALESCE(auth.jwt()->>'email', '')));

DROP POLICY IF EXISTS user_devices_update_own ON public.user_devices;
CREATE POLICY user_devices_update_own
ON public.user_devices
FOR UPDATE
TO authenticated
USING (lower(user_email) = lower(COALESCE(auth.jwt()->>'email', '')))
WITH CHECK (lower(user_email) = lower(COALESCE(auth.jwt()->>'email', '')));

GRANT SELECT, INSERT, UPDATE ON public.user_devices TO authenticated;

NOTIFY pgrst, 'reload schema';
