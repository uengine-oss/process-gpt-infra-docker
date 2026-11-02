ALTER TABLE public.proc_def
ADD COLUMN IF NOT EXISTS description text;

COMMENT ON COLUMN public.proc_def.description IS 'Process definition description shown in process architecture and tooltips.';

UPDATE public.proc_def
SET description = COALESCE(
    NULLIF(description, ''),
    NULLIF(definition ->> 'description', ''),
    CASE
        WHEN jsonb_typeof(definition -> 'shortDescription') = 'string'
            THEN NULLIF(definition ->> 'shortDescription', '')
        WHEN jsonb_typeof(definition -> 'shortDescription') = 'object'
            THEN NULLIF(definition -> 'shortDescription' ->> 'text', '')
        ELSE NULL
    END
)
WHERE definition IS NOT NULL
  AND (
    description IS NULL
    OR description = ''
  );

NOTIFY pgrst, 'reload schema';
