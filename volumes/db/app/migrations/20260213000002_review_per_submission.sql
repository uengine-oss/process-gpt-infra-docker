-- =====================================================
-- 검토 요청 건당 분리 관리 마이그레이션
-- per-submission review tracking
-- =====================================================

-- 1. proc_def_approval_state: UNIQUE 제약 제거 (프로세스당 여러 리뷰 허용)
ALTER TABLE proc_def_approval_state DROP CONSTRAINT IF EXISTS proc_def_approval_state_proc_def_id_key;

-- 2. proc_def_approval_state: version 컬럼 추가
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS version TEXT;

-- 3. proc_def_approval_history: review_id 컬럼 추가 (리뷰 건별 이력 연결)
ALTER TABLE proc_def_approval_history ADD COLUMN IF NOT EXISTS review_id UUID REFERENCES proc_def_approval_state(id);
CREATE INDEX IF NOT EXISTS idx_proc_def_approval_history_review ON proc_def_approval_history(review_id);

-- 4. v_review_board 뷰 업데이트: review_id, version 포함 (컬럼명 변경으로 DROP 필요)
DROP VIEW IF EXISTS v_review_board;
CREATE VIEW v_review_board AS
SELECT
  pas.id AS review_id,
  pas.proc_def_id, pd.name AS process_name, pd.owner,
  pas.state, pas.version,
  pas.submitted_by, pas.submitted_at,
  pas.reviewer_level1_name, pas.reviewed_at_level1,
  pas.confirmed_by_name, pas.confirmed_at,
  pas.rejected_by_name, pas.rejected_at, pas.reject_comment,
  m.domain_id,
  COALESCE(cc.comment_count, 0) AS comment_count,
  pas.tenant_id, pas.updated_at
FROM proc_def_approval_state pas
JOIN proc_def pd ON pas.proc_def_id=pd.id AND pas.tenant_id=pd.tenant_id
LEFT JOIN tb_bpmn_model m ON pas.proc_def_id=m.proc_def_id AND pas.tenant_id=m.tenant_id
LEFT JOIN (
  SELECT proc_def_id, tenant_id, COUNT(*) AS comment_count
  FROM proc_def_comments GROUP BY proc_def_id, tenant_id
) cc ON pas.proc_def_id=cc.proc_def_id AND pas.tenant_id=cc.tenant_id
WHERE pd.isdeleted=false;

-- 5. KPI 뷰: 프로세스당 최신 리뷰만 집계
CREATE OR REPLACE VIEW v_kpi_pipeline_summary AS
SELECT tenant_id,
  COUNT(*) AS total_processes,
  COUNT(CASE WHEN state='draft' THEN 1 END) AS draft_count,
  COUNT(CASE WHEN state IN ('review','approved_level1','approved_level2') THEN 1 END) AS review_count,
  COUNT(CASE WHEN state='confirmed' THEN 1 END) AS published_count,
  COUNT(CASE WHEN state='rejected' THEN 1 END) AS rejected_count
FROM (
  SELECT DISTINCT ON (proc_def_id, tenant_id) proc_def_id, tenant_id, state
  FROM proc_def_approval_state
  ORDER BY proc_def_id, tenant_id, created_at DESC
) latest_reviews
GROUP BY tenant_id;

CREATE OR REPLACE VIEW v_kpi_domain_progress AS
SELECT m.domain_id, m.tenant_id,
  COUNT(*) AS total_processes,
  COUNT(CASE WHEN lr.state='confirmed' THEN 1 END) AS published_count,
  COUNT(CASE WHEN lr.state='draft' THEN 1 END) AS draft_count,
  COUNT(CASE WHEN lr.state IN ('review','approved_level1','approved_level2') THEN 1 END) AS review_count
FROM tb_bpmn_model m
LEFT JOIN (
  SELECT DISTINCT ON (proc_def_id, tenant_id) proc_def_id, tenant_id, state
  FROM proc_def_approval_state
  ORDER BY proc_def_id, tenant_id, created_at DESC
) lr ON m.proc_def_id=lr.proc_def_id AND m.tenant_id=lr.tenant_id
WHERE m.deleted_at IS NULL GROUP BY m.domain_id, m.tenant_id;

-- 6. 주간 배포 속도 뷰 수정 (기존 JOIN이 중복 발생 가능하므로 history 자체 tenant_id 사용)
CREATE OR REPLACE VIEW v_weekly_deployment_velocity AS
SELECT h.tenant_id, DATE_TRUNC('week', h.created_at) AS week_start, COUNT(*) AS deployments
FROM proc_def_approval_history h
WHERE h.action='confirm' AND h.to_state='confirmed'
GROUP BY h.tenant_id, DATE_TRUNC('week', h.created_at)
ORDER BY week_start DESC;

-- GRANT
GRANT SELECT ON v_review_board TO authenticated;
GRANT SELECT ON v_kpi_pipeline_summary TO authenticated;
GRANT SELECT ON v_kpi_domain_progress TO authenticated;
GRANT SELECT ON v_weekly_deployment_velocity TO authenticated;
