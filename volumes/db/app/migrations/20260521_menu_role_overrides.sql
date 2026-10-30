-- =============================================================================
-- menu_role_overrides
--   사이드바 메뉴별 최소 접근 역할(requiredRole) 의 운영 조정 이력.
--
--   - 메뉴 정의(label/path/icon/section) 자체는 코드(routePermissions.ts) 유지
--   - 이 테이블에는 "코드 기본값에서 벗어난 항목만" 저장 (sparse override)
--   - 판정: effectiveRequiredRole = DB override 값 ?? 코드 기본값
--   - 기본값으로 되돌릴 때는 row DELETE → 테이블에 "조정된 항목만" 남음
--
--   사용처: 사이드바 필터링, 라우트 가드(canAccess/lookupRequiredRole),
--           매트릭스 관리 UI(RoleMenuMatrix.vue).
-- =============================================================================

-- =====================================================
-- 1. menu_role_overrides 테이블
-- =====================================================

CREATE TABLE IF NOT EXISTS public.menu_role_overrides (
    id            uuid         NOT NULL DEFAULT gen_random_uuid(),
    name          text         NOT NULL,
    menu_path     text         NOT NULL,
    required_role text         NOT NULL,
    tenant_id     text         NOT NULL,
    updated_at    timestamptz  NOT NULL DEFAULT now(),
    updated_by    uuid         NULL,
    CONSTRAINT menu_role_overrides_pkey
        PRIMARY KEY (id),
    CONSTRAINT menu_role_overrides_tenant_path_key
        UNIQUE (tenant_id, menu_path),
    CONSTRAINT menu_role_overrides_role_check
        CHECK (required_role IN ('admin', 'owner', 'editor', 'reviewer', 'viewer'))
);

COMMENT ON TABLE  public.menu_role_overrides               IS '메뉴별 최소 접근 역할 운영 조정 (코드 기본값 override)';
COMMENT ON COLUMN public.menu_role_overrides.id            IS 'PK (uuid)';
COMMENT ON COLUMN public.menu_role_overrides.name          IS '메뉴 label (예: PI Flag) — UI 표시·관리 편의';
COMMENT ON COLUMN public.menu_role_overrides.menu_path     IS '라우트 경로 (예: /admin-console/pi-flags) — 권한 판정 키';
COMMENT ON COLUMN public.menu_role_overrides.required_role IS '최소 접근 역할 (admin|owner|editor|reviewer|viewer)';
COMMENT ON COLUMN public.menu_role_overrides.tenant_id     IS '테넌트 식별자 (window.$tenantName)';
COMMENT ON COLUMN public.menu_role_overrides.updated_at    IS '마지막 수정 시각';
COMMENT ON COLUMN public.menu_role_overrides.updated_by    IS '마지막 수정자 (users.id 값, FK 미지정 — users PK 가 복합키 (id, tenant_id) 이라 단일 FK 불가)';

-- =====================================================
-- 2. 인덱스 — 테넌트별 전체 조회 가속
--    (tenant_id, menu_path) UNIQUE 가 자동 생성하는 인덱스로 prefix 조회는
--    이미 커버되지만, ORDER BY menu_path 같은 정렬 비용 줄이기 위해 보강.
-- =====================================================

CREATE INDEX IF NOT EXISTS idx_menu_role_overrides_tenant
    ON public.menu_role_overrides (tenant_id);

-- =====================================================
-- 3. RLS
--    - 읽기 : 인증 사용자 전체 (사이드바·가드 동작에 필요)
--    - 쓰기 : admin 만 (users.is_admin = true OR users.role = 'admin')
-- =====================================================

ALTER TABLE public.menu_role_overrides ENABLE ROW LEVEL SECURITY;

CREATE POLICY "menu_role_overrides_authenticated_read" ON public.menu_role_overrides
    FOR SELECT
    USING (auth.role() = 'authenticated');

CREATE POLICY "menu_role_overrides_admin_all" ON public.menu_role_overrides
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.users u
            WHERE u.id = auth.uid()
              AND (u.is_admin = true OR u.role = 'admin')
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.users u
            WHERE u.id = auth.uid()
              AND (u.is_admin = true OR u.role = 'admin')
        )
    );
