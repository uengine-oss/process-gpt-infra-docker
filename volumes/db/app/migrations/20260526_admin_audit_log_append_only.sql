-- =============================================================================
-- 관리자 감사 로그 append-only 정책 적용 (D안: 최소 안전망)
--
-- [목표]
--   감사 로그는 한 번 기록되면 누구도 수정·삭제할 수 없어야 한다 (append-only).
--   현재 admin_audit_log 는 RLS 가 꺼져있어 anon/authenticated 키로 임의 수정·
--   삭제가 가능한 상태. 이를 RLS 로 차단한다.
--
-- [무엇이 바뀌나]
--   - 변경 ① UPDATE / DELETE 차단 (모든 클라이언트 키 기준)
--   - 변경 ② 조회·삽입은 정책으로 다시 명시 — 기존 동작 그대로 유지
--   - 영향 ⓪ 앱 코드(insertAdminAuditLog / getAdminAuditLogs) 변경 불필요
--
-- [무엇이 안 바뀌나]
--   - actor_id 위·변조 차단은 이 마이그레이션 범위 밖.
--     → 인증 흐름(Keycloak ↔ Supabase Auth) 정리 후 별도 트리거로 처리 예정.
--
-- [동작 원리]
--   PostgreSQL RLS 는 한 번 켜지면 기본 동작이 "전부 차단" 으로 바뀐다.
--   GRANT 가 있어도 정책이 없으면 막힌다. 그래서:
--     · ENABLE RLS         → 모든 행 접근 차단 (기본값)
--     · SELECT 정책 생성    → 조회만 다시 허용
--     · INSERT 정책 생성    → 삽입만 다시 허용
--     · UPDATE/DELETE 정책 미선언 → 그대로 차단 유지 = 보안 효과
--     · REVOKE UPDATE/DELETE → GRANT 단에서도 한 번 더 차단 (이중 안전망)
--
-- [롤백] 파일 하단 주석 참고
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. RLS 활성화
--    켜는 순간 정책이 없는 모든 동작이 차단된다. 그래서 아래에서 SELECT/INSERT
--    정책을 즉시 다시 만들어줘야 운영이 깨지지 않는다.
-- ---------------------------------------------------------------------------
ALTER TABLE public.admin_audit_log ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 2. SELECT 정책 — 조회 허용 (현재 동작 유지)
--    감사 로그 페이지(AuditTrail.vue) 가 조회할 수 있게 해야 한다.
--    USING (true) = 행 단위 제한 없이 모두 허용. 테넌트별 필터는 앱 쿼리에서
--    이미 .eq('tenant_id', ...) 로 적용 중이라 정책에서 추가로 막지 않는다.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS admin_audit_log_select ON public.admin_audit_log;
CREATE POLICY admin_audit_log_select ON public.admin_audit_log
    FOR SELECT TO anon, authenticated
    USING (true);

-- ---------------------------------------------------------------------------
-- 3. INSERT 정책 — 삽입 허용 (현재 동작 유지)
--    insertAdminAuditLog (호출 9곳) 가 그대로 동작하게 해야 한다.
--    WITH CHECK (true) = 어떤 값이든 INSERT 허용. actor_id 위·변조 차단은
--    별도 트리거로 추후 추가 예정 (이 마이그레이션 범위 밖).
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS admin_audit_log_insert ON public.admin_audit_log;
CREATE POLICY admin_audit_log_insert ON public.admin_audit_log
    FOR INSERT TO anon, authenticated
    WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- 4. UPDATE / DELETE — 정책을 일부러 만들지 않는다
--    PostgreSQL RLS 의 핵심 규칙: 정책이 없는 동작은 자동 차단.
--    → 어떤 클라이언트가 .update() / .delete() 를 호출해도 막힌다.
--    이게 이 마이그레이션의 본질적 보안 효과.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 5. REVOKE — 이중 안전망
--    위 RLS 정책만으로도 차단되지만, GRANT 단에서도 권한을 회수해둔다.
--    혹시 미래에 RLS 가 실수로 꺼지더라도 UPDATE/DELETE 는 여전히 막힌다.
-- ---------------------------------------------------------------------------
REVOKE UPDATE, DELETE ON public.admin_audit_log FROM anon, authenticated, PUBLIC;

-- ---------------------------------------------------------------------------
-- 6. 테이블 코멘트 — 다음 작업자가 이 테이블의 정책을 이해할 수 있도록 기록
-- ---------------------------------------------------------------------------
COMMENT ON TABLE public.admin_audit_log IS
'관리자 감사 로그. append-only (UPDATE/DELETE 차단). actor_id 는 현재 클라이언트 제공값 — 인증 흐름 정리 후 트리거로 강제 덮어쓰기 예정.';

COMMIT;

-- =============================================================================
-- 검증 쿼리 (적용 후 별도 실행)
-- =============================================================================
-- ① RLS 활성화 확인
--    SELECT relname, relrowsecurity FROM pg_class WHERE relname = 'admin_audit_log';
--    → relrowsecurity = true 면 OK
--
-- ② 정책 2개 등록 확인
--    SELECT polname, polcmd FROM pg_policy
--    WHERE polrelid = 'public.admin_audit_log'::regclass;
--    → admin_audit_log_select / r, admin_audit_log_insert / a 두 행
--
-- ③ UPDATE/DELETE 차단 동작 확인 (실패해야 정상)
--    UPDATE public.admin_audit_log SET comment = 'tampered'
--    WHERE id = (SELECT id FROM public.admin_audit_log ORDER BY created_at DESC LIMIT 1);
--    → "new row violates row-level security policy" 또는 0 rows affected
--
-- ④ INSERT 정상 동작 확인
--    앱에서 권한 변경·스키마 수정 등을 한 번 수행하면 새 감사 로그가 잘 쌓여야 함.

-- =============================================================================
-- 롤백 SQL (문제 발생 시)
-- =============================================================================
-- BEGIN;
-- ALTER TABLE public.admin_audit_log DISABLE ROW LEVEL SECURITY;
-- DROP POLICY IF EXISTS admin_audit_log_select ON public.admin_audit_log;
-- DROP POLICY IF EXISTS admin_audit_log_insert ON public.admin_audit_log;
-- GRANT UPDATE, DELETE ON public.admin_audit_log TO anon, authenticated;
-- COMMIT;
