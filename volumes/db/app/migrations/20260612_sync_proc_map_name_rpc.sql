-- =============================================================================
-- sync_proc_map_name RPC
--
-- 배경:
--   순서도(BPMN 에디터)에서 프로세스 이름 변경 시 proc_def.name은 editor 권한으로
--   업데이트되지만, 체계도(proc_map)가 저장된 configuration 테이블은
--   "configuration_modify_admin" 정책(admin+ 전용)에 막혀 이름 동기화가
--   조용히 실패(RLS UPDATE = 0 rows, 에러 없음)하던 문제 해결.
--
-- 해결:
--   SECURITY DEFINER 함수로 RLS를 우회하되, 함수 내부에서
--   - editor 이상 역할 검증
--   - 현재 테넌트의 key='proc_map' 행만 대상
--   - sub_proc_list 내 동일 id의 name 필드만 갱신
--   으로 최소 권한 범위를 강제한다.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.sync_proc_map_name(
  p_proc_def_id text,
  p_new_name text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_updated integer := 0;
BEGIN
  -- 권한 검증: proc_def 수정 권한(editor+)과 동일 기준
  IF NOT public.has_role_at_least('editor') THEN
    RAISE EXCEPTION 'permission denied: editor role required'
      USING ERRCODE = '42501';
  END IF;

  IF coalesce(trim(p_proc_def_id), '') = '' OR coalesce(trim(p_new_name), '') = '' THEN
    RAISE EXCEPTION 'proc_def_id and new_name are required';
  END IF;

  UPDATE public.configuration c
  SET value = jsonb_set(
    c.value,
    '{mega_proc_list}',
    coalesce(
      (
        SELECT jsonb_agg(
          CASE
            WHEN jsonb_typeof(mega -> 'major_proc_list') = 'array' THEN
              jsonb_set(
                mega,
                '{major_proc_list}',
                coalesce(
                  (
                    SELECT jsonb_agg(
                      CASE
                        WHEN jsonb_typeof(major -> 'sub_proc_list') = 'array' THEN
                          jsonb_set(
                            major,
                            '{sub_proc_list}',
                            coalesce(
                              (
                                SELECT jsonb_agg(
                                  CASE
                                    WHEN sub ->> 'id' = p_proc_def_id
                                      THEN jsonb_set(sub, '{name}', to_jsonb(p_new_name))
                                    ELSE sub
                                  END
                                )
                                FROM jsonb_array_elements(major -> 'sub_proc_list') AS sub
                              ),
                              '[]'::jsonb
                            )
                          )
                        ELSE major
                      END
                    )
                    FROM jsonb_array_elements(mega -> 'major_proc_list') AS major
                  ),
                  '[]'::jsonb
                )
              )
            ELSE mega
          END
        )
        FROM jsonb_array_elements(c.value -> 'mega_proc_list') AS mega
      ),
      '[]'::jsonb
    )
  )
  WHERE c.key = 'proc_map'
    AND c.tenant_id = public.tenant_id()
    AND jsonb_typeof(c.value -> 'mega_proc_list') = 'array'
    -- 해당 id의 sub 프로세스가 실제로 존재할 때만 갱신
    AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements(c.value -> 'mega_proc_list') AS mega,
           jsonb_array_elements(coalesce(mega -> 'major_proc_list', '[]'::jsonb)) AS major,
           jsonb_array_elements(coalesce(major -> 'sub_proc_list', '[]'::jsonb)) AS sub
      WHERE sub ->> 'id' = p_proc_def_id
    );

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_proc_map_name(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_proc_map_name(text, text) TO authenticated;
