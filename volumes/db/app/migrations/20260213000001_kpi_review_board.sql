-- =====================================================
-- KPI & Review Board 마이그레이션
-- 의존: proc_def_approval_state, proc_def_approval_history,
--       proc_def_comments, proc_def, tb_bpmn_model
-- =====================================================

-- 1. KPI 목표 테이블
CREATE TABLE IF NOT EXISTS kpi_targets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id TEXT NOT NULL DEFAULT 'default',
    period_type TEXT NOT NULL DEFAULT 'quarterly' CHECK (period_type IN ('monthly','quarterly','yearly')),
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    total_target INTEGER NOT NULL DEFAULT 0,
    domain_targets JSONB DEFAULT '[]',   -- [{domain_id, domain_name, target}]
    org_targets JSONB DEFAULT '[]',
    created_by TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (tenant_id, period_type, period_start)
);

-- 2. 파이프라인 집계 뷰
CREATE  VIEW v_kpi_pipeline_summary AS
SELECT tenant_id,
  COUNT(*) AS total_processes,
  COUNT(CASE WHEN state='draft' THEN 1 END) AS draft_count,
  COUNT(CASE WHEN state IN ('review','approved_level1','approved_level2') THEN 1 END) AS review_count,
  COUNT(CASE WHEN state='confirmed' THEN 1 END) AS published_count,
  COUNT(CASE WHEN state='rejected' THEN 1 END) AS rejected_count
FROM proc_def_approval_state GROUP BY tenant_id;

-- 3. 도메인별 진행 현황 뷰
CREATE  VIEW v_kpi_domain_progress AS
SELECT m.domain_id, m.tenant_id,
  COUNT(*) AS total_processes,
  COUNT(CASE WHEN pas.state='confirmed' THEN 1 END) AS published_count,
  COUNT(CASE WHEN pas.state='draft' THEN 1 END) AS draft_count,
  COUNT(CASE WHEN pas.state IN ('review','approved_level1','approved_level2') THEN 1 END) AS review_count
FROM tb_bpmn_model m
LEFT JOIN proc_def_approval_state pas ON m.proc_def_id=pas.proc_def_id AND m.tenant_id=pas.tenant_id
WHERE m.deleted_at IS NULL GROUP BY m.domain_id, m.tenant_id;

-- 4. 주간 배포 속도 뷰
CREATE  VIEW v_weekly_deployment_velocity AS
SELECT pas.tenant_id, DATE_TRUNC('week', h.created_at) AS week_start, COUNT(*) AS deployments
FROM proc_def_approval_history h
JOIN proc_def_approval_state pas ON h.proc_def_id=pas.proc_def_id AND h.tenant_id=pas.tenant_id
WHERE h.action='confirm' AND h.to_state='confirmed'
GROUP BY pas.tenant_id, DATE_TRUNC('week', h.created_at)
ORDER BY week_start DESC;

-- 5. 리뷰 보드 뷰 (프로세스 + 승인상태 + 도메인 + 코멘트수)
CREATE  VIEW v_review_board AS
SELECT
  pas.proc_def_id, pd.name AS process_name, pd.owner,
  pas.state, pas.submitted_by, pas.submitted_at,
  pas.reviewer_level1_name, pas.reviewed_at_level1,
  pas.confirmed_by_name, pas.confirmed_at,
  pas.rejected_by_name, pas.rejected_at, pas.reject_comment,
  m.domain_id,
  COALESCE(cc.comment_count, 0) AS comment_count,
  lv.latest_version,
  pas.tenant_id, pas.updated_at
FROM proc_def_approval_state pas
JOIN proc_def pd ON pas.proc_def_id=pd.id AND pas.tenant_id=pd.tenant_id
LEFT JOIN tb_bpmn_model m ON pas.proc_def_id=m.proc_def_id AND pas.tenant_id=m.tenant_id
LEFT JOIN (
  SELECT proc_def_id, tenant_id, COUNT(*) AS comment_count
  FROM proc_def_comments GROUP BY proc_def_id, tenant_id
) cc ON pas.proc_def_id=cc.proc_def_id AND pas.tenant_id=cc.tenant_id
LEFT JOIN LATERAL (
  SELECT v.version AS latest_version
  FROM proc_def_version v
  WHERE v.proc_def_id=pas.proc_def_id AND v.tenant_id=pas.tenant_id
  ORDER BY v."timeStamp" DESC NULLS LAST
  LIMIT 1
) lv ON true
WHERE pd.isdeleted=false;

-- RLS + Indexes
ALTER TABLE kpi_targets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "kpi_targets_all" ON kpi_targets FOR ALL USING (true) WITH CHECK (true);
CREATE INDEX IF NOT EXISTS idx_kpi_targets_tenant ON kpi_targets(tenant_id);
GRANT ALL ON kpi_targets TO authenticated;
GRANT SELECT ON v_kpi_pipeline_summary TO authenticated;
GRANT SELECT ON v_kpi_domain_progress TO authenticated;
GRANT SELECT ON v_weekly_deployment_velocity TO authenticated;
GRANT SELECT ON v_review_board TO authenticated;
