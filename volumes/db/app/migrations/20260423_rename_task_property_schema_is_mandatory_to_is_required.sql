-- =============================================================================
-- Rename task_property_schema.is_mandatory -> is_required
-- =============================================================================
-- 프론트엔드 코드 전반에서 사용하는 `is_required` 네이밍과 일치시키기 위해
-- 기존 컬럼 `is_mandatory` 를 `is_required` 로 변경한다.
-- =============================================================================

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'task_property_schema' AND column_name = 'is_mandatory'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'task_property_schema' AND column_name = 'is_required'
    ) THEN
        ALTER TABLE public.task_property_schema RENAME COLUMN is_mandatory TO is_required;
    ELSIF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'task_property_schema' AND column_name = 'is_mandatory'
    ) THEN
        UPDATE public.task_property_schema
        SET is_required = COALESCE(is_required, false) OR COALESCE(is_mandatory, false);
        ALTER TABLE public.task_property_schema DROP COLUMN is_mandatory;
    END IF;
END $$;

COMMENT ON COLUMN public.task_property_schema.is_required IS
'Whether the property is required.';
