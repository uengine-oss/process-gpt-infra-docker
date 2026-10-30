-- 42P10 "there is no unique or exclusion constraint matching the ON CONFLICT specification" 대응.
--
-- 프로세스 순서도 저장 경로는 두 테이블을 upsert 한다.
--   proc_def      : upsert(..., { onConflict: 'id,tenant_id' })   -- ProcessGPTBackend.putRawDefinition
--   configuration : upsert(..., { onConflict: 'key,tenant_id' })  -- putProcessDefinitionMap / setConfigurationValue 등
-- 그런데 base schema(20260101_base_schema.sql)의 두 테이블에는 uuid 단일 PK 만 있고
-- (tenant_id, id) / (tenant_id, key) unique 제약이 없다. lock 테이블에만 lock_tenant_id_id_unique 가
-- 정의돼 있어 같은 패턴이 proc_def / configuration 에서 누락된 상태였고, ON CONFLICT 컬럼 추론이
-- 실패해 저장이 42P10 으로 떨어진다.
--
-- 제약을 걸기 전에 기존 중복 행을 정리한다. 중복 행은 이미 앱에서 정상 조회가 불가능한 상태지만
-- (getObject/maybeSingle 이 다중 행에서 실패) 그냥 지우지 않고 백업 테이블로 옮겨 복구 가능하게 둔다.

-- ---------------------------------------------------------------------------
-- 1. 백업 테이블 (RLS 켜고 정책 없음 = service_role/owner 외 접근 불가)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.proc_def_dedup_backup (LIKE public.proc_def);
CREATE TABLE IF NOT EXISTS public.configuration_dedup_backup (LIKE public.configuration);

ALTER TABLE public.proc_def_dedup_backup ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.configuration_dedup_backup ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.proc_def_dedup_backup FROM anon, authenticated;
REVOKE ALL ON public.configuration_dedup_backup FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. proc_def 중복 정리 — (tenant_id, id) 당 1행만 남긴다.
--    우선순위: 활성(deleted_at IS NULL) > bpmn 보유 > bpmn 길이 > uuid(결정적 tie-break)
--    남지 못한 행은 백업 후 삭제한다 (bpmn_element_map 은 proc_def.uuid FK ON DELETE CASCADE).
-- ---------------------------------------------------------------------------
WITH ranked AS (
    SELECT uuid,
           row_number() OVER (
               PARTITION BY tenant_id, id
               ORDER BY (deleted_at IS NULL) DESC,
                        (bpmn IS NOT NULL) DESC,
                        length(coalesce(bpmn, '')) DESC,
                        uuid
           ) AS rn
      FROM public.proc_def
)
INSERT INTO public.proc_def_dedup_backup
SELECT p.* FROM public.proc_def p JOIN ranked r ON r.uuid = p.uuid AND r.rn > 1;

WITH ranked AS (
    SELECT uuid,
           row_number() OVER (
               PARTITION BY tenant_id, id
               ORDER BY (deleted_at IS NULL) DESC,
                        (bpmn IS NOT NULL) DESC,
                        length(coalesce(bpmn, '')) DESC,
                        uuid
           ) AS rn
      FROM public.proc_def
)
DELETE FROM public.proc_def p
 USING ranked r
 WHERE r.uuid = p.uuid AND r.rn > 1;

-- ---------------------------------------------------------------------------
-- 3. configuration 중복 정리 — (tenant_id, key) 당 1행. value 가 있는 행 우선.
-- ---------------------------------------------------------------------------
WITH ranked AS (
    SELECT uuid,
           row_number() OVER (
               PARTITION BY tenant_id, key
               ORDER BY (value IS NOT NULL) DESC, uuid
           ) AS rn
      FROM public.configuration
)
INSERT INTO public.configuration_dedup_backup
SELECT c.* FROM public.configuration c JOIN ranked r ON r.uuid = c.uuid AND r.rn > 1;

WITH ranked AS (
    SELECT uuid,
           row_number() OVER (
               PARTITION BY tenant_id, key
               ORDER BY (value IS NOT NULL) DESC, uuid
           ) AS rn
      FROM public.configuration
)
DELETE FROM public.configuration c
 USING ranked r
 WHERE r.uuid = c.uuid AND r.rn > 1;

-- ---------------------------------------------------------------------------
-- 4. ON CONFLICT 추론 대상 unique 제약 추가 (멱등)
--    컬럼 순서는 추론에 영향이 없어 앱의 'id,tenant_id' / 'key,tenant_id' 와 그대로 매칭된다.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'public.proc_def'::regclass AND conname = 'proc_def_tenant_id_id_unique'
    ) THEN
        ALTER TABLE public.proc_def
            ADD CONSTRAINT proc_def_tenant_id_id_unique UNIQUE (tenant_id, id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'public.configuration'::regclass AND conname = 'configuration_tenant_id_key_unique'
    ) THEN
        ALTER TABLE public.configuration
            ADD CONSTRAINT configuration_tenant_id_key_unique UNIQUE (tenant_id, key);
    END IF;
END $$;
