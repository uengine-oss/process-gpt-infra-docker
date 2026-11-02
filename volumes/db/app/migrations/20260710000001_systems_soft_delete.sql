-- =============================================================================
-- systems 휴지통 지원 컬럼 보강
--   시스템 관리 삭제를 실제 DELETE 대신 soft delete 로 처리하고,
--   휴지통에서 복원/영구삭제할 수 있게 한다.
-- =============================================================================

ALTER TABLE public.systems
    ADD COLUMN IF NOT EXISTS deleted_at timestamptz,
    ADD COLUMN IF NOT EXISTS deleted_by text;

CREATE INDEX IF NOT EXISTS idx_systems_tenant_deleted_at
    ON public.systems (tenant_id, deleted_at);

