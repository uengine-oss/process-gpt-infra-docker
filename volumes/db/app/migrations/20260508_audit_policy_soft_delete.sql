-- ============================================================================
-- audit_policy 소프트 딜리트 컬럼 추가
-- deleted_at: 삭제 시각 (NULL = 활성)
-- deleted_by_id / deleted_by_name / deleted_by_team: 삭제자 정보
-- (기존 author_id/author_name/author_team 와 동일한 분할 패턴)
-- storage 의 실제 파일은 제거하지 않고 file_path 를 그대로 유지하여
-- 추후 복원이 가능하도록 한다.
-- ============================================================================
ALTER TABLE public.audit_policy ADD COLUMN IF NOT EXISTS deleted_at      TIMESTAMPTZ DEFAULT NULL;
ALTER TABLE public.audit_policy ADD COLUMN IF NOT EXISTS deleted_by_id   TEXT        DEFAULT NULL;
ALTER TABLE public.audit_policy ADD COLUMN IF NOT EXISTS deleted_by_name TEXT        DEFAULT NULL;
ALTER TABLE public.audit_policy ADD COLUMN IF NOT EXISTS deleted_by_team TEXT        DEFAULT NULL;

CREATE INDEX IF NOT EXISTS idx_audit_policy_deleted_at
    ON public.audit_policy (deleted_at)
    WHERE deleted_at IS NOT NULL;

COMMENT ON COLUMN public.audit_policy.deleted_at      IS '소프트 딜리트 시각 (NULL = 활성)';
COMMENT ON COLUMN public.audit_policy.deleted_by_id   IS '삭제자 user id';
COMMENT ON COLUMN public.audit_policy.deleted_by_name IS '삭제자 표시 이름';
COMMENT ON COLUMN public.audit_policy.deleted_by_team IS '삭제자 소속 팀/조직';
