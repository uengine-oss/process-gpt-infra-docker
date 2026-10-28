-- =============================================================================
-- backfill_proc_def_property RPC
-- =============================================================================
-- 속성 스키마(applies_to = 'process' | 'both') 신규 등록 시,
-- 기존 proc_def.definition JSONB 에 해당 키가 없는 행에만 {key: null} 을 채워 넣는다.
-- 기존 클라이언트 측 N+1 백필 (proc_def 전체 SELECT → 행당 UPDATE) 을 단일 SQL 로 대체하여
-- 운영 환경 (300+ 프로세스) 에서 등록 지연을 제거한다.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.backfill_proc_def_property(
    p_key    text,
    p_tenant text
)
RETURNS integer
LANGUAGE sql
AS $$
    WITH updated AS (
        UPDATE public.proc_def
           SET definition = COALESCE(definition, '{}'::jsonb)
                          || jsonb_build_object(p_key, null)
         WHERE tenant_id = p_tenant
           AND NOT (COALESCE(definition, '{}'::jsonb) ? p_key)
        RETURNING 1
    )
    SELECT COUNT(*)::int FROM updated;
$$;

COMMENT ON FUNCTION public.backfill_proc_def_property(text, text) IS
'신규 속성 스키마 등록 시 proc_def.definition JSONB 에 {key: null} 을 일괄 백필. 갱신된 행 수를 반환.';

NOTIFY pgrst, 'reload schema';
