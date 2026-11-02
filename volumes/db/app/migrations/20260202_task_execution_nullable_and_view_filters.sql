-- =============================================================================
-- proc_def_id, activity_id NULL 허용 및 뷰 null 필터링
-- formHandler 등 standalone task 지원, BPM 분석 뷰는 프로세스 컨텍스트 있는 행만 대상
-- =============================================================================

-- 1. task_execution_properties: proc_def_id, activity_id NULL 허용
ALTER TABLE public.task_execution_properties
    ALTER COLUMN proc_def_id DROP NOT NULL,
    ALTER COLUMN activity_id DROP NOT NULL;

-- 2. v_activity_bottleneck: proc_inst_id, activity_id가 있는 todolist만 (활동별 병목 분석)
CREATE OR REPLACE VIEW public.v_activity_bottleneck AS
WITH task_sequence AS (
    SELECT
        t.id,
        t.proc_inst_id,
        t.activity_id,
        t.activity_name,
        t.tenant_id,
        t.start_date,
        t.end_date,
        LAG(t.end_date) OVER (PARTITION BY t.proc_inst_id ORDER BY t.start_date) AS prev_end_date,
        EXTRACT(EPOCH FROM (t.end_date - t.start_date)) AS processing_time_sec
    FROM public.todolist t
    WHERE t.start_date IS NOT NULL
      AND t.proc_inst_id IS NOT NULL
      AND t.activity_id IS NOT NULL
)
SELECT
    ts.activity_id,
    ts.activity_name,
    ts.tenant_id,
    COUNT(*) AS execution_count,
    AVG(ts.processing_time_sec) AS avg_processing_time_sec,
    AVG(EXTRACT(EPOCH FROM (ts.start_date - ts.prev_end_date))) AS avg_wait_time_sec,
    SUM(ts.processing_time_sec) AS total_processing_time_sec,
    SUM(EXTRACT(EPOCH FROM (ts.start_date - ts.prev_end_date))) AS total_wait_time_sec
FROM task_sequence ts
GROUP BY ts.activity_id, ts.activity_name, ts.tenant_id;

-- 3. v_sla_compliance: proc_def_id, activity_id가 있는 todolist만 (프로세스/활동 단위 SLA)
CREATE OR REPLACE VIEW public.v_sla_compliance AS
SELECT
    t.proc_def_id,
    pd.name AS process_name,
    t.activity_id,
    t.activity_name,
    t.tenant_id,
    COUNT(*) AS total_tasks,
    COUNT(CASE WHEN t.due_date IS NOT NULL AND t.end_date <= t.due_date THEN 1 END) AS on_time_tasks,
    COUNT(CASE WHEN t.due_date IS NOT NULL AND t.end_date > t.due_date THEN 1 END) AS overdue_tasks,
    CASE
        WHEN COUNT(CASE WHEN t.due_date IS NOT NULL THEN 1 END) > 0
        THEN ROUND(
            100.0 * COUNT(CASE WHEN t.due_date IS NOT NULL AND t.end_date <= t.due_date THEN 1 END)
            / COUNT(CASE WHEN t.due_date IS NOT NULL THEN 1 END), 2
        )
        ELSE NULL
    END AS sla_compliance_rate
FROM public.todolist t
LEFT JOIN public.proc_def pd ON t.proc_def_id = pd.id AND t.tenant_id = pd.tenant_id
WHERE t.status = 'DONE'
  AND t.proc_def_id IS NOT NULL
  AND t.activity_id IS NOT NULL
GROUP BY t.proc_def_id, pd.name, t.activity_id, t.activity_name, t.tenant_id;
