-- Migration: 프로세스 정의 댓글 및 승인 상태 관리
-- Date: 2026-01-30
-- Description: 노드 단위 댓글과 프로세스 승인 워크플로우 지원

-- =====================================================
-- 1. 프로세스 정의 댓글 테이블 (노드 단위 댓글)
-- =====================================================

CREATE TABLE IF NOT EXISTS proc_def_comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    proc_def_id TEXT NOT NULL,
    element_id TEXT NOT NULL,           -- BPMN 요소 ID (Task_a, Gateway_1 등)
    element_type TEXT,                  -- 요소 타입 (bpmn:UserTask, bpmn:Gateway 등)
    element_name TEXT,                  -- 요소 이름 (표시용)
    author_id TEXT NOT NULL,            -- 작성자 ID
    author_name TEXT,                   -- 작성자 이름 (캐시)
    content TEXT NOT NULL,              -- 댓글 내용
    parent_comment_id UUID REFERENCES proc_def_comments(id) ON DELETE CASCADE, -- 답글용 부모 댓글
    is_resolved BOOLEAN DEFAULT FALSE,  -- 해결됨 여부
    resolved_by TEXT,                   -- 해결 처리자
    resolved_at TIMESTAMPTZ,            -- 해결 시간
    tenant_id TEXT DEFAULT 'default',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 인덱스 생성
CREATE INDEX IF NOT EXISTS idx_proc_def_comments_def_element ON proc_def_comments(proc_def_id, element_id);
CREATE INDEX IF NOT EXISTS idx_proc_def_comments_parent ON proc_def_comments(parent_comment_id);
CREATE INDEX IF NOT EXISTS idx_proc_def_comments_tenant ON proc_def_comments(tenant_id);

-- =====================================================
-- 2. 프로세스 정의 승인 상태 테이블
-- =====================================================

CREATE TABLE IF NOT EXISTS proc_def_approval_state (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    proc_def_id TEXT NOT NULL UNIQUE,

    -- 현재 상태: draft → review → approved_level1 → approved_level2 → confirmed
    state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'review', 'approved_level1', 'approved_level2', 'confirmed', 'rejected')),

    -- 검토 요청 정보
    submitted_by TEXT,                  -- 검토 요청자
    submitted_at TIMESTAMPTZ,           -- 검토 요청 시간
    submit_comment TEXT,                -- 검토 요청 코멘트

    -- 1차 승인 정보
    reviewer_level1_id TEXT,            -- 1차 검토자 ID
    reviewer_level1_name TEXT,          -- 1차 검토자 이름
    reviewed_at_level1 TIMESTAMPTZ,     -- 1차 검토 시간
    review_comment_level1 TEXT,         -- 1차 검토 코멘트

    -- 2차 승인 정보
    reviewer_level2_id TEXT,            -- 2차 검토자 ID
    reviewer_level2_name TEXT,          -- 2차 검토자 이름
    reviewed_at_level2 TIMESTAMPTZ,     -- 2차 검토 시간
    review_comment_level2 TEXT,         -- 2차 검토 코멘트

    -- 최종 확정 정보
    confirmed_by_id TEXT,               -- 최종 확정자 ID
    confirmed_by_name TEXT,             -- 최종 확정자 이름
    confirmed_at TIMESTAMPTZ,           -- 최종 확정 시간
    confirm_comment TEXT,               -- 확정 코멘트

    -- 반려 정보
    rejected_by_id TEXT,                -- 반려자 ID
    rejected_by_name TEXT,              -- 반려자 이름
    rejected_at TIMESTAMPTZ,            -- 반려 시간
    reject_comment TEXT,                -- 반려 사유

    tenant_id TEXT DEFAULT 'default',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 인덱스 생성
CREATE INDEX IF NOT EXISTS idx_proc_def_approval_state_def ON proc_def_approval_state(proc_def_id);
CREATE INDEX IF NOT EXISTS idx_proc_def_approval_state_status ON proc_def_approval_state(state);
CREATE INDEX IF NOT EXISTS idx_proc_def_approval_state_tenant ON proc_def_approval_state(tenant_id);

-- =====================================================
-- 3. 승인 이력 테이블 (변경 추적)
-- =====================================================

CREATE TABLE IF NOT EXISTS proc_def_approval_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    proc_def_id TEXT NOT NULL,
    action TEXT NOT NULL,               -- submit, approve_level1, approve_level2, confirm, reject, reopen
    from_state TEXT,                    -- 이전 상태
    to_state TEXT NOT NULL,             -- 변경 후 상태
    actor_id TEXT NOT NULL,             -- 행위자 ID
    actor_name TEXT,                    -- 행위자 이름
    comment TEXT,                       -- 코멘트
    tenant_id TEXT DEFAULT 'default',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 인덱스 생성
CREATE INDEX IF NOT EXISTS idx_proc_def_approval_history_def ON proc_def_approval_history(proc_def_id);
CREATE INDEX IF NOT EXISTS idx_proc_def_approval_history_tenant ON proc_def_approval_history(tenant_id);

-- =====================================================
-- 4. RLS 정책 (Row Level Security)
-- =====================================================

-- proc_def_comments RLS
ALTER TABLE proc_def_comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "proc_def_comments_select_policy" ON proc_def_comments
    FOR SELECT USING (true);

CREATE POLICY "proc_def_comments_insert_policy" ON proc_def_comments
    FOR INSERT WITH CHECK (true);

CREATE POLICY "proc_def_comments_update_policy" ON proc_def_comments
    FOR UPDATE USING (true);

CREATE POLICY "proc_def_comments_delete_policy" ON proc_def_comments
    FOR DELETE USING (true);

-- proc_def_approval_state RLS
ALTER TABLE proc_def_approval_state ENABLE ROW LEVEL SECURITY;

CREATE POLICY "proc_def_approval_state_select_policy" ON proc_def_approval_state
    FOR SELECT USING (true);

CREATE POLICY "proc_def_approval_state_insert_policy" ON proc_def_approval_state
    FOR INSERT WITH CHECK (true);

CREATE POLICY "proc_def_approval_state_update_policy" ON proc_def_approval_state
    FOR UPDATE USING (true);

-- proc_def_approval_history RLS
ALTER TABLE proc_def_approval_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY "proc_def_approval_history_select_policy" ON proc_def_approval_history
    FOR SELECT USING (true);

CREATE POLICY "proc_def_approval_history_insert_policy" ON proc_def_approval_history
    FOR INSERT WITH CHECK (true);

-- =====================================================
-- 5. 트리거: updated_at 자동 갱신
-- =====================================================

CREATE OR REPLACE FUNCTION update_proc_def_comments_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER proc_def_comments_updated_at_trigger
    BEFORE UPDATE ON proc_def_comments
    FOR EACH ROW
    EXECUTE FUNCTION update_proc_def_comments_updated_at();

CREATE OR REPLACE FUNCTION update_proc_def_approval_state_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER proc_def_approval_state_updated_at_trigger
    BEFORE UPDATE ON proc_def_approval_state
    FOR EACH ROW
    EXECUTE FUNCTION update_proc_def_approval_state_updated_at();

-- =====================================================
-- 6. 댓글 개수 집계 뷰
-- =====================================================

CREATE OR REPLACE VIEW proc_def_element_comment_counts AS
SELECT
    proc_def_id,
    element_id,
    COUNT(*) as total_count,
    COUNT(*) FILTER (WHERE NOT is_resolved) as unresolved_count,
    COUNT(*) FILTER (WHERE is_resolved) as resolved_count
FROM proc_def_comments
WHERE parent_comment_id IS NULL  -- 최상위 댓글만 카운트
GROUP BY proc_def_id, element_id;
