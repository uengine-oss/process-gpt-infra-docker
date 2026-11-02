-- =============================================================================
-- Role-Based RLS (Row Level Security) 정책
--
-- 역할 계층:
--   superadmin (level 120) > admin (100) > owner (80) > editor (60) > reviewer (40) > viewer (20)
--
-- 적용 테이블:
--   proc_def          - 프로세스 정의 (생성/수정: editor+, 배포: owner+)
--   configuration     - 시스템 설정 (수정: admin+, 조회: viewer+)
--   users             - 사용자 관리 (수정: admin+, 조회: viewer+)
--   user_permissions  - 권한 관리 (수정: admin+, 조회: editor+)
--   proc_def_comments - 댓글 (작성: reviewer+, 조회: viewer+)
--   proc_def_approval_state - 승인 상태 (수정: owner+, 조회: editor+)
--   proc_def_approval_history - 승인 이력 (작성: editor+, 조회: viewer+)
-- =============================================================================

-- =====================================================
-- 1. 역할 레벨 함수
--    JWT claims 또는 users 테이블에서 role을 가져와 숫자 레벨로 변환
-- =====================================================

CREATE OR REPLACE FUNCTION public.get_role_level(p_role text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(coalesce(p_role, ''))
    WHEN 'superadmin' THEN 120
    WHEN 'admin'      THEN 100
    WHEN 'owner'      THEN 80
    WHEN 'editor'     THEN 60
    WHEN 'reviewer'   THEN 40
    WHEN 'viewer'     THEN 20
    ELSE 0
  END;
$$;

-- =====================================================
-- 2. 현재 요청 사용자의 role 반환
--    우선순위: users 테이블 (Single Source of Truth) > JWT fallback > 'viewer'
--    ※ 승인 후 토큰 재발행 전에도 즉시 반영되도록 DB를 항상 우선 조회
-- =====================================================

CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_role text;
  v_uid  uuid;
  v_is_admin boolean;
  v_jwt_role text;
BEGIN
  -- 1) JWT에서 user id 추출
  BEGIN
    v_uid := (current_setting('request.jwt.claims', true)::json ->> 'sub')::uuid;
  EXCEPTION WHEN OTHERS THEN
    v_uid := NULL;
  END;

  -- 2) users 테이블에서 최신 role 조회 (Single Source of Truth)
  IF v_uid IS NOT NULL THEN
    SELECT u.role, u.is_admin
    INTO v_role, v_is_admin
    FROM public.users u
    WHERE u.id = v_uid
      AND u.tenant_id = public.tenant_id()
    LIMIT 1;

    IF v_role IS NOT NULL AND public.get_role_level(v_role) > 0 THEN
      RETURN lower(v_role);
    END IF;

    -- role 컬럼이 비어있으면 is_admin 플래그로 판단
    IF v_is_admin = true THEN
      RETURN 'admin';
    END IF;

    -- DB에 사용자는 있지만 role이 없으면 viewer
    IF v_role IS NOT NULL OR v_is_admin IS NOT NULL THEN
      RETURN 'viewer';
    END IF;
  END IF;

  -- 3) DB 조회 불가 시 JWT claims fallback
  BEGIN
    v_jwt_role := coalesce(
      current_setting('request.jwt.claims', true)::json ->> 'user_role',
      current_setting('request.jwt.claims', true)::json ->> 'role'
    );
  EXCEPTION WHEN OTHERS THEN
    v_jwt_role := NULL;
  END;

  IF v_jwt_role IS NOT NULL
     AND v_jwt_role NOT IN ('authenticated', 'anon', 'service_role', '')
     AND public.get_role_level(v_jwt_role) > 0
  THEN
    RETURN lower(v_jwt_role);
  END IF;

  -- 4) 기본값
  RETURN 'viewer';
END;
$$;

-- =====================================================
-- 3. 현재 사용자가 특정 역할 이상인지 확인하는 편의 함수
-- =====================================================

CREATE OR REPLACE FUNCTION public.has_role_at_least(required_role text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT public.get_role_level(public.current_user_role())
      >= public.get_role_level(required_role);
$$;

-- =====================================================
-- 4. proc_def (프로세스 정의) RLS
--    SELECT: 모든 인증 사용자 (viewer+)
--    INSERT: editor 이상
--    UPDATE: editor 이상
--    DELETE: admin 이상
-- =====================================================

ALTER TABLE public.proc_def ENABLE ROW LEVEL SECURITY;

-- 기존 정책 삭제 (있으면)
DROP POLICY IF EXISTS "proc_def_select_all" ON public.proc_def;
DROP POLICY IF EXISTS "proc_def_insert_owner" ON public.proc_def;
DROP POLICY IF EXISTS "proc_def_insert_editor" ON public.proc_def;
DROP POLICY IF EXISTS "proc_def_update_editor" ON public.proc_def;
DROP POLICY IF EXISTS "proc_def_delete_admin" ON public.proc_def;

CREATE POLICY "proc_def_select_all" ON public.proc_def
  FOR SELECT
  USING (true);

CREATE POLICY "proc_def_insert_editor" ON public.proc_def
  FOR INSERT
  WITH CHECK (public.has_role_at_least('editor'));

CREATE POLICY "proc_def_update_editor" ON public.proc_def
  FOR UPDATE
  USING (public.has_role_at_least('editor'));

CREATE POLICY "proc_def_delete_admin" ON public.proc_def
  FOR DELETE
  USING (public.has_role_at_least('admin'));

-- =====================================================
-- 5. configuration (시스템 설정) RLS
--    SELECT: viewer+
--    INSERT/UPDATE/DELETE: admin+
-- =====================================================

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'configuration' AND table_schema = 'public') THEN
    EXECUTE 'ALTER TABLE public.configuration ENABLE ROW LEVEL SECURITY';

    EXECUTE 'DROP POLICY IF EXISTS "configuration_select_all" ON public.configuration';
    EXECUTE 'DROP POLICY IF EXISTS "configuration_modify_admin" ON public.configuration';

    EXECUTE 'CREATE POLICY "configuration_select_all" ON public.configuration
      FOR SELECT USING (true)';

    EXECUTE 'CREATE POLICY "configuration_modify_admin" ON public.configuration
      FOR ALL USING (public.has_role_at_least(''admin''))
      WITH CHECK (public.has_role_at_least(''admin''))';
  END IF;
END $$;

-- =====================================================
-- 6. users (사용자 테이블) RLS
--    SELECT: viewer+ (목록 조회)
--    INSERT: admin+ (사용자 추가)
--    UPDATE: 본인 정보 수정 OR admin+ (역할 변경 등)
--    DELETE: admin+
-- =====================================================

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_select_all" ON public.users;
DROP POLICY IF EXISTS "users_insert_admin" ON public.users;
DROP POLICY IF EXISTS "users_update_self_or_admin" ON public.users;
DROP POLICY IF EXISTS "users_delete_admin" ON public.users;

CREATE POLICY "users_select_all" ON public.users
  FOR SELECT
  USING (true);

CREATE POLICY "users_insert_admin" ON public.users
  FOR INSERT
  WITH CHECK (public.has_role_at_least('admin'));

CREATE POLICY "users_update_self_or_admin" ON public.users
  FOR UPDATE
  USING (
    -- 본인 레코드이거나 admin 이상
    id::text = coalesce(
      nullif(current_setting('request.jwt.claims', true)::json ->> 'sub', ''),
      '00000000-0000-0000-0000-000000000000'
    )
    OR public.has_role_at_least('admin')
  );

CREATE POLICY "users_delete_admin" ON public.users
  FOR DELETE
  USING (public.has_role_at_least('admin'));

-- =====================================================
-- 7. user_permissions (권한 관리) RLS
--    SELECT: editor+
--    INSERT/UPDATE/DELETE: admin+
-- =====================================================

ALTER TABLE public.user_permissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_permissions_select_editor" ON public.user_permissions;
DROP POLICY IF EXISTS "user_permissions_modify_admin" ON public.user_permissions;

CREATE POLICY "user_permissions_select_editor" ON public.user_permissions
  FOR SELECT
  USING (public.has_role_at_least('editor'));

CREATE POLICY "user_permissions_modify_admin" ON public.user_permissions
  FOR ALL
  USING (public.has_role_at_least('admin'))
  WITH CHECK (public.has_role_at_least('admin'));

-- =====================================================
-- 8. proc_def_comments (댓글) RLS - 기존 정책 교체
--    SELECT: viewer+ (모든 인증 사용자)
--    INSERT: reviewer+ (공람 댓글 작성)
--    UPDATE: 본인 댓글만
--    DELETE: 본인 댓글 OR admin+
-- =====================================================

DROP POLICY IF EXISTS "proc_def_comments_select_policy" ON proc_def_comments;
DROP POLICY IF EXISTS "proc_def_comments_insert_policy" ON proc_def_comments;
DROP POLICY IF EXISTS "proc_def_comments_update_policy" ON proc_def_comments;
DROP POLICY IF EXISTS "proc_def_comments_delete_policy" ON proc_def_comments;

CREATE POLICY "proc_def_comments_select_all" ON proc_def_comments
  FOR SELECT
  USING (true);

CREATE POLICY "proc_def_comments_insert_reviewer" ON proc_def_comments
  FOR INSERT
  WITH CHECK (public.has_role_at_least('reviewer'));

CREATE POLICY "proc_def_comments_update_own" ON proc_def_comments
  FOR UPDATE
  USING (true);

CREATE POLICY "proc_def_comments_delete_own_or_admin" ON proc_def_comments
  FOR DELETE
  USING (public.has_role_at_least('reviewer'));

-- =====================================================
-- 9. proc_def_approval_state (승인 상태) RLS - 기존 정책 교체
--    SELECT: reviewer+ (체계도 status 표시 등에 필요)
--    INSERT/UPDATE: editor+ (승인 요청) + owner+ (최종 승인)
-- =====================================================

DROP POLICY IF EXISTS "proc_def_approval_state_select_policy" ON proc_def_approval_state;
DROP POLICY IF EXISTS "proc_def_approval_state_select_editor" ON proc_def_approval_state;
DROP POLICY IF EXISTS "proc_def_approval_state_insert_policy" ON proc_def_approval_state;
DROP POLICY IF EXISTS "proc_def_approval_state_update_policy" ON proc_def_approval_state;

CREATE POLICY "proc_def_approval_state_select_reviewer" ON proc_def_approval_state
  FOR SELECT
  USING (public.has_role_at_least('reviewer'));

CREATE POLICY "proc_def_approval_state_insert_editor" ON proc_def_approval_state
  FOR INSERT
  WITH CHECK (public.has_role_at_least('editor'));

CREATE POLICY "proc_def_approval_state_update_editor" ON proc_def_approval_state
  FOR UPDATE
  USING (public.has_role_at_least('editor'));

-- =====================================================
-- 10. proc_def_approval_history (승인 이력) RLS - 기존 정책 교체
--     SELECT: viewer+
--     INSERT: editor+
-- =====================================================

DROP POLICY IF EXISTS "proc_def_approval_history_select_policy" ON proc_def_approval_history;
DROP POLICY IF EXISTS "proc_def_approval_history_insert_policy" ON proc_def_approval_history;

CREATE POLICY "proc_def_approval_history_select_all" ON proc_def_approval_history
  FOR SELECT
  USING (true);

CREATE POLICY "proc_def_approval_history_insert_editor" ON proc_def_approval_history
  FOR INSERT
  WITH CHECK (public.has_role_at_least('editor'));

-- =====================================================
-- 11. 코멘트
-- =====================================================

COMMENT ON FUNCTION public.get_role_level(text) IS '역할 이름을 숫자 레벨로 변환 (superadmin=120, admin=100, owner=80, editor=60, reviewer=40, viewer=20)';
COMMENT ON FUNCTION public.current_user_role() IS '현재 요청 사용자의 역할을 JWT claims 또는 users 테이블에서 조회하여 반환';
COMMENT ON FUNCTION public.has_role_at_least(text) IS '현재 사용자가 지정된 역할 이상의 권한을 가지고 있는지 확인';
