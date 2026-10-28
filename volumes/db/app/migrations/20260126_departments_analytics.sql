-- ============================================
-- 부서 테이블 및 Analytics 지원을 위한 마이그레이션
-- 부서별 Task 통계 및 BPM 표준 분석을 위한 스키마 확장
-- ============================================

-- 1. 부서(Department) 테이블 생성
CREATE TABLE IF NOT EXISTS public.departments (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    parent_id TEXT REFERENCES public.departments(id) ON DELETE SET NULL,
    tenant_id TEXT DEFAULT public.tenant_id(),
    level INTEGER DEFAULT 0,
    path TEXT, -- 계층 경로 (예: /회사/본부/팀)
    manager_email TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT departments_tenant_fkey FOREIGN KEY (tenant_id)
        REFERENCES tenants(id) ON UPDATE CASCADE ON DELETE CASCADE
);

-- 부서 테이블 인덱스
CREATE INDEX IF NOT EXISTS idx_departments_tenant ON public.departments(tenant_id);
CREATE INDEX IF NOT EXISTS idx_departments_parent ON public.departments(parent_id);
CREATE INDEX IF NOT EXISTS idx_departments_path ON public.departments(path);

-- 2. users 테이블에 부서 컬럼 추가
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'users' AND column_name = 'department_id') THEN
        ALTER TABLE public.users ADD COLUMN department_id TEXT;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'users' AND column_name = 'department_name') THEN
        ALTER TABLE public.users ADD COLUMN department_name TEXT;
    END IF;
END $$;

-- users 부서 인덱스
CREATE INDEX IF NOT EXISTS idx_users_department ON public.users(department_id);

-- 3. todolist 테이블에 실행자 부서 정보 추가 (비정규화 - 분석 편의)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'todolist' AND column_name = 'executor_dept_id') THEN
        ALTER TABLE public.todolist ADD COLUMN executor_dept_id TEXT;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'todolist' AND column_name = 'executor_dept_name') THEN
        ALTER TABLE public.todolist ADD COLUMN executor_dept_name TEXT;
    END IF;
END $$;

-- todolist 부서 인덱스
CREATE INDEX IF NOT EXISTS idx_todolist_executor_dept ON public.todolist(executor_dept_id);

-- 4. task_execution_properties 테이블에 부서 정보 추가
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'task_execution_properties' AND column_name = 'executor_dept_id') THEN
        ALTER TABLE public.task_execution_properties ADD COLUMN executor_dept_id TEXT;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'task_execution_properties' AND column_name = 'executor_dept_name') THEN
        ALTER TABLE public.task_execution_properties ADD COLUMN executor_dept_name TEXT;
    END IF;
END $$;

-- 5. BPM Analytics를 위한 집계 뷰 생성

-- 5-1. 부서별 Task 통계 뷰
CREATE OR REPLACE VIEW public.v_department_task_stats AS
SELECT
    COALESCE(t.executor_dept_id, u.department_id, 'UNASSIGNED') AS dept_id,
    COALESCE(t.executor_dept_name, u.department_name, '미지정') AS dept_name,
    t.tenant_id,
    COUNT(*) AS total_tasks,
    COUNT(CASE WHEN t.agent_orch IS NOT NULL THEN 1 END) AS agent_tasks,
    COUNT(CASE WHEN t.agent_orch IS NULL AND t.user_id IS NOT NULL THEN 1 END) AS human_tasks,
    COUNT(CASE WHEN t.status = 'DONE' THEN 1 END) AS completed_tasks,
    COUNT(CASE WHEN t.status IN ('NEW', 'TODO', 'IN_PROGRESS') THEN 1 END) AS pending_tasks,
    AVG(EXTRACT(EPOCH FROM (t.end_date - t.start_date))) AS avg_duration_sec,
    SUM(COALESCE(t.rework_count, 0)) AS total_rework,
    COUNT(CASE WHEN t.rework_count > 0 THEN 1 END) AS tasks_with_rework
FROM public.todolist t
LEFT JOIN public.users u ON t.user_id = u.id::text AND t.tenant_id = u.tenant_id
WHERE t.start_date IS NOT NULL
GROUP BY COALESCE(t.executor_dept_id, u.department_id, 'UNASSIGNED'),
         COALESCE(t.executor_dept_name, u.department_name, '미지정'),
         t.tenant_id;

-- 5-2. 프로세스별 성능 통계 뷰 (Cycle Time, Throughput)
CREATE OR REPLACE VIEW public.v_process_performance AS
SELECT
    pi.proc_def_id,
    pd.name AS process_name,
    pi.tenant_id,
    COUNT(*) AS total_instances,
    COUNT(CASE WHEN pi.status = 'COMPLETED' THEN 1 END) AS completed_instances,
    COUNT(CASE WHEN pi.status = 'RUNNING' THEN 1 END) AS running_instances,
    AVG(EXTRACT(EPOCH FROM (pi.end_date - pi.start_date))) AS avg_cycle_time_sec,
    MIN(EXTRACT(EPOCH FROM (pi.end_date - pi.start_date))) AS min_cycle_time_sec,
    MAX(EXTRACT(EPOCH FROM (pi.end_date - pi.start_date))) AS max_cycle_time_sec,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (pi.end_date - pi.start_date))) AS median_cycle_time_sec,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (pi.end_date - pi.start_date))) AS p95_cycle_time_sec
FROM public.bpm_proc_inst pi
LEFT JOIN public.proc_def pd ON pi.proc_def_id = pd.id AND pi.tenant_id = pd.tenant_id
WHERE pi.is_deleted = false
GROUP BY pi.proc_def_id, pd.name, pi.tenant_id;

-- 5-3. 활동별 병목 분석 뷰 (Bottleneck Analysis)
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

-- 5-4. 월별 트렌드 뷰
CREATE OR REPLACE VIEW public.v_monthly_trend AS
SELECT
    DATE_TRUNC('month', t.start_date) AS month,
    t.tenant_id,
    COUNT(*) AS total_tasks,
    COUNT(CASE WHEN t.agent_orch IS NOT NULL THEN 1 END) AS agent_tasks,
    COUNT(CASE WHEN t.agent_orch IS NULL AND t.user_id IS NOT NULL THEN 1 END) AS human_tasks,
    COUNT(CASE WHEN t.status = 'DONE' THEN 1 END) AS completed_tasks,
    AVG(EXTRACT(EPOCH FROM (t.end_date - t.start_date))) AS avg_duration_sec,
    SUM(COALESCE(t.rework_count, 0)) AS total_rework
FROM public.todolist t
WHERE t.start_date IS NOT NULL
GROUP BY DATE_TRUNC('month', t.start_date), t.tenant_id
ORDER BY month DESC;

-- 5-5. SLA 준수율 뷰 (due_date 기준)
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
GROUP BY t.proc_def_id, pd.name, t.activity_id, t.activity_name, t.tenant_id;

-- 6. RLS 정책
ALTER TABLE public.departments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "departments_tenant_isolation" ON public.departments
    FOR ALL USING (tenant_id = public.tenant_id());

-- 7. 권한 부여
GRANT ALL ON public.departments TO authenticated;
GRANT SELECT ON public.departments TO anon;
GRANT SELECT ON public.v_department_task_stats TO authenticated;
GRANT SELECT ON public.v_process_performance TO authenticated;
GRANT SELECT ON public.v_activity_bottleneck TO authenticated;
GRANT SELECT ON public.v_monthly_trend TO authenticated;
GRANT SELECT ON public.v_sla_compliance TO authenticated;

-- 8. 조직도에서 부서 데이터 동기화 함수
CREATE OR REPLACE FUNCTION public.sync_departments_from_org_chart(p_tenant_id TEXT)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER := 0;
    v_org_chart JSONB;
    v_proc_def RECORD;
BEGIN
    -- proc_def에서 org_chart가 있는 정의 찾기
    FOR v_proc_def IN
        SELECT id, definition->>'org_chart' AS org_chart_json
        FROM public.proc_def
        WHERE tenant_id = p_tenant_id
        AND definition->>'org_chart' IS NOT NULL
        LIMIT 1
    LOOP
        -- 조직도 JSON 파싱 및 부서 추출 로직
        -- (실제 구현은 org_chart JSON 구조에 따라 조정 필요)
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 9. 사용자 부서 자동 업데이트 트리거
CREATE OR REPLACE FUNCTION public.update_user_department()
RETURNS TRIGGER AS $$
BEGIN
    -- department_id가 설정되면 department_name도 자동 업데이트
    IF NEW.department_id IS NOT NULL AND NEW.department_id != '' THEN
        SELECT name INTO NEW.department_name
        FROM public.departments
        WHERE id = NEW.department_id AND tenant_id = NEW.tenant_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_user_department ON public.users;
CREATE TRIGGER trg_update_user_department
    BEFORE INSERT OR UPDATE OF department_id ON public.users
    FOR EACH ROW
    EXECUTE FUNCTION public.update_user_department();

-- 10. todolist 실행자 부서 자동 설정 트리거
CREATE OR REPLACE FUNCTION public.set_todolist_executor_dept()
RETURNS TRIGGER AS $$
BEGIN
    -- user_id가 설정되면 해당 사용자의 부서 정보 가져오기
    IF NEW.user_id IS NOT NULL THEN
        SELECT department_id, department_name
        INTO NEW.executor_dept_id, NEW.executor_dept_name
        FROM public.users
        WHERE id::text = NEW.user_id AND tenant_id = NEW.tenant_id
        LIMIT 1;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_todolist_executor_dept ON public.todolist;
CREATE TRIGGER trg_set_todolist_executor_dept
    BEFORE INSERT OR UPDATE OF user_id ON public.todolist
    FOR EACH ROW
    EXECUTE FUNCTION public.set_todolist_executor_dept();

COMMENT ON TABLE public.departments IS '부서 테이블 - BPM 분석을 위한 조직 구조';
COMMENT ON VIEW public.v_department_task_stats IS '부서별 Task 통계';
COMMENT ON VIEW public.v_process_performance IS '프로세스 성능 지표 (Cycle Time, Throughput)';
COMMENT ON VIEW public.v_activity_bottleneck IS '활동별 병목 분석 (Wait Time, Processing Time)';
COMMENT ON VIEW public.v_monthly_trend IS '월별 Task 트렌드';
COMMENT ON VIEW public.v_sla_compliance IS 'SLA 준수율 통계';
