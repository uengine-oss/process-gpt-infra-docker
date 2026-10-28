-- =====================================================
-- 거버넌스 워크플로우 마이그레이션
-- Date: 2026-02-23
-- Description: 병렬 승인(HQ/Field), 공람 기간, Re-open 요청,
--              버전 체계(Major/Minor), 스냅샷 관리
-- 의존: 20260130_proc_def_comments_approval,
--       20260213_review_per_submission,
--       20260213_assigned_reviewer,
--       20260213_add_cancelled_state
-- =====================================================

-- =====================================================
-- 1. proc_def_approval_state 상태값 재설계
--    기존: draft, review, approved_level1, approved_level2, confirmed, rejected, cancelled
--    신규: draft, in_review, public_feedback, final_edit, published, reopen_requested, archived, rejected, cancelled
-- =====================================================

-- 기존 CHECK 제약 제거
ALTER TABLE proc_def_approval_state
  DROP CONSTRAINT IF EXISTS proc_def_approval_state_state_check;

-- 기존 데이터 마이그레이션: 상태값 변환
UPDATE proc_def_approval_state SET state = 'in_review' WHERE state = 'review';
UPDATE proc_def_approval_state SET state = 'published' WHERE state = 'confirmed';
-- approved_level1, approved_level2 → in_review (병렬 승인으로 통합)
UPDATE proc_def_approval_state SET state = 'in_review' WHERE state IN ('approved_level1', 'approved_level2');

-- 새로운 CHECK 제약 추가
ALTER TABLE proc_def_approval_state
  ADD CONSTRAINT proc_def_approval_state_state_check
  CHECK (state IN (
    'draft',              -- 초안 작성 (v0.x)
    'in_review',          -- 전문가 병렬 검토 (HQ + Field)
    'public_feedback',    -- 전사 30일 공람
    'final_edit',         -- 최종 편집 (공람 후)
    'published',          -- 배포 완료
    'reopen_requested',   -- 현장 개선 요청
    'archived',           -- 아카이빙 (차기 버전 배포 시)
    'rejected',           -- 반려
    'cancelled'           -- 취소
  ));

-- =====================================================
-- 2. 병렬 승인 컬럼 추가 (HQ + Field)
-- =====================================================

-- HQ(본사) 검토 정보
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS hq_reviewer_id TEXT;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS hq_reviewer_name TEXT;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS hq_reviewed_at TIMESTAMPTZ;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS hq_review_comment TEXT;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS hq_status TEXT DEFAULT 'pending'
  CHECK (hq_status IS NULL OR hq_status IN ('pending', 'approved', 'rejected'));

-- Field(현업) 검토 정보
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS field_reviewer_id TEXT;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS field_reviewer_name TEXT;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS field_reviewed_at TIMESTAMPTZ;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS field_review_comment TEXT;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS field_status TEXT DEFAULT 'pending'
  CHECK (field_status IS NULL OR field_status IN ('pending', 'approved', 'rejected'));

-- =====================================================
-- 3. 공람(Public Feedback) 기간 컬럼
-- =====================================================

ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS public_feedback_started_at TIMESTAMPTZ;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS public_feedback_ends_at TIMESTAMPTZ;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS public_feedback_auto_transitioned BOOLEAN DEFAULT FALSE;

-- =====================================================
-- 4. 버전 체계 컬럼 (Major/Minor)
-- =====================================================

ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS major_version INTEGER DEFAULT 0;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS minor_version INTEGER DEFAULT 1;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS version_label TEXT;  -- e.g. "v1.2"

-- =====================================================
-- 5. Re-open 요청 관련 컬럼
-- =====================================================

ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS reopen_requested_by TEXT;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS reopen_requested_at TIMESTAMPTZ;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS reopen_reason TEXT;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS reopen_approved_by TEXT;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS reopen_approved_at TIMESTAMPTZ;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS root_cause_review_id UUID;  -- 이 Draft가 생긴 원인 리뷰

-- =====================================================
-- 6. 최종 배포(Publish) 정보 컬럼 (기존 confirmed → published)
-- =====================================================

ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS published_by_id TEXT;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS published_by_name TEXT;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS published_at TIMESTAMPTZ;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS publish_comment TEXT;

-- =====================================================
-- 7. proc_def_approval_history action 확장
-- =====================================================

-- action 컬럼에 CHECK 제약이 없으므로 별도 제약 불필요
-- 새로운 action 값들:
--   submit, approve_hq, approve_field, reject_hq, reject_field,
--   start_public_feedback, auto_transition_final_edit,
--   publish, request_reopen, approve_reopen, reject_reopen,
--   reset_approvals, comment, reassign, cancel, archive

-- =====================================================
-- 8. 스냅샷 테이블 (단계별 BPMN 상태 보존)
-- =====================================================

CREATE TABLE IF NOT EXISTS proc_def_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    review_id UUID REFERENCES proc_def_approval_state(id) ON DELETE CASCADE,
    proc_def_id TEXT NOT NULL,
    stage TEXT NOT NULL,                    -- 스냅샷 시점의 stage (in_review, public_feedback, published 등)
    major_version INTEGER,
    minor_version INTEGER,
    bpmn_xml TEXT,                          -- BPMN XML 전체
    bpmn_json JSONB,                        -- 파싱된 요소 데이터 (비교용)
    metadata JSONB DEFAULT '{}',            -- 추가 메타데이터
    tenant_id TEXT DEFAULT 'default',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_proc_def_snapshots_review ON proc_def_snapshots(review_id);
CREATE INDEX IF NOT EXISTS idx_proc_def_snapshots_proc ON proc_def_snapshots(proc_def_id);
CREATE INDEX IF NOT EXISTS idx_proc_def_snapshots_tenant ON proc_def_snapshots(tenant_id);

-- RLS
ALTER TABLE proc_def_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY "proc_def_snapshots_select" ON proc_def_snapshots FOR SELECT USING (true);
CREATE POLICY "proc_def_snapshots_insert" ON proc_def_snapshots FOR INSERT WITH CHECK (true);
CREATE POLICY "proc_def_snapshots_delete" ON proc_def_snapshots FOR DELETE USING (true);

GRANT ALL ON proc_def_snapshots TO authenticated;

-- =====================================================
-- 9. proc_def_comments 확장: Resolve 시 조치 내용 필수
-- =====================================================

ALTER TABLE proc_def_comments ADD COLUMN IF NOT EXISTS resolve_action_text TEXT;  -- 조치 내용 (Action Taken)
ALTER TABLE proc_def_comments ADD COLUMN IF NOT EXISTS reviewer_type TEXT          -- 본사/현업/상신자/공람 구분
  CHECK (reviewer_type IS NULL OR reviewer_type IN ('hq', 'field', 'owner', 'public'));

-- =====================================================
-- 10. v_review_board 뷰 재작성 (병렬 승인 + 공람 + 버전)
-- =====================================================

DROP VIEW IF EXISTS v_review_board;
CREATE VIEW v_review_board AS
SELECT
    pas.id AS review_id,
    pas.proc_def_id,
    pd.name AS process_name,
    pd.owner,
    pas.state,
    pas.version,
    pas.version_label,
    pas.major_version,
    pas.minor_version,
    -- 제출 정보
    pas.submitted_by,
    pas.submitted_at,
    -- 병렬 승인 (HQ)
    pas.hq_reviewer_id, pas.hq_reviewer_name, pas.hq_reviewed_at, pas.hq_status,
    -- 병렬 승인 (Field)
    pas.field_reviewer_id, pas.field_reviewer_name, pas.field_reviewed_at, pas.field_status,
    -- 공람 기간
    pas.public_feedback_started_at, pas.public_feedback_ends_at,
    CASE
        WHEN pas.state = 'public_feedback' AND pas.public_feedback_ends_at IS NOT NULL
        THEN EXTRACT(DAY FROM pas.public_feedback_ends_at - NOW())::INTEGER
        ELSE NULL
    END AS public_feedback_days_remaining,
    -- 배포 정보
    pas.published_by_name, pas.published_at,
    -- 반려 정보
    pas.rejected_by_name, pas.rejected_at, pas.reject_comment,
    -- Re-open 정보
    pas.reopen_requested_by, pas.reopen_requested_at, pas.reopen_reason,
    -- 담당자
    pas.assigned_reviewer_id, pas.assigned_reviewer_name,
    -- 도메인
    m.domain_id,
    -- 코멘트 집계
    COALESCE(cc.total_comment_count, 0) AS comment_count,
    COALESCE(cc.unresolved_comment_count, 0) AS unresolved_comment_count,
    -- 정체 일수
    EXTRACT(DAY FROM NOW() - pas.updated_at)::INTEGER AS days_since_update,
    -- 테넌트
    pas.tenant_id,
    pas.created_at,
    pas.updated_at
FROM proc_def_approval_state pas
JOIN proc_def pd ON pas.proc_def_id = pd.id AND pas.tenant_id = pd.tenant_id
LEFT JOIN tb_bpmn_model m ON pas.proc_def_id = m.proc_def_id AND pas.tenant_id = m.tenant_id
LEFT JOIN (
    SELECT
        proc_def_id, tenant_id,
        COUNT(*) AS total_comment_count,
        COUNT(*) FILTER (WHERE NOT is_resolved) AS unresolved_comment_count
    FROM proc_def_comments
    WHERE parent_comment_id IS NULL
    GROUP BY proc_def_id, tenant_id
) cc ON pas.proc_def_id = cc.proc_def_id AND pas.tenant_id = cc.tenant_id
WHERE pd.isdeleted = false;

GRANT SELECT ON v_review_board TO authenticated;

-- =====================================================
-- 11. KPI 뷰 재작성 (새 상태값 반영)
-- =====================================================

DROP VIEW IF EXISTS v_kpi_pipeline_summary;
CREATE VIEW v_kpi_pipeline_summary AS
SELECT tenant_id,
    COUNT(*) AS total_processes,
    COUNT(CASE WHEN state = 'draft' THEN 1 END) AS draft_count,
    COUNT(CASE WHEN state = 'in_review' THEN 1 END) AS in_review_count,
    COUNT(CASE WHEN state = 'public_feedback' THEN 1 END) AS public_feedback_count,
    COUNT(CASE WHEN state = 'final_edit' THEN 1 END) AS final_edit_count,
    COUNT(CASE WHEN state = 'published' THEN 1 END) AS published_count,
    COUNT(CASE WHEN state = 'reopen_requested' THEN 1 END) AS reopen_requested_count,
    COUNT(CASE WHEN state = 'rejected' THEN 1 END) AS rejected_count,
    COUNT(CASE WHEN state = 'archived' THEN 1 END) AS archived_count
FROM (
    SELECT DISTINCT ON (proc_def_id, tenant_id) proc_def_id, tenant_id, state
    FROM proc_def_approval_state
    ORDER BY proc_def_id, tenant_id, created_at DESC
) latest_reviews
GROUP BY tenant_id;

DROP VIEW IF EXISTS v_kpi_domain_progress;
CREATE VIEW v_kpi_domain_progress AS
SELECT m.domain_id, m.tenant_id,
    COUNT(*) AS total_processes,
    COUNT(CASE WHEN lr.state = 'published' THEN 1 END) AS published_count,
    COUNT(CASE WHEN lr.state = 'draft' THEN 1 END) AS draft_count,
    COUNT(CASE WHEN lr.state = 'in_review' THEN 1 END) AS in_review_count,
    COUNT(CASE WHEN lr.state = 'public_feedback' THEN 1 END) AS public_feedback_count,
    COUNT(CASE WHEN lr.state = 'final_edit' THEN 1 END) AS final_edit_count
FROM tb_bpmn_model m
LEFT JOIN (
    SELECT DISTINCT ON (proc_def_id, tenant_id) proc_def_id, tenant_id, state
    FROM proc_def_approval_state
    ORDER BY proc_def_id, tenant_id, created_at DESC
) lr ON m.proc_def_id = lr.proc_def_id AND m.tenant_id = lr.tenant_id
WHERE m.deleted_at IS NULL
GROUP BY m.domain_id, m.tenant_id;

DROP VIEW IF EXISTS v_weekly_deployment_velocity;
CREATE VIEW v_weekly_deployment_velocity AS
SELECT h.tenant_id,
    DATE_TRUNC('week', h.created_at) AS week_start,
    COUNT(*) AS deployments
FROM proc_def_approval_history h
WHERE h.action = 'publish' AND h.to_state = 'published'
GROUP BY h.tenant_id, DATE_TRUNC('week', h.created_at)
ORDER BY week_start DESC;

GRANT SELECT ON v_kpi_pipeline_summary TO authenticated;
GRANT SELECT ON v_kpi_domain_progress TO authenticated;
GRANT SELECT ON v_weekly_deployment_velocity TO authenticated;

-- =====================================================
-- 12. 공람 30일 자동 전환 함수 (Cron 또는 Edge Function에서 호출)
-- =====================================================

CREATE OR REPLACE FUNCTION auto_transition_public_feedback()
RETURNS INTEGER AS $$
DECLARE
    transitioned_count INTEGER := 0;
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT id, proc_def_id, tenant_id
        FROM proc_def_approval_state
        WHERE state = 'public_feedback'
          AND public_feedback_ends_at IS NOT NULL
          AND public_feedback_ends_at <= NOW()
          AND public_feedback_auto_transitioned = FALSE
    LOOP
        -- 상태 전환
        UPDATE proc_def_approval_state
        SET state = 'final_edit',
            public_feedback_auto_transitioned = TRUE,
            updated_at = NOW()
        WHERE id = rec.id;

        -- 이력 기록
        INSERT INTO proc_def_approval_history
            (proc_def_id, review_id, action, from_state, to_state, actor_id, actor_name, comment, tenant_id)
        VALUES
            (rec.proc_def_id, rec.id, 'auto_transition_final_edit', 'public_feedback', 'final_edit',
             'system', 'System', '30일 공람 기간 만료로 자동 전환', rec.tenant_id);

        transitioned_count := transitioned_count + 1;
    END LOOP;

    RETURN transitioned_count;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 13. 인덱스 추가
-- =====================================================

-- =====================================================
-- 14. Realtime: old/new 전체 데이터 수신을 위한 REPLICA IDENTITY
-- =====================================================

ALTER TABLE proc_def_approval_state REPLICA IDENTITY FULL;

-- Realtime publication에 테이블 추가 (이미 있으면 무시)
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE proc_def_approval_state;
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_approval_state_hq_status ON proc_def_approval_state(hq_status);
CREATE INDEX IF NOT EXISTS idx_approval_state_field_status ON proc_def_approval_state(field_status);
CREATE INDEX IF NOT EXISTS idx_approval_state_feedback_end ON proc_def_approval_state(public_feedback_ends_at)
  WHERE state = 'public_feedback';
CREATE INDEX IF NOT EXISTS idx_approval_state_major_version ON proc_def_approval_state(proc_def_id, major_version);
