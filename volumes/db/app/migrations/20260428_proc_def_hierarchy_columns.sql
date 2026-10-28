-- Normalize process hierarchy ownership on proc_def for policy checks such as Data Freeze.

ALTER TABLE public.proc_def
    ADD COLUMN IF NOT EXISTS domain_id TEXT,
    ADD COLUMN IF NOT EXISTS mega_process_id TEXT,
    ADD COLUMN IF NOT EXISTS major_process_id TEXT;

CREATE INDEX IF NOT EXISTS idx_proc_def_tenant_domain_id
    ON public.proc_def(tenant_id, domain_id)
    WHERE domain_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_proc_def_tenant_mega_process_id
    ON public.proc_def(tenant_id, mega_process_id)
    WHERE mega_process_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_proc_def_tenant_major_process_id
    ON public.proc_def(tenant_id, major_process_id)
    WHERE major_process_id IS NOT NULL;

WITH metrics_domains AS (
    SELECT DISTINCT
        c.tenant_id,
        LOWER(TRIM(domain_key.domain_key)) AS domain_key,
        TRIM(COALESCE(domain_item.value->>'id', domain_item.value->>'name', '')) AS domain_id
    FROM public.configuration AS c
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(c.value->'domains', '[]'::jsonb)) AS domain_item(value)
    CROSS JOIN LATERAL (
        VALUES
            (COALESCE(domain_item.value->>'id', '')),
            (COALESCE(domain_item.value->>'name', ''))
    ) AS domain_key(domain_key)
    WHERE c.key = 'metrics'
      AND TRIM(COALESCE(domain_item.value->>'id', domain_item.value->>'name', '')) <> ''
      AND TRIM(domain_key.domain_key) <> ''
),
proc_map_entries AS (
    SELECT
        c.tenant_id,
        TRIM(COALESCE(sub_item.value->>'id', '')) AS proc_def_id,
        TRIM(COALESCE(mega_item.value->>'id', '')) AS mega_process_id,
        TRIM(COALESCE(major_item.value->>'id', '')) AS major_process_id,
        TRIM(
            COALESCE(
                major_item.value->>'domain_id',
                major_item.value->>'domain',
                major_item.value->>'business_domain',
                major_item.value->>'businessDomain',
                major_item.value->>'network_domain',
                major_item.value->>'networkDomain',
                ''
            )
        ) AS raw_domain_id
    FROM public.configuration AS c
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(c.value->'mega_proc_list', '[]'::jsonb)) AS mega_item(value)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(mega_item.value->'major_proc_list', '[]'::jsonb)) AS major_item(value)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(major_item.value->'sub_proc_list', '[]'::jsonb)) AS sub_item(value)
    WHERE c.key = 'proc_map'
),
resolved_entries AS (
    SELECT
        entry.tenant_id,
        entry.proc_def_id,
        entry.mega_process_id,
        entry.major_process_id,
        COALESCE(domain_lookup.domain_id, NULLIF(entry.raw_domain_id, '')) AS domain_id
    FROM proc_map_entries AS entry
    LEFT JOIN metrics_domains AS domain_lookup
        ON domain_lookup.tenant_id = entry.tenant_id
       AND domain_lookup.domain_key = LOWER(entry.raw_domain_id)
    WHERE entry.proc_def_id <> ''
)
UPDATE public.proc_def AS proc
SET
    domain_id = NULLIF(resolved.domain_id, ''),
    mega_process_id = NULLIF(resolved.mega_process_id, ''),
    major_process_id = NULLIF(resolved.major_process_id, '')
FROM resolved_entries AS resolved
WHERE proc.tenant_id = resolved.tenant_id
  AND proc.id = resolved.proc_def_id;
