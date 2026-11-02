-- =============================================================================
-- systems 테이블 (시스템 관리 인벤토리)
--
-- pi-system-web 에서는 /pi-system-backend/systems REST(별도 백엔드 서비스)가
-- 이 테이블을 관리했고 DDL 이 리포지토리에 없었다(핸드오버 문서 12번 "미확인").
-- pal 모드 이관에서는 별도 백엔드 없이 Supabase 직접 접근으로 동작해야 하므로
-- 프런트엔드 System 타입(src/stores/systemManagement.ts)과
-- 20260710_systems_soft_delete.sql 이 전제하는 컬럼으로 테이블을 신설한다.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.systems (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id TEXT NOT NULL DEFAULT 'default',
    name TEXT NOT NULL,
    system_type TEXT,
    category TEXT,
    description TEXT,
    shortcut_link TEXT,
    is_active INTEGER NOT NULL DEFAULT 1,
    responsible_org_id TEXT,
    responsible_person TEXT,
    registration_status TEXT,
    created_by TEXT,
    created_by_display TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    deleted_by TEXT
);

CREATE INDEX IF NOT EXISTS idx_systems_tenant_name
    ON public.systems (tenant_id, name);

ALTER TABLE public.systems ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "systems_public_read" ON public.systems;
CREATE POLICY "systems_public_read"
    ON public.systems
    FOR SELECT
    USING (true);

DROP POLICY IF EXISTS "systems_public_write" ON public.systems;
CREATE POLICY "systems_public_write"
    ON public.systems
    FOR ALL
    USING (true)
    WITH CHECK (true);

GRANT ALL ON public.systems TO authenticated;
