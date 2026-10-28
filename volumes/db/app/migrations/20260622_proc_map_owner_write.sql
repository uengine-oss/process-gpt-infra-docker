-- =============================================================================
-- 프로세스 체계도(proc_map) 생성/수정 권한 완화: admin -> owner 이상
--
-- 프로세스 체계도의 노드 추가(Mega / Major / Call-Activity Sub)는
-- putProcessDefinitionMap 을 통해 configuration 테이블의 key = 'proc_map' 행으로
-- 저장된다. 기존에는 configuration_modify_admin 정책(admin+, level >= 100)만
-- 쓰기를 허용했기 때문에, 프론트엔드 생성 권한을 owner(level 80)로 낮춰도
-- DB(RLS)에서 거부되어 실제 생성이 불가능했다.
--
-- 생성 권한을 owner 이상으로 변경하기 위해, key = 'proc_map' 에 한정한
-- owner+ 쓰기 정책을 추가한다. 그 외 configuration 키는 기존대로 admin+ 유지한다.
-- (PostgreSQL의 permissive 정책은 OR로 결합되므로 admin 전용 정책과 공존하며,
--  proc_map 행에 대해서만 owner+ 쓰기를 추가로 허용한다.)
--
-- 주의: 체계도의 이름 변경/삭제는 프론트엔드에서 여전히 admin 전용으로 막혀 있으나,
--       proc_map 은 단일 JSON 행이므로 DB 레벨에서 생성과 수정을 분리할 수 없다.
--       owner 는 신뢰 등급(level 80)으로 체계도 쓰기를 허용하는 것이 정책상 적절하다.
-- =============================================================================

DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_name = 'configuration' AND table_schema = 'public'
  ) THEN
    EXECUTE 'ALTER TABLE public.configuration ENABLE ROW LEVEL SECURITY';

    EXECUTE 'DROP POLICY IF EXISTS "configuration_modify_proc_map_owner" ON public.configuration';

    EXECUTE 'CREATE POLICY "configuration_modify_proc_map_owner" ON public.configuration
      FOR ALL
      USING (key = ''proc_map'' AND public.has_role_at_least(''owner''))
      WITH CHECK (key = ''proc_map'' AND public.has_role_at_least(''owner''))';
  END IF;
END $$;
