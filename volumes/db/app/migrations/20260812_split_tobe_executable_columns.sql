-- =====================================================
-- proc_def definition JSON 분리: To-Be / 실행형 변환 작업본 전용 컬럼
-- Date: 2026-08-12
-- Description:
--   definition(jsonb) 안에 저장되던 To-Be 관련 대용량 데이터(BPMN XML 여러 벌)를
--   전용 컬럼으로 분리해 definition 비대화와 definition 덮어쓰기 사고 반경을 줄인다.
--   - tobe       JSONB: definition.tobe (블루프린트/솔루션/ROI/AN 확장, executable 제외)
--                       + definition 루트의 tobe_bpmn / tobe_version / tobe_bpmn_versions
--                         (순서도 To-Be 캔버스 XML과 그 이력 — 루트 키 그대로 tobe 컬럼 안에 보관)
--   - executable JSONB: definition.tobe.executable (실행형 변환 작업본)
--   "실행 정의로 등록"된(applied) 실행 필드는 엔진 계약상 definition 루트에 그대로 남는다.
--   읽기/쓰기 재조립은 ProcessGPTBackend(putRawDefinition/updateProcessDefinitionMetadata/
--   getDefinitionDetailLite/getRawDefinition)에서 수행한다.
-- =====================================================

-- =====================================================
-- 0. 백업: 영향받는 행의 definition 원본 보존 (복원용)
--    - proc_def_version 쪽 To-Be 제거는 이동이 아닌 삭제이므로 백업이 유일한 복원 수단
--    - 검증 완료 후 아래 "정리" 주석의 DROP 을 별도 실행해 제거
-- =====================================================

CREATE TABLE IF NOT EXISTS _backup_20260812_proc_def_tobe_split AS
SELECT uuid, id, tenant_id, definition, now() AS backed_up_at
  FROM proc_def
 WHERE jsonb_typeof(definition) = 'object'
   AND (definition ? 'tobe' OR definition ? 'tobe_bpmn'
        OR definition ? 'tobe_version' OR definition ? 'tobe_bpmn_versions');

CREATE TABLE IF NOT EXISTS _backup_20260812_proc_def_version_tobe_split AS
SELECT uuid, arcv_id, proc_def_id, tenant_id, definition, now() AS backed_up_at
  FROM proc_def_version
 WHERE jsonb_typeof(definition) = 'object'
   AND (definition ? 'tobe' OR definition ? 'tobe_bpmn'
        OR definition ? 'tobe_version' OR definition ? 'tobe_bpmn_versions');

-- 백업 테이블은 API 로 노출되지 않도록 차단 (RLS 활성 + 정책 없음 → service_role 전용)
ALTER TABLE _backup_20260812_proc_def_tobe_split ENABLE ROW LEVEL SECURITY;
ALTER TABLE _backup_20260812_proc_def_version_tobe_split ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON _backup_20260812_proc_def_tobe_split FROM anon, authenticated;
REVOKE ALL ON _backup_20260812_proc_def_version_tobe_split FROM anon, authenticated;

-- 복원(롤백)이 필요할 때 (service_role/psql 로 실행):
--   UPDATE proc_def p
--      SET definition = b.definition, tobe = NULL, executable = NULL
--     FROM _backup_20260812_proc_def_tobe_split b
--    WHERE p.uuid = b.uuid;
--   UPDATE proc_def_version v
--      SET definition = b.definition
--     FROM _backup_20260812_proc_def_version_tobe_split b
--    WHERE v.uuid = b.uuid;
--
-- 검증 완료 후 정리:
--   DROP TABLE _backup_20260812_proc_def_tobe_split;
--   DROP TABLE _backup_20260812_proc_def_version_tobe_split;

ALTER TABLE proc_def ADD COLUMN IF NOT EXISTS tobe JSONB;
ALTER TABLE proc_def ADD COLUMN IF NOT EXISTS executable JSONB;

-- =====================================================
-- 백필: definition → 분리 컬럼 (이미 분리 컬럼에 값이 있는 행은 보존)
-- =====================================================

UPDATE proc_def
SET
    executable = COALESCE(
        executable,
        CASE WHEN jsonb_typeof(definition->'tobe') = 'object'
             THEN definition->'tobe'->'executable'
        END
    ),
    tobe = COALESCE(
        tobe,
        NULLIF(
            CASE WHEN jsonb_typeof(definition->'tobe') = 'object'
                 THEN (definition->'tobe') - 'executable'
                 ELSE '{}'::jsonb
            END
            || COALESCE(
                (SELECT jsonb_object_agg(k, definition->k)
                   FROM unnest(ARRAY['tobe_bpmn', 'tobe_version', 'tobe_bpmn_versions']) AS k
                  WHERE definition ? k),
                '{}'::jsonb
            ),
            '{}'::jsonb
        )
    ),
    definition = definition - 'tobe' - 'tobe_bpmn' - 'tobe_version' - 'tobe_bpmn_versions'
WHERE jsonb_typeof(definition) = 'object'
  AND (definition ? 'tobe' OR definition ? 'tobe_bpmn'
       OR definition ? 'tobe_version' OR definition ? 'tobe_bpmn_versions');

-- =====================================================
-- 버전 스냅샷 슬림화: proc_def_version.definition 에서 To-Be 작업본 제거
-- (엔진/실행 경로는 definition 루트 키만 사용하므로 prod/published 실행에 영향 없음.
--  To-Be 는 버전별 이력 없이 live(proc_def.tobe/executable)만 유지하는 정책.)
-- =====================================================

UPDATE proc_def_version
SET definition = definition - 'tobe' - 'tobe_bpmn' - 'tobe_version' - 'tobe_bpmn_versions'
WHERE jsonb_typeof(definition) = 'object'
  AND (definition ? 'tobe' OR definition ? 'tobe_bpmn'
       OR definition ? 'tobe_version' OR definition ? 'tobe_bpmn_versions');

-- =====================================================
-- 검증 (마이그레이션 후 수동 실행)
-- 1) definition 에 To-Be 키가 남은 행 = 0 이어야 함 (proc_def / proc_def_version 모두)
--   SELECT count(*) FROM proc_def
--    WHERE jsonb_typeof(definition) = 'object'
--      AND (definition ? 'tobe' OR definition ? 'tobe_bpmn'
--           OR definition ? 'tobe_version' OR definition ? 'tobe_bpmn_versions');
--   SELECT count(*) FROM proc_def_version
--    WHERE jsonb_typeof(definition) = 'object'
--      AND (definition ? 'tobe' OR definition ? 'tobe_bpmn'
--           OR definition ? 'tobe_version' OR definition ? 'tobe_bpmn_versions');
-- 2) 백업 행 수 = tobe 컬럼이 채워진 행 수 (이관 누락 확인)
--   SELECT (SELECT count(*) FROM _backup_20260812_proc_def_tobe_split)      AS backed_up,
--          (SELECT count(*) FROM proc_def WHERE tobe IS NOT NULL)            AS migrated;
