-- Task 실행 속성 저장 테이블
-- 프로세스 실행 시 Task의 properties를 저장하여 분석에 활용

-- 1. task_execution_properties 테이블 생성
CREATE TABLE IF NOT EXISTS public.task_execution_properties (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id text DEFAULT public.tenant_id(),

    -- 실행 컨텍스트 정보
    proc_def_id text NOT NULL,
    proc_inst_id text NOT NULL,
    activity_id text NOT NULL,
    activity_name text,
    todo_id uuid,

    -- Task 속성
    role text,
    duration integer,
    instruction text,
    description text,
    checkpoints text[],

    -- AI/Agent 관련 속성
    agent_id text,
    agent_mode text,
    orchestration text,
    tool text,

    -- 시스템 정보
    system_name text,
    menu_name text,

    -- JSONB 확장 데이터
    input_data jsonb DEFAULT '[]'::jsonb,
    custom_properties jsonb DEFAULT '[]'::jsonb,

    -- 실행 결과
    execution_status text NOT NULL DEFAULT 'STARTED',
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    actual_duration interval,
    executor_email text,

    CONSTRAINT task_execution_properties_tenant_fkey
        FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON UPDATE CASCADE ON DELETE CASCADE
);

-- 2. 인덱스 생성
CREATE INDEX IF NOT EXISTS idx_tep_tenant_proc_def ON task_execution_properties(tenant_id, proc_def_id);
CREATE INDEX IF NOT EXISTS idx_tep_proc_inst ON task_execution_properties(proc_inst_id);
CREATE INDEX IF NOT EXISTS idx_tep_activity ON task_execution_properties(activity_id);
CREATE INDEX IF NOT EXISTS idx_tep_started_at ON task_execution_properties(started_at DESC);
CREATE INDEX IF NOT EXISTS idx_tep_execution_status ON task_execution_properties(execution_status);

-- 3. RLS 정책 설정
ALTER TABLE public.task_execution_properties ENABLE ROW LEVEL SECURITY;

CREATE POLICY "task_execution_properties_tenant_isolation" ON public.task_execution_properties
    FOR ALL USING (tenant_id = public.tenant_id());
