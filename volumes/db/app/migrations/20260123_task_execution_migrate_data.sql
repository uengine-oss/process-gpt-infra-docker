-- =============================================================================
-- 기존 todolist 데이터를 task_execution_properties로 마이그레이션
-- =============================================================================

INSERT INTO public.task_execution_properties (
    tenant_id,
    proc_def_id,
    proc_inst_id,
    activity_id,
    activity_name,
    todo_id,
    tool,
    execution_status,
    started_at,
    completed_at,
    actual_duration,
    executor_email
)
SELECT
    t.tenant_id,
    t.proc_def_id,
    t.proc_inst_id,
    t.activity_id,
    t.activity_name,
    t.id,
    t.tool,
    CASE
        WHEN t.status::text IN ('DONE', 'COMPLETED') THEN 'COMPLETED'
        WHEN t.status::text = 'CANCELLED' THEN 'CANCELLED'
        ELSE 'STARTED'
    END,
    COALESCE(t.start_date, now()),
    CASE WHEN t.status::text IN ('DONE', 'COMPLETED', 'CANCELLED') THEN COALESCE(t.end_date, t.updated_at) ELSE NULL END,
    CASE WHEN t.status::text IN ('DONE', 'COMPLETED', 'CANCELLED') THEN COALESCE(t.end_date, t.updated_at) - COALESCE(t.start_date, now()) ELSE NULL END,
    t.user_id
FROM public.todolist t
WHERE NOT EXISTS (
    SELECT 1 FROM public.task_execution_properties tep WHERE tep.todo_id = t.id
)
ON CONFLICT DO NOTHING;
