-- =============================================================================
-- Expand task_property_schema to match PropertySchemaStudio payload
-- =============================================================================

ALTER TABLE IF EXISTS public.task_property_schema
    ADD COLUMN IF NOT EXISTS description TEXT,
    ADD COLUMN IF NOT EXISTS applies_to VARCHAR(50) DEFAULT 'both',
    ADD COLUMN IF NOT EXISTS placeholder TEXT,
    ADD COLUMN IF NOT EXISTS visible_by_default BOOLEAN DEFAULT true,
    ADD COLUMN IF NOT EXISTS is_readonly BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS is_required BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS options JSONB DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS config JSONB DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS display_order INTEGER DEFAULT 0,
    ADD COLUMN IF NOT EXISTS deprecated_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS number_min NUMERIC,
    ADD COLUMN IF NOT EXISTS number_max NUMERIC,
    ADD COLUMN IF NOT EXISTS number_use_comma BOOLEAN DEFAULT false,
    ADD COLUMN IF NOT EXISTS number_unit VARCHAR(20),
    ADD COLUMN IF NOT EXISTS select_source_type VARCHAR(10) DEFAULT 'static',
    ADD COLUMN IF NOT EXISTS select_api_endpoint TEXT,
    ADD COLUMN IF NOT EXISTS select_api_label_field VARCHAR(100),
    ADD COLUMN IF NOT EXISTS select_api_value_field VARCHAR(100);

COMMENT ON COLUMN public.task_property_schema.description IS
'Schema field description/help text.';

COMMENT ON COLUMN public.task_property_schema.applies_to IS
'both | process | task | specific task type';

COMMENT ON COLUMN public.task_property_schema.placeholder IS
'Placeholder text shown in the input UI.';

COMMENT ON COLUMN public.task_property_schema.visible_by_default IS
'Whether the property is visible by default in the editor.';

COMMENT ON COLUMN public.task_property_schema.is_readonly IS
'Whether the property is read-only.';

COMMENT ON COLUMN public.task_property_schema.is_required IS
'Whether the property is required.';

COMMENT ON COLUMN public.task_property_schema.options IS
'Select/multiselect options as JSON array.';

COMMENT ON COLUMN public.task_property_schema.config IS
'Additional property configuration such as db-select/formula settings.';

COMMENT ON COLUMN public.task_property_schema.display_order IS
'Sort order in UI.';

COMMENT ON COLUMN public.task_property_schema.deprecated_at IS
'Soft delete timestamp. NULL means active.';

COMMENT ON COLUMN public.task_property_schema.number_min IS 'Minimum value for number type';
COMMENT ON COLUMN public.task_property_schema.number_max IS 'Maximum value for number type';
COMMENT ON COLUMN public.task_property_schema.number_use_comma IS 'Display thousands separator (1,000) for number type';
COMMENT ON COLUMN public.task_property_schema.number_unit IS 'Unit label for number type (e.g. %, kg, EA)';
COMMENT ON COLUMN public.task_property_schema.select_source_type IS 'static | api';
COMMENT ON COLUMN public.task_property_schema.select_api_endpoint IS 'External API endpoint URL for dynamic select options';
COMMENT ON COLUMN public.task_property_schema.select_api_label_field IS 'JSON field name to use as option label from API response';
COMMENT ON COLUMN public.task_property_schema.select_api_value_field IS 'JSON field name to use as option value from API response';
