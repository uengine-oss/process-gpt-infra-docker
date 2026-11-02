-- ============================================================
-- 속성 스키마: 저장 버그 수정 + 그룹(묶음) 지원
--
-- 1) default_value 컬럼 추가
--    스튜디오(PropertySchemaStudio)는 읽기전용 속성의 기본값을 default_value 로
--    upsert 하는데 컬럼이 없어 PostgREST 가 PGRST204 를 반환, 저장 자체가
--    조용히 실패했다 ("설정한 내용이 반영되지 않는다"의 원인 1).
--
-- 2) 내장(panel) 속성 중복 시드 정리
--    syncPanelPropertySchemas 의 초기 시드가 두 번 실행되어 모든 내장 속성이
--    (renderer 유무만 다른) 2행씩 존재한다. 관리 화면 목록이 2배로 보이고,
--    가시성 토글이 find() 로 잡히는 행과 실제 판정에 쓰이는 행이 달라
--    설정이 적용되지 않는 것처럼 보였다 (원인 2).
--    → (tenant_id, task_type, property_key) 별로 renderer='panel' 행(없으면
--      최신 행)만 남기고 나머지를 삭제한 뒤 유니크 인덱스로 재발을 막는다.
--
-- 3) 그룹(묶음) 컬럼 추가
--    속성패널의 "일반 - 이름, 설명" 처럼 사용자 정의 속성도 섹션으로 묶기 위한
--    group_key / group_label / group_order.
-- ============================================================

-- 1) default_value
ALTER TABLE task_property_schema ADD COLUMN IF NOT EXISTS default_value text;

-- 3) 그룹
ALTER TABLE task_property_schema ADD COLUMN IF NOT EXISTS group_key text;
ALTER TABLE task_property_schema ADD COLUMN IF NOT EXISTS group_label text;
ALTER TABLE task_property_schema ADD COLUMN IF NOT EXISTS group_order integer NOT NULL DEFAULT 0;

-- 2) 중복 정리: renderer='panel' 행 우선, 그다음 최신(updated_at) 행을 남긴다.
--    proc_def 쪽 값은 property_key 로만 연결되므로 스키마 행 삭제는 데이터에 영향 없음.
DO $$
DECLARE
    removed integer;
BEGIN
    WITH ranked AS (
        SELECT id,
               ROW_NUMBER() OVER (
                   PARTITION BY tenant_id, COALESCE(task_type, ''), property_key
                   ORDER BY (config ->> 'renderer' = 'panel') DESC NULLS LAST,
                            updated_at DESC NULLS LAST,
                            created_at DESC NULLS LAST
               ) AS rn
        FROM task_property_schema
        WHERE deleted_at IS NULL
    )
    DELETE FROM task_property_schema t
    USING ranked r
    WHERE t.id = r.id
      AND r.rn > 1;
    GET DIAGNOSTICS removed = ROW_COUNT;
    RAISE NOTICE '[property_schema] 중복 시드 제거: % 건', removed;
END $$;

-- 재발 방지: 활성 행 기준 (tenant, task_type, property_key) 유니크.
-- soft delete(deleted_at) 행은 제외해 같은 키의 재생성을 허용한다.
CREATE UNIQUE INDEX IF NOT EXISTS task_property_schema_tenant_type_key_unique
    ON task_property_schema (tenant_id, COALESCE(task_type, ''), property_key)
    WHERE deleted_at IS NULL;
