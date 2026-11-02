-- =============================================================================
-- lock 테이블 RLS 정책 변경
-- 기존: admin만 INSERT/UPDATE/DELETE 가능
-- 변경: editor 이상 (editor, owner, admin, superadmin) INSERT/UPDATE/DELETE 가능
-- =============================================================================

ALTER TABLE public.lock ENABLE ROW LEVEL SECURITY;

-- 기존 정책 삭제
DROP POLICY IF EXISTS "lock_insert_policy" ON public.lock;
DROP POLICY IF EXISTS "lock_update_policy" ON public.lock;
DROP POLICY IF EXISTS "lock_delete_policy" ON public.lock;
DROP POLICY IF EXISTS "lock_select_policy" ON public.lock;

-- SELECT: 같은 tenant 인증 사용자
CREATE POLICY "lock_select_policy" ON public.lock
  FOR SELECT TO authenticated
  USING (tenant_id = public.tenant_id());

-- INSERT: editor 이상
CREATE POLICY "lock_insert_editor" ON public.lock
  FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id = public.tenant_id()
    AND public.has_role_at_least('editor')
  );

-- UPDATE: editor 이상
CREATE POLICY "lock_update_editor" ON public.lock
  FOR UPDATE TO authenticated
  USING (
    tenant_id = public.tenant_id()
    AND public.has_role_at_least('editor')
  );

-- DELETE: editor 이상
CREATE POLICY "lock_delete_editor" ON public.lock
  FOR DELETE TO authenticated
  USING (
    tenant_id = public.tenant_id()
    AND public.has_role_at_least('editor')
  );
