-- =============================================================================
-- permissions  +  users.permission_ids
--   커스텀 권한 Policy CRUD 엔진의 마스터 권한 카탈로그와 사용자별 할당.
--
--   - permissions: HTTP verb + api_path 단위로 미리 정의된 권한 목록
--   - users.permission_ids: 해당 사용자에게 할당된 permissions.id 배열
--
--   기본 RBAC (role: admin > owner > editor > reviewer > viewer) 와 AND/OR 로
--   합쳐 권한 체크 시 사용한다. 메뉴 가드와 페이지 내 액션 버튼 가드 모두
--   동일한 헬퍼로 처리한다.
--
--   permissions 카탈로그는 테넌트 무관(글로벌).
-- =============================================================================

-- =====================================================
-- 1. permissions 테이블
-- =====================================================

CREATE TABLE IF NOT EXISTS public.permissions (
    id          uuid    NOT NULL DEFAULT gen_random_uuid(),
    name        text    NOT NULL,
    label       text    NOT NULL,
    api_path    text    NOT NULL,
    verb        text    NOT NULL,
    CONSTRAINT permissions_pkey       PRIMARY KEY (id),
    CONSTRAINT permissions_name_key   UNIQUE (name),
    CONSTRAINT permissions_verb_check CHECK (verb IN ('GET', 'POST', 'PUT', 'PATCH', 'DELETE', '*'))
);

COMMENT ON TABLE  public.permissions          IS '커스텀 권한 마스터 카탈로그 (verb + api_path 단위)';
COMMENT ON COLUMN public.permissions.id       IS '권한 PK (uuid)';
COMMENT ON COLUMN public.permissions.name     IS '권한 코드 (예: kpi_read, recycle_delete) — 어플리케이션에서 식별자로 사용';
COMMENT ON COLUMN public.permissions.label    IS '권한 표시 이름 (한국어, UI 노출용)';
COMMENT ON COLUMN public.permissions.api_path IS '대상 API endpoint / 페이지 경로';
COMMENT ON COLUMN public.permissions.verb     IS 'HTTP verb: GET | POST | PUT | PATCH | DELETE | * (모든 verb)';

-- =====================================================
-- 2. users 에 permission_ids 컬럼 추가
-- =====================================================

ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS permission_ids uuid[] NOT NULL DEFAULT '{}'::uuid[];

COMMENT ON COLUMN public.users.permission_ids IS '해당 사용자에게 할당된 permissions.id 배열. 기본 RBAC 보완용 커스텀 권한.';

CREATE INDEX IF NOT EXISTS idx_users_permission_ids
    ON public.users USING GIN (permission_ids);

-- =====================================================
-- 3. 초기 시드 데이터
--    1차 단계: viewer 등급 RBAC 으로는 접근 못 하는 메뉴들에 대한
--    "페이지 접근(GET)" 권한만 등록.
--    각 페이지의 세부 액션(생성/수정/삭제) 권한은 추후 화면 단위로 추가.
-- =====================================================

INSERT INTO public.permissions (name, label, api_path, verb) VALUES
    -- process 섹션
    ('process_architecture_read', '프로세스 체계도 접근',  '/process-architecture',           'GET'),
    ('review_board_read',         '프로세스 리뷰 보드 접근','/review-board',                  'GET'),
    ('call_activity_read',        '프로세스 모듈 접근',    '/call-activity-management',       'GET'),

    -- admin 섹션
    ('property_schema_read',        '속성 스키마 접근',         '/admin-console/property-schemas',  'GET'),
    ('data_freeze_read',            '수정 잠금 접근',           '/admin-console/data-freeze',       'GET'),
    ('recycle_bin_read',            '휴지통 접근',              '/admin-console/recycle-bin',       'GET'),
    ('system_ops_read',             '시스템 운영 접근',         '/admin-console/system-operations', 'GET'),
    ('kpi_read',                    'KPI 목표 접근',            '/admin-console/kpi-targets',       'GET'),
    ('usage_adoption_read',         '사용 활성도 접근',         '/admin-console/usage-adoption',    'GET'),
    ('audit_read',                  '감사 로그 접근',           '/admin-console/audit-trail',       'GET'),
    ('governance_read',             '거버넌스 스튜디오 접근',   '/admin-console/governance-studio', 'GET'),
    ('policy_document_read',        '사내 정책문서 접근',       '/policy-document',                 'GET'),
    ('signup_approval_read',        '회원가입 승인 접근',       '/admin-console/signup-approvals',  'GET'),
    ('admin_request_approval_read', '역할 관리 / 권한 승인 접근','/admin-console/admin-requests',   'GET'),
    ('supplier_read',               '외부협력사 관리 접근',     '/admin-console/suppliers',         'GET'),
    ('pi_flag_read',                'PI Flag 접근',             '/admin-console/pi-flags',          'GET'),
    ('system_read',                 '시스템 관리 접근',         '/systems',                         'GET'),
    ('external_api_health_read',    'api 연동 상태 접근',       '/external-api-health',             'GET'),
    ('task_type_read',              'Task 종류 설정 접근',      '/admin-console/task-types',        'GET'),
    ('work_assignment_read',        '업무분장 접근',            '/work-assignment',                 'GET')
ON CONFLICT (name) DO NOTHING;
