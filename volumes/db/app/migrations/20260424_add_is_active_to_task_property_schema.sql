-- =============================================================================
-- Add is_active column to task_property_schema for Deactivate action
-- =============================================================================
-- is_active = true  (default) : 활성 상태 (목록/프로퍼티 패널 모두 노출)
-- is_active = false           : 비활성화 (Studio 기본 목록 및 프로퍼티 패널에서 숨김)
-- deprecated_at IS NOT NULL   : 휴지통 이동 (Soft Delete)

ALTER TABLE IF EXISTS public.task_property_schema
    ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN public.task_property_schema.is_active IS
'Active flag. FALSE means temporarily deactivated (hidden from default studio list and property panel) but not deleted.';
