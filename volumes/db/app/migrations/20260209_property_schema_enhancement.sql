-- Property Schema Enhancement: applies_to, placeholder, visible_by_default, config
-- Supports dynamic Process/Task property fields in Process Hierarchy

ALTER TABLE IF EXISTS public.task_property_schema
    ADD COLUMN IF NOT EXISTS applies_to VARCHAR(20) DEFAULT 'both',
    ADD COLUMN IF NOT EXISTS placeholder TEXT,
    ADD COLUMN IF NOT EXISTS visible_by_default BOOLEAN DEFAULT true,
    ADD COLUMN IF NOT EXISTS config JSONB;

-- property_type 확장: url, db-select, formula 지원
COMMENT ON COLUMN public.task_property_schema.property_type IS 'string | number | boolean | select | multiselect | textarea | url | db-select | formula | date | daterange | user';
COMMENT ON COLUMN public.task_property_schema.applies_to IS 'both | process | task';
COMMENT ON COLUMN public.task_property_schema.config IS 'DB-Select: {"table":"table_name","label_col":"name","value_col":"id"}, Formula: {"expression":"SUM(tasks.fte)"}';
