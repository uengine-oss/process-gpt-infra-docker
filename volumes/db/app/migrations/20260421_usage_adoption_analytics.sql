-- Usage adoption analytics for organization/team activity dashboards.

ALTER TABLE public.users ADD COLUMN IF NOT EXISTS employee_no text;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS org_code text;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS org_name text;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS department_id text;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS department_name text;

CREATE INDEX IF NOT EXISTS idx_users_tenant_department
    ON public.users (tenant_id, department_id);

CREATE INDEX IF NOT EXISTS idx_users_tenant_org
    ON public.users (tenant_id, org_code);

CREATE TABLE IF NOT EXISTS public.app_usage_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id text NOT NULL DEFAULT 'skt',
    event_type text NOT NULL,
    event_key text NULL,
    session_id text NULL,
    user_id text NULL,
    email text NULL,
    employee_no text NULL,
    user_name text NULL,
    department_id text NULL,
    department_name text NULL,
    org_code text NULL,
    org_name text NULL,
    route text NULL,
    proc_def_id text NULL,
    model_id uuid NULL,
    active_duration_ms bigint NOT NULL DEFAULT 0,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT app_usage_events_event_type_check CHECK (
        event_type IN (
            'session_start',
            'session_end',
            'route_view',
            'heartbeat',
            'model_view',
            'model_create',
            'model_edit',
            'model_save'
        )
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_app_usage_events_event_key
    ON public.app_usage_events (tenant_id, event_key)
    WHERE event_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_app_usage_events_tenant_time
    ON public.app_usage_events (tenant_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_app_usage_events_user_time
    ON public.app_usage_events (tenant_id, user_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_app_usage_events_email_time
    ON public.app_usage_events (tenant_id, email, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_app_usage_events_session
    ON public.app_usage_events (tenant_id, session_id);

CREATE INDEX IF NOT EXISTS idx_app_usage_events_model
    ON public.app_usage_events (tenant_id, proc_def_id, model_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_app_usage_events_type_time
    ON public.app_usage_events (tenant_id, event_type, occurred_at DESC);

ALTER TABLE public.app_usage_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "app_usage_events_all" ON public.app_usage_events;
CREATE POLICY "app_usage_events_all" ON public.app_usage_events
    FOR ALL
    USING (true)
    WITH CHECK (true);

GRANT ALL ON public.app_usage_events TO anon, authenticated;

COMMENT ON TABLE public.app_usage_events IS 'Product usage events for adoption, retention, and BPMN model activity dashboards.';
COMMENT ON COLUMN public.app_usage_events.active_duration_ms IS 'Active visible time reported by the browser heartbeat for this event.';
