-- ============================================
-- FTE Heatmap Configuration Tables
-- ============================================

-- 1. Activity별 표준 작업 시간 설정
CREATE TABLE IF NOT EXISTS public.activity_config (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id VARCHAR(255) NOT NULL,
    proc_def_id VARCHAR(255) NOT NULL,
    activity_id VARCHAR(255) NOT NULL,
    activity_name VARCHAR(500),

    -- FTE 계산 관련
    standard_minutes INTEGER DEFAULT 30,          -- 표준 작업 시간 (분)
    role_name VARCHAR(255),                       -- 담당 역할/레인
    complexity_factor DECIMAL(3,2) DEFAULT 1.0,   -- 복잡도 계수 (0.5 ~ 2.0)

    -- 메타데이터
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    created_by VARCHAR(255),

    CONSTRAINT activity_config_unique UNIQUE (tenant_id, proc_def_id, activity_id)
);

-- 2. Role/팀별 FTE 용량 설정
CREATE TABLE IF NOT EXISTS public.fte_capacity (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id VARCHAR(255) NOT NULL,

    role_name VARCHAR(255) NOT NULL,              -- 역할명 (예: 'Approver', 'Reviewer')
    available_fte DECIMAL(5,2) DEFAULT 1.0,       -- 가용 FTE 수
    hours_per_day DECIMAL(4,2) DEFAULT 8.0,       -- 일일 근무시간
    working_days_per_month INTEGER DEFAULT 20,    -- 월 근무일수

    -- 계산된 값 (편의용)
    monthly_capacity_hours DECIMAL(8,2) GENERATED ALWAYS AS (available_fte * hours_per_day * working_days_per_month) STORED,

    -- 메타데이터
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),

    CONSTRAINT fte_capacity_unique UNIQUE (tenant_id, role_name)
);

-- 3. FTE 스냅샷 (시계열 분석용, 선택적)
CREATE TABLE IF NOT EXISTS public.fte_snapshot (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id VARCHAR(255) NOT NULL,
    proc_def_id VARCHAR(255) NOT NULL,
    activity_id VARCHAR(255) NOT NULL,

    snapshot_date DATE NOT NULL,

    -- FTE 지표들
    instance_count INTEGER DEFAULT 0,
    total_work_minutes INTEGER DEFAULT 0,
    workload_fte DECIMAL(8,4) DEFAULT 0,
    peak_concurrent INTEGER DEFAULT 0,
    peak_fte DECIMAL(8,4) DEFAULT 0,
    load_ratio DECIMAL(5,4) DEFAULT 0,

    created_at TIMESTAMPTZ DEFAULT now(),

    CONSTRAINT fte_snapshot_unique UNIQUE (tenant_id, proc_def_id, activity_id, snapshot_date)
);

-- 인덱스
CREATE INDEX IF NOT EXISTS idx_activity_config_tenant_proc ON public.activity_config(tenant_id, proc_def_id);
CREATE INDEX IF NOT EXISTS idx_fte_capacity_tenant ON public.fte_capacity(tenant_id);
CREATE INDEX IF NOT EXISTS idx_fte_snapshot_date ON public.fte_snapshot(tenant_id, proc_def_id, snapshot_date);

-- RLS 정책
ALTER TABLE public.activity_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fte_capacity ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fte_snapshot ENABLE ROW LEVEL SECURITY;

-- activity_config RLS
CREATE POLICY "activity_config_tenant_isolation" ON public.activity_config
    FOR ALL USING (tenant_id = current_setting('app.tenant_id', true));

CREATE POLICY "activity_config_public_read" ON public.activity_config
    FOR SELECT USING (true);

CREATE POLICY "activity_config_public_write" ON public.activity_config
    FOR ALL USING (true);

-- fte_capacity RLS
CREATE POLICY "fte_capacity_tenant_isolation" ON public.fte_capacity
    FOR ALL USING (tenant_id = current_setting('app.tenant_id', true));

CREATE POLICY "fte_capacity_public_read" ON public.fte_capacity
    FOR SELECT USING (true);

CREATE POLICY "fte_capacity_public_write" ON public.fte_capacity
    FOR ALL USING (true);

-- fte_snapshot RLS
CREATE POLICY "fte_snapshot_tenant_isolation" ON public.fte_snapshot
    FOR ALL USING (tenant_id = current_setting('app.tenant_id', true));

CREATE POLICY "fte_snapshot_public_read" ON public.fte_snapshot
    FOR SELECT USING (true);

-- updated_at 트리거
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER activity_config_updated_at
    BEFORE UPDATE ON public.activity_config
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER fte_capacity_updated_at
    BEFORE UPDATE ON public.fte_capacity
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- 기본 데이터 삽입 (예시)
-- INSERT INTO public.fte_capacity (tenant_id, role_name, available_fte, hours_per_day, working_days_per_month)
-- VALUES
--     ('default', 'Default', 5.0, 8.0, 20),
--     ('default', 'Approver', 2.0, 8.0, 20),
--     ('default', 'Reviewer', 3.0, 8.0, 20);

COMMENT ON TABLE public.activity_config IS 'Activity별 FTE 계산을 위한 표준 작업 시간 설정';
COMMENT ON TABLE public.fte_capacity IS 'Role/팀별 가용 FTE 용량 설정';
COMMENT ON TABLE public.fte_snapshot IS 'FTE 지표 일별 스냅샷 (시계열 분석용)';
