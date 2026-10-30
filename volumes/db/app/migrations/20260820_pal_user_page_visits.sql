CREATE TABLE IF NOT EXISTS public.user_page_visits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id TEXT NOT NULL DEFAULT public.tenant_id(),
    user_email TEXT NOT NULL,
    page TEXT NOT NULL,
    last_visit_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (tenant_id, user_email, page)
);

CREATE INDEX IF NOT EXISTS idx_user_page_visits_tenant_user
    ON public.user_page_visits (tenant_id, user_email);

ALTER TABLE public.user_page_visits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_page_visits_tenant_policy ON public.user_page_visits;
CREATE POLICY user_page_visits_tenant_policy ON public.user_page_visits
    FOR ALL TO authenticated
    USING (tenant_id = public.tenant_id())
    WITH CHECK (tenant_id = public.tenant_id());
