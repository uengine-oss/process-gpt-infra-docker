-- ============================================================================
-- 20260723_bpmn_element_uuid.sql
-- BPMN Element 영구 UUID 체계 도입
--
-- 내용:
--   1) uuid_generate_v7() 함수 추가 (RFC 9562 UUIDv7, 시간순 정렬 가능)
--   2) proc_def / proc_def_version 신규 행의 uuid 기본값을 v7 로 전환
--      (기존 행의 uuid 값은 변경하지 않는다 — 동일 객체 UUID 유지)
--   3) bpmn_element_map 테이블 신설:
--      BPMN XML 요소(legacy element_id = XML id/tracingTag) ↔ 영구 element_uuid 매핑.
--      element UUID 원본은 BPMN XML 내 uengine:properties/@json 의 "uuid" 키이며
--      이 테이블은 DB 측 조회/조인용 미러다. 저장 시(putRawDefinition) 동기화된다.
--   4) proc_map(프로세스 체계도, configuration.key='proc_map') 노드에 uuid 백필
--
-- 멱등성: 전체 재실행 안전 (IF NOT EXISTS / OR REPLACE / uuid 미존재 노드만 백필).
-- 기존 BPMN XML 본문 백필은 scripts/backfill-bpmn-element-uuids.mjs 로 수행한다.
-- 롤백: supabase/rollback/20260723_bpmn_element_uuid_down.sql
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. UUIDv7 생성 함수
--    gen_random_uuid()(v4) 결과의 앞 48bit 를 unix epoch(ms)로 교체하고
--    version 비트를 7(0111)로 설정한다.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.uuid_generate_v7()
RETURNS uuid
LANGUAGE sql
VOLATILE
PARALLEL SAFE
AS $$
  SELECT encode(
    set_bit(
      set_bit(
        overlay(
          uuid_send(gen_random_uuid())
          PLACING substring(int8send((extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3)
          FROM 1 FOR 6
        ),
        52, 1
      ),
      53, 1
    ),
    'hex'
  )::uuid;
$$;

COMMENT ON FUNCTION public.uuid_generate_v7() IS
  'RFC 9562 UUIDv7 (48bit ms timestamp + random). BPMN Element/프로세스 신규 UUID 발급용';

-- ----------------------------------------------------------------------------
-- 2. 신규 행 uuid 기본값을 v7 로 전환 (기존 값은 그대로 유지)
-- ----------------------------------------------------------------------------
ALTER TABLE public.proc_def ALTER COLUMN uuid SET DEFAULT public.uuid_generate_v7();

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'proc_def_version' AND column_name = 'uuid') THEN
    EXECUTE 'ALTER TABLE public.proc_def_version ALTER COLUMN uuid SET DEFAULT public.uuid_generate_v7()';
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 3. bpmn_element_map — legacy element id ↔ 영구 element UUID 매핑
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.bpmn_element_map (
  element_uuid uuid NOT NULL DEFAULT public.uuid_generate_v7(),
  proc_def_uuid uuid NOT NULL,
  proc_def_id text NOT NULL,             -- legacy 텍스트 정의 id (조회 편의)
  element_id text NOT NULL,              -- legacy id: BPMN XML id (= tracingTag/activity_id)
  element_type text NULL,                -- 예: bpmn:UserTask, bpmn:SequenceFlow
  name text NULL,
  tenant_id text NULL DEFAULT public.tenant_id(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bpmn_element_map_pkey PRIMARY KEY (element_uuid),
  CONSTRAINT bpmn_element_map_def_element_unique UNIQUE (proc_def_uuid, element_id),
  CONSTRAINT bpmn_element_map_proc_def_fkey FOREIGN KEY (proc_def_uuid)
    REFERENCES public.proc_def (uuid) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_bpmn_element_map_def_id
  ON public.bpmn_element_map (proc_def_id, tenant_id);
CREATE INDEX IF NOT EXISTS idx_bpmn_element_map_element_id
  ON public.bpmn_element_map (element_id);

COMMENT ON TABLE public.bpmn_element_map IS
  'BPMN Element 영구 UUID 매핑. 원본은 proc_def.bpmn 의 uengine:properties json "uuid" 키. 저장 시 동기화(파생 데이터)';
COMMENT ON COLUMN public.bpmn_element_map.element_id IS
  'legacy id — BPMN XML 요소 id (tracingTag / todolist.activity_id / current_activity_ids 와 동일 체계)';

ALTER TABLE public.bpmn_element_map ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "bpmn_element_map_select_all" ON public.bpmn_element_map;
DROP POLICY IF EXISTS "bpmn_element_map_insert_editor" ON public.bpmn_element_map;
DROP POLICY IF EXISTS "bpmn_element_map_update_editor" ON public.bpmn_element_map;
DROP POLICY IF EXISTS "bpmn_element_map_delete_editor" ON public.bpmn_element_map;

CREATE POLICY "bpmn_element_map_select_all" ON public.bpmn_element_map
  FOR SELECT USING (true);

-- 저장(putRawDefinition) 시 편집 권한자가 매핑을 동기화하므로 editor+ 로 허용
CREATE POLICY "bpmn_element_map_insert_editor" ON public.bpmn_element_map
  FOR INSERT WITH CHECK (public.has_role_at_least('editor'));

CREATE POLICY "bpmn_element_map_update_editor" ON public.bpmn_element_map
  FOR UPDATE USING (public.has_role_at_least('editor'));

CREATE POLICY "bpmn_element_map_delete_editor" ON public.bpmn_element_map
  FOR DELETE USING (public.has_role_at_least('editor'));

-- ----------------------------------------------------------------------------
-- 4. proc_map 노드(mega/major/sub) uuid 백필
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.procmap_ensure_uuids(map jsonb)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  mega_list jsonb;
  new_mega jsonb := '[]'::jsonb;
  mega jsonb;
  major_list jsonb;
  new_major jsonb;
  major jsonb;
  sub_list jsonb;
  new_sub jsonb;
  sub jsonb;
BEGIN
  IF map IS NULL OR jsonb_typeof(map) <> 'object' OR jsonb_typeof(map->'mega_proc_list') <> 'array' THEN
    RETURN map;
  END IF;

  mega_list := map->'mega_proc_list';
  FOR mega IN SELECT * FROM jsonb_array_elements(mega_list) LOOP
    IF jsonb_typeof(mega) = 'object' AND NOT (mega ? 'uuid') THEN
      mega := jsonb_set(mega, '{uuid}', to_jsonb(public.uuid_generate_v7()::text));
    END IF;

    major_list := mega->'major_proc_list';
    IF jsonb_typeof(major_list) = 'array' THEN
      new_major := '[]'::jsonb;
      FOR major IN SELECT * FROM jsonb_array_elements(major_list) LOOP
        IF jsonb_typeof(major) = 'object' AND NOT (major ? 'uuid') THEN
          major := jsonb_set(major, '{uuid}', to_jsonb(public.uuid_generate_v7()::text));
        END IF;

        sub_list := major->'sub_proc_list';
        IF jsonb_typeof(sub_list) = 'array' THEN
          new_sub := '[]'::jsonb;
          FOR sub IN SELECT * FROM jsonb_array_elements(sub_list) LOOP
            IF jsonb_typeof(sub) = 'object' AND NOT (sub ? 'uuid') THEN
              sub := jsonb_set(sub, '{uuid}', to_jsonb(public.uuid_generate_v7()::text));
            END IF;
            new_sub := new_sub || jsonb_build_array(sub);
          END LOOP;
          major := jsonb_set(major, '{sub_proc_list}', new_sub);
        END IF;

        new_major := new_major || jsonb_build_array(major);
      END LOOP;
      mega := jsonb_set(mega, '{major_proc_list}', new_major);
    END IF;

    new_mega := new_mega || jsonb_build_array(mega);
  END LOOP;

  RETURN jsonb_set(map, '{mega_proc_list}', new_mega);
END;
$$;

COMMENT ON FUNCTION public.procmap_ensure_uuids(jsonb) IS
  'proc_map JSON 의 mega/major/sub 노드에 uuid 가 없으면 v7 발급 (있으면 유지 — 멱등)';

UPDATE public.configuration
SET value = public.procmap_ensure_uuids(value)
WHERE key = 'proc_map'
  AND value IS DISTINCT FROM public.procmap_ensure_uuids(value);
