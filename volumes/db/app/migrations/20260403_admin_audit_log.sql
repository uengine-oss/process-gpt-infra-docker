-- ============================================================================
-- 관리자 감사 로그 테이블 (Admin Audit Log)
-- 권한 변경, 스키마 수정/삭제, 점검 모드 전환 등 관리자 액션 기록
-- Who / When / What / Before & After 구조, 최소 1년 보관
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.admin_audit_log (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    action TEXT NOT NULL,
    target_type TEXT,
    target_id TEXT,
    target_name TEXT,
    before_value TEXT,
    after_value TEXT,
    comment TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_log_tenant ON public.admin_audit_log (tenant_id);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_created ON public.admin_audit_log (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_action ON public.admin_audit_log (action);
CREATE INDEX IF NOT EXISTS idx_admin_audit_log_actor ON public.admin_audit_log (actor_id);

GRANT SELECT, INSERT ON public.admin_audit_log TO anon;
