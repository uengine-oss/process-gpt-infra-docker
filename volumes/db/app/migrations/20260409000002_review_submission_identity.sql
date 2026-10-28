-- Review submission identity hardening
-- 1. proc_def_approval_state에 submitted_by_id 추가
-- 2. 기존 row 백필
-- 3. v_review_board가 submitted_by_id를 노출하도록 재생성

ALTER TABLE public.proc_def_approval_state
    ADD COLUMN IF NOT EXISTS submitted_by_id TEXT;

UPDATE public.proc_def_approval_state
SET submitted_by_id = submitted_by
WHERE submitted_by_id IS NULL
  AND submitted_by ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

UPDATE public.proc_def_approval_state pas
SET submitted_by_id = u.id
FROM public.users u
WHERE pas.submitted_by_id IS NULL
  AND COALESCE(TRIM(pas.submitted_by), '') <> ''
  AND (
      LOWER(TRIM(u.username)) = LOWER(TRIM(pas.submitted_by))
      OR LOWER(TRIM(u.email)) = LOWER(TRIM(pas.submitted_by))
  );

DROP VIEW IF EXISTS public.v_review_board;

CREATE VIEW public.v_review_board AS
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
    pas.submitted_by,
    pas.submitted_at,
    pas.hq_reviewer_id,
    pas.hq_reviewer_name,
    pas.hq_reviewed_at,
    pas.hq_status,
    pas.field_reviewer_id,
    pas.field_reviewer_name,
    pas.field_reviewed_at,
    pas.field_status,
    pas.public_feedback_started_at,
    pas.public_feedback_ends_at,
    CASE
        WHEN pas.state = 'public_feedback' AND pas.public_feedback_ends_at IS NOT NULL
        THEN EXTRACT(DAY FROM pas.public_feedback_ends_at - NOW())::INTEGER
        ELSE NULL
    END AS public_feedback_days_remaining,
    pas.published_by_name,
    pas.published_at,
    pas.rejected_by_name,
    pas.rejected_at,
    pas.reject_comment,
    pas.reopen_requested_by,
    pas.reopen_requested_at,
    pas.reopen_reason,
    pas.assigned_reviewer_id,
    pas.assigned_reviewer_name,
    m.domain_id,
    COALESCE(cc.total_comment_count, 0) AS comment_count,
    COALESCE(cc.unresolved_comment_count, 0) AS unresolved_comment_count,
    EXTRACT(DAY FROM NOW() - pas.updated_at)::INTEGER AS days_since_update,
    pas.tenant_id,
    pas.created_at,
    pas.updated_at,
    pas.submitted_by_id
FROM public.proc_def_approval_state pas
JOIN public.proc_def pd ON pas.proc_def_id = pd.id AND pas.tenant_id = pd.tenant_id
LEFT JOIN public.tb_bpmn_model m ON pas.proc_def_id = m.proc_def_id AND pas.tenant_id = m.tenant_id
LEFT JOIN (
    SELECT
        proc_def_id,
        tenant_id,
        COUNT(*) AS total_comment_count,
        COUNT(*) FILTER (WHERE NOT is_resolved) AS unresolved_comment_count
    FROM public.proc_def_comments
    WHERE parent_comment_id IS NULL
    GROUP BY proc_def_id, tenant_id
) cc ON pas.proc_def_id = cc.proc_def_id AND pas.tenant_id = cc.tenant_id
WHERE pd.isdeleted = false;

GRANT SELECT ON public.v_review_board TO authenticated;
