-- Standard Terminology Table for Term Autocomplete
-- Phase 5: Process Authoring Enhancement

-- 표준 용어 사전 테이블
CREATE TABLE IF NOT EXISTS standard_terminology (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id TEXT NOT NULL DEFAULT 'default',
    category TEXT NOT NULL,  -- 'task_name', 'lane_name', 'gateway_name', 'event_name', 'condition'
    term TEXT NOT NULL,
    description TEXT,
    usage_count INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(tenant_id, category, term)
);

-- 사용 빈도 기반 자동 학습을 위한 인덱스
CREATE INDEX IF NOT EXISTS idx_terminology_tenant_category ON standard_terminology(tenant_id, category);
CREATE INDEX IF NOT EXISTS idx_terminology_usage ON standard_terminology(tenant_id, category, usage_count DESC);

-- RLS 정책
ALTER TABLE standard_terminology ENABLE ROW LEVEL SECURITY;

-- 테넌트별 접근 정책
CREATE POLICY "tenant_isolation" ON standard_terminology
    FOR ALL
    USING (tenant_id = current_setting('app.tenant_id', true)::text OR tenant_id = 'default');

-- 기본 용어 삽입 (공통)
INSERT INTO standard_terminology (tenant_id, category, term, description, usage_count)
VALUES
    -- Task 이름 용어
    ('default', 'task_name', '검토', 'Review task', 100),
    ('default', 'task_name', '승인', 'Approval task', 100),
    ('default', 'task_name', '결재', 'Approval/Sign-off task', 100),
    ('default', 'task_name', '작성', 'Create/Write task', 100),
    ('default', 'task_name', '등록', 'Register task', 100),
    ('default', 'task_name', '수정', 'Modify/Edit task', 100),
    ('default', 'task_name', '삭제', 'Delete task', 100),
    ('default', 'task_name', '조회', 'Query/View task', 100),
    ('default', 'task_name', '전송', 'Send/Transfer task', 100),
    ('default', 'task_name', '접수', 'Receive/Accept task', 100),
    ('default', 'task_name', '처리', 'Process/Handle task', 100),
    ('default', 'task_name', '확인', 'Confirm/Check task', 100),
    ('default', 'task_name', '요청', 'Request task', 100),
    ('default', 'task_name', '완료', 'Complete task', 100),
    ('default', 'task_name', '반려', 'Reject task', 100),

    -- Lane 이름 용어 (역할/부서)
    ('default', 'lane_name', '담당자', 'Person in charge', 100),
    ('default', 'lane_name', '팀장', 'Team leader', 100),
    ('default', 'lane_name', '부장', 'Department head', 100),
    ('default', 'lane_name', '기획팀', 'Planning team', 100),
    ('default', 'lane_name', '개발팀', 'Development team', 100),
    ('default', 'lane_name', '영업팀', 'Sales team', 100),
    ('default', 'lane_name', '인사팀', 'HR team', 100),
    ('default', 'lane_name', '재무팀', 'Finance team', 100),
    ('default', 'lane_name', '고객', 'Customer', 100),
    ('default', 'lane_name', '시스템', 'System', 100),

    -- 조건 표현식 용어
    ('default', 'condition', '승인', 'Approved condition', 100),
    ('default', 'condition', '반려', 'Rejected condition', 100),
    ('default', 'condition', '보류', 'Pending condition', 100),
    ('default', 'condition', '완료', 'Completed condition', 100),
    ('default', 'condition', '취소', 'Cancelled condition', 100)
ON CONFLICT (tenant_id, category, term) DO NOTHING;

-- 용어 사용 시 usage_count 증가 함수
CREATE OR REPLACE FUNCTION increment_terminology_usage(
    p_tenant_id TEXT,
    p_category TEXT,
    p_term TEXT
) RETURNS VOID AS $$
BEGIN
    UPDATE standard_terminology
    SET usage_count = usage_count + 1,
        updated_at = NOW()
    WHERE tenant_id = p_tenant_id
      AND category = p_category
      AND term = p_term;

    -- 용어가 없으면 새로 추가
    IF NOT FOUND THEN
        INSERT INTO standard_terminology (tenant_id, category, term, usage_count)
        VALUES (p_tenant_id, p_category, p_term, 1)
        ON CONFLICT (tenant_id, category, term) DO UPDATE
        SET usage_count = standard_terminology.usage_count + 1,
            updated_at = NOW();
    END IF;
END;
$$ LANGUAGE plpgsql;
