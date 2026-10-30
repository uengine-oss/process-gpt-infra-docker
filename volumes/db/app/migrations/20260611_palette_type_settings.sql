CREATE TABLE IF NOT EXISTS public.palette_task_types (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id text NOT NULL DEFAULT public.tenant_id(),
    task_type text NOT NULL,
    label text NOT NULL,
    label_ko text,
    icon text,
    is_enabled boolean NOT NULL DEFAULT true,
    display_order integer NOT NULL DEFAULT 0,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT palette_task_types_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES public.tenants(id)
        ON UPDATE CASCADE ON DELETE CASCADE
);

ALTER TABLE public.palette_task_types ADD COLUMN IF NOT EXISTS tenant_id text DEFAULT public.tenant_id();
ALTER TABLE public.palette_task_types ADD COLUMN IF NOT EXISTS task_type text;
ALTER TABLE public.palette_task_types ADD COLUMN IF NOT EXISTS label text;
ALTER TABLE public.palette_task_types ADD COLUMN IF NOT EXISTS label_ko text;
ALTER TABLE public.palette_task_types ADD COLUMN IF NOT EXISTS icon text;
ALTER TABLE public.palette_task_types ADD COLUMN IF NOT EXISTS is_enabled boolean DEFAULT true;
ALTER TABLE public.palette_task_types ADD COLUMN IF NOT EXISTS display_order integer DEFAULT 0;
ALTER TABLE public.palette_task_types ADD COLUMN IF NOT EXISTS created_at timestamp with time zone DEFAULT now();
ALTER TABLE public.palette_task_types ADD COLUMN IF NOT EXISTS updated_at timestamp with time zone DEFAULT now();

DELETE FROM public.palette_task_types a
USING public.palette_task_types b
WHERE a.ctid < b.ctid
  AND a.tenant_id = b.tenant_id
  AND a.task_type = b.task_type;

CREATE UNIQUE INDEX IF NOT EXISTS palette_task_types_tenant_task_type_idx
    ON public.palette_task_types (tenant_id, task_type);

CREATE INDEX IF NOT EXISTS palette_task_types_tenant_idx
    ON public.palette_task_types (tenant_id);

ALTER TABLE public.palette_task_types ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "palette_task_types_select" ON public.palette_task_types;
CREATE POLICY "palette_task_types_select" ON public.palette_task_types
    FOR SELECT TO authenticated
    USING (tenant_id = public.tenant_id());

DROP POLICY IF EXISTS "palette_task_types_insert_admin" ON public.palette_task_types;
CREATE POLICY "palette_task_types_insert_admin" ON public.palette_task_types
    FOR INSERT TO authenticated
    WITH CHECK (tenant_id = public.tenant_id() AND public.has_role_at_least('admin'));

DROP POLICY IF EXISTS "palette_task_types_update_admin" ON public.palette_task_types;
CREATE POLICY "palette_task_types_update_admin" ON public.palette_task_types
    FOR UPDATE TO authenticated
    USING (tenant_id = public.tenant_id() AND public.has_role_at_least('admin'))
    WITH CHECK (tenant_id = public.tenant_id() AND public.has_role_at_least('admin'));

DROP POLICY IF EXISTS "palette_task_types_delete_admin" ON public.palette_task_types;
CREATE POLICY "palette_task_types_delete_admin" ON public.palette_task_types
    FOR DELETE TO authenticated
    USING (tenant_id = public.tenant_id() AND public.has_role_at_least('admin'));

WITH default_task_types(task_type, label, label_ko, icon, is_enabled, display_order) AS (
    VALUES
        ('bpmn:Task', 'Task', '일반 작업', 'bpmn-icon-task-none', true, 5),
        ('bpmn:ManualTask', 'Manual Task', '수동 작업', 'bpmn-icon-task', true, 10),
        ('bpmn:ServiceTask', 'Service Task', '서비스 작업', 'bpmn-icon-service-task', true, 20),
        ('bpmn:UserTask', 'User Task', '사용자 작업', 'bpmn-icon-user-task', true, 30),
        ('bpmn:ScriptTask', 'Script Task', '스크립트 작업', 'bpmn-icon-script-task', true, 40),
        ('bpmn:BusinessRuleTask', 'Business Rule Task', '비즈니스 규칙 작업', 'bpmn-icon-business-rule-task', true, 50),
        ('bpmn:SendTask', 'Send Task', '전송 작업', 'bpmn-icon-send-task', true, 60),
        ('bpmn:ReceiveTask', 'Receive Task', '수신 작업', 'bpmn-icon-receive-task', true, 70),
        ('bpmn:AdHocSubProcess', 'Ad-hoc Sub Process', '애드혹 하위 프로세스', 'mdi-shuffle-variant', true, 80),
        ('bpmn:CallActivity', 'Call Activity', '호출 활동', 'bpmn-icon-call-activity', true, 90),
        ('bpmn:SubProcess', 'Sub Process', '하위 프로세스', 'bpmn-icon-subprocess-collapsed', true, 100),
        ('bpmn:Transaction', 'Transaction', '트랜잭션', 'bpmn-icon-transaction', true, 110)
)
INSERT INTO public.palette_task_types (
    id,
    tenant_id,
    task_type,
    label,
    label_ko,
    icon,
    is_enabled,
    display_order
)
SELECT
    gen_random_uuid(),
    t.id,
    d.task_type,
    d.label,
    d.label_ko,
    d.icon,
    d.is_enabled,
    d.display_order
FROM public.tenants t
CROSS JOIN default_task_types d
ON CONFLICT (tenant_id, task_type) DO NOTHING;

WITH default_settings AS (
    SELECT
        to_jsonb(ARRAY[
            'bpmn:Task',
            'bpmn:ManualTask',
            'bpmn:ServiceTask',
            'bpmn:UserTask',
            'bpmn:ScriptTask',
            'bpmn:BusinessRuleTask',
            'bpmn:SendTask',
            'bpmn:ReceiveTask',
            'bpmn:CallActivity',
            'bpmn:SubProcess',
            'bpmn:AdHocSubProcess',
            'bpmn:Transaction'
        ]::text[]) AS visible_task_types,
        to_jsonb(ARRAY[
            'replace-with-none-start',
            'replace-with-message-start',
            'replace-with-timer-start',
            'replace-with-conditional-start',
            'replace-with-signal-start',
            'replace-with-error-start',
            'replace-with-escalation-start',
            'replace-with-compensation-start',
            'replace-with-non-interrupting-message-start',
            'replace-with-non-interrupting-timer-start',
            'replace-with-non-interrupting-conditional-start',
            'replace-with-non-interrupting-signal-start',
            'replace-with-non-interrupting-escalation-start',
            'replace-with-none-intermediate-throw',
            'replace-with-message-intermediate-catch',
            'replace-with-message-intermediate-throw',
            'replace-with-timer-intermediate-catch',
            'replace-with-escalation-intermediate-throw',
            'replace-with-conditional-intermediate-catch',
            'replace-with-link-intermediate-catch',
            'replace-with-link-intermediate-throw',
            'replace-with-compensation-intermediate-throw',
            'replace-with-signal-intermediate-catch',
            'replace-with-signal-intermediate-throw',
            'replace-with-none-end',
            'replace-with-message-end',
            'replace-with-escalation-end',
            'replace-with-error-end',
            'replace-with-cancel-end',
            'replace-with-compensation-end',
            'replace-with-signal-end',
            'replace-with-terminate-end',
            'replace-with-message-boundary',
            'replace-with-timer-boundary',
            'replace-with-escalation-boundary',
            'replace-with-conditional-boundary',
            'replace-with-error-boundary',
            'replace-with-cancel-boundary',
            'replace-with-signal-boundary',
            'replace-with-compensation-boundary',
            'replace-with-non-interrupting-message-boundary',
            'replace-with-non-interrupting-timer-boundary',
            'replace-with-non-interrupting-escalation-boundary',
            'replace-with-non-interrupting-conditional-boundary',
            'replace-with-non-interrupting-signal-boundary'
        ]::text[]) AS visible_event_types
)
INSERT INTO public.configuration (key, value, tenant_id)
SELECT
    'palette_settings',
    jsonb_build_object(
        'visibleTaskTypes', d.visible_task_types,
        'visibleEventTypes', d.visible_event_types
    ),
    t.id
FROM public.tenants t
CROSS JOIN default_settings d
WHERE NOT EXISTS (
    SELECT 1
    FROM public.configuration c
    WHERE c.key = 'palette_settings'
      AND c.tenant_id = t.id
);

WITH default_settings AS (
    SELECT to_jsonb(ARRAY[
        'replace-with-none-start',
        'replace-with-message-start',
        'replace-with-timer-start',
        'replace-with-conditional-start',
        'replace-with-signal-start',
        'replace-with-error-start',
        'replace-with-escalation-start',
        'replace-with-compensation-start',
        'replace-with-non-interrupting-message-start',
        'replace-with-non-interrupting-timer-start',
        'replace-with-non-interrupting-conditional-start',
        'replace-with-non-interrupting-signal-start',
        'replace-with-non-interrupting-escalation-start',
        'replace-with-none-intermediate-throw',
        'replace-with-message-intermediate-catch',
        'replace-with-message-intermediate-throw',
        'replace-with-timer-intermediate-catch',
        'replace-with-escalation-intermediate-throw',
        'replace-with-conditional-intermediate-catch',
        'replace-with-link-intermediate-catch',
        'replace-with-link-intermediate-throw',
        'replace-with-compensation-intermediate-throw',
        'replace-with-signal-intermediate-catch',
        'replace-with-signal-intermediate-throw',
        'replace-with-none-end',
        'replace-with-message-end',
        'replace-with-escalation-end',
        'replace-with-error-end',
        'replace-with-cancel-end',
        'replace-with-compensation-end',
        'replace-with-signal-end',
        'replace-with-terminate-end',
        'replace-with-message-boundary',
        'replace-with-timer-boundary',
        'replace-with-escalation-boundary',
        'replace-with-conditional-boundary',
        'replace-with-error-boundary',
        'replace-with-cancel-boundary',
        'replace-with-signal-boundary',
        'replace-with-compensation-boundary',
        'replace-with-non-interrupting-message-boundary',
        'replace-with-non-interrupting-timer-boundary',
        'replace-with-non-interrupting-escalation-boundary',
        'replace-with-non-interrupting-conditional-boundary',
        'replace-with-non-interrupting-signal-boundary'
    ]::text[]) AS visible_event_types
)
UPDATE public.configuration c
SET value = jsonb_set(
    COALESCE(c.value, '{}'::jsonb),
    '{visibleEventTypes}',
    d.visible_event_types,
    true
)
FROM default_settings d
WHERE c.key = 'palette_settings'
  AND NOT (COALESCE(c.value, '{}'::jsonb) ? 'visibleEventTypes');
