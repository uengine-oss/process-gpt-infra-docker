-- =====================================================
-- 다음 담당자 지정 기능
-- Assigned reviewer tracking on approval actions
-- =====================================================

-- proc_def_approval_state에 다음 담당자 컬럼 추가
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS assigned_reviewer_id TEXT;
ALTER TABLE proc_def_approval_state ADD COLUMN IF NOT EXISTS assigned_reviewer_name TEXT;

-- v_review_board 뷰 업데이트: assigned_reviewer 컬럼 포함
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
  pas.assigned_reviewer_id, pas.assigned_reviewer_name,
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

GRANT SELECT ON v_review_board TO authenticated;
