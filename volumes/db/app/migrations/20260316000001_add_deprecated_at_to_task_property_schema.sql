-- =============================================================================
-- Add soft-delete support to task_property_schema
-- =============================================================================

ALTER TABLE IF EXISTS public.task_property_schema
    ADD COLUMN IF NOT EXISTS deprecated_at TIMESTAMPTZ;

COMMENT ON COLUMN public.task_property_schema.deprecated_at IS
'Soft delete timestamp. NULL means active.';
