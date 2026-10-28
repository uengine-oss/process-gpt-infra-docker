-- ============================================
-- External API Health Table
-- ============================================

CREATE TABLE IF NOT EXISTS public.external_api_health (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id VARCHAR(255) NOT NULL DEFAULT 'default',
    integration_target_name VARCHAR(255) NOT NULL,
    call_address TEXT NOT NULL,
    health_status VARCHAR(20) NOT NULL CHECK (health_status IN ('정상', '비정상')),
    last_check_time TIMESTAMPTZ NOT NULL DEFAULT now(),
    error_message_log TEXT,
    manual_sync_enabled BOOLEAN NOT NULL DEFAULT true,
    last_manual_sync_requested_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_external_api_health_tenant_target
    ON public.external_api_health(tenant_id, integration_target_name);

CREATE INDEX IF NOT EXISTS idx_external_api_health_last_check_time
    ON public.external_api_health(last_check_time DESC);

ALTER TABLE public.external_api_health ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "external_api_health_public_read" ON public.external_api_health;
CREATE POLICY "external_api_health_public_read"
    ON public.external_api_health
    FOR SELECT
    USING (true);

DROP POLICY IF EXISTS "external_api_health_public_write" ON public.external_api_health;
CREATE POLICY "external_api_health_public_write"
    ON public.external_api_health
    FOR ALL
    USING (true)
    WITH CHECK (true);

GRANT ALL ON public.external_api_health TO authenticated;
