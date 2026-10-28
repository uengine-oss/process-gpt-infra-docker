    -- 프로세스 접근 권한 기능 확장
    -- 실행 권한, 조직/조직그룹 지원, 권한 레벨 추가

    -- 1. user_permissions 테이블에 새 컬럼 추가

    -- 실행(execute) 권한 추가
    ALTER TABLE user_permissions
    ADD COLUMN IF NOT EXISTS executable boolean NOT NULL DEFAULT false;

    -- 권한 대상 타입 (user, organization, org_group)
    ALTER TABLE user_permissions
    ADD COLUMN IF NOT EXISTS target_type text NOT NULL DEFAULT 'user';

    -- 조직 그룹 ID (target_type이 org_group일 때 사용)
    ALTER TABLE user_permissions
    ADD COLUMN IF NOT EXISTS org_group_id uuid REFERENCES org_chart_groups(id) ON DELETE CASCADE;

    -- 조직 ID (target_type이 organization일 때 사용)
    ALTER TABLE user_permissions
    ADD COLUMN IF NOT EXISTS organization_id text;

    -- 권한 레벨 (domain, mega, major, sub)
    ALTER TABLE user_permissions
    ADD COLUMN IF NOT EXISTS permission_level text NOT NULL DEFAULT 'sub';

    -- 2. 인덱스 추가 (성능 최적화)
    CREATE INDEX IF NOT EXISTS idx_user_permissions_target_type ON user_permissions(target_type);
    CREATE INDEX IF NOT EXISTS idx_user_permissions_org_group_id ON user_permissions(org_group_id);
    CREATE INDEX IF NOT EXISTS idx_user_permissions_organization_id ON user_permissions(organization_id);
    CREATE INDEX IF NOT EXISTS idx_user_permissions_permission_level ON user_permissions(permission_level);

    -- 3. 권한 체크 함수 업데이트 (조직/그룹 지원 및 상속 로직 포함)
    CREATE OR REPLACE FUNCTION check_process_permission_v2(
        p_proc_def_id TEXT,
        p_user_id UUID DEFAULT NULL,
        p_user_organizations TEXT[] DEFAULT NULL
    )
    RETURNS TABLE (
        id TEXT,
        user_id UUID,
        proc_def_id TEXT,
        readable BOOLEAN,
        executable BOOLEAN,
        writable BOOLEAN,
        target_type TEXT,
        permission_level TEXT,
        org_group_id UUID,
        organization_id TEXT
    ) AS $$
    BEGIN
        RETURN QUERY
        WITH user_org_groups AS (
            -- 사용자가 속한 조직 그룹 조회
            SELECT DISTINCT ocg.id AS group_id
            FROM org_chart_groups ocg
            JOIN org_chart_group_teams ocgt ON ocgt.group_id = ocg.id
            WHERE ocgt.team_id = ANY(p_user_organizations)
            AND ocg.tenant_id = public.tenant_id()
        ),
        all_permissions AS (
            SELECT up.*
            FROM user_permissions up
            WHERE up.tenant_id = public.tenant_id()
            AND (
                -- 직접 사용자 권한
                (up.target_type = 'user' AND up.user_id = p_user_id)
                -- 조직 권한
                OR (up.target_type = 'organization' AND up.organization_id = ANY(p_user_organizations))
                -- 조직 그룹 권한
                OR (up.target_type = 'org_group' AND up.org_group_id IN (SELECT group_id FROM user_org_groups))
            )
        )
        SELECT
            ap.id,
            ap.user_id,
            ap.proc_def_id,
            ap.readable,
            ap.executable,
            ap.writable,
            ap.target_type,
            ap.permission_level,
            ap.org_group_id,
            ap.organization_id
        FROM all_permissions ap
        WHERE (
            -- 직접 매칭
            ap.proc_def_id = p_proc_def_id
            -- 또는 계층적 매칭 (proc_def_ids JSONB 내에서)
            OR EXISTS (
                SELECT 1
                FROM jsonb_array_elements(ap.proc_def_ids->'major_proc_list') AS major_proc,
                    jsonb_array_elements(major_proc->'sub_proc_list') AS sub_proc
                WHERE ap.proc_def_ids->>'id' = p_proc_def_id
                OR major_proc->>'id' = p_proc_def_id
                OR sub_proc->>'id' = p_proc_def_id
            )
        );
    END;
    $$ LANGUAGE plpgsql SECURITY DEFINER;

    -- 4. 권한 요약 함수 (OR 병합으로 최종 권한 결정)
    CREATE OR REPLACE FUNCTION get_merged_permission(
        p_proc_def_id TEXT,
        p_user_id UUID,
        p_user_organizations TEXT[] DEFAULT NULL
    )
    RETURNS TABLE (
        has_readable BOOLEAN,
        has_executable BOOLEAN,
        has_writable BOOLEAN
    ) AS $$
    BEGIN
        RETURN QUERY
        SELECT
            COALESCE(bool_or(readable), false) AS has_readable,
            COALESCE(bool_or(executable), false) AS has_executable,
            COALESCE(bool_or(writable), false) AS has_writable
        FROM check_process_permission_v2(p_proc_def_id, p_user_id, p_user_organizations);
    END;
    $$ LANGUAGE plpgsql SECURITY DEFINER;

    -- 5. 기존 데이터 마이그레이션 (기존 readable 권한이 있으면 executable도 true로)
    UPDATE user_permissions
    SET executable = readable
    WHERE executable IS NULL OR executable = false;

    COMMENT ON COLUMN user_permissions.executable IS '프로세스 실행 권한';
    COMMENT ON COLUMN user_permissions.target_type IS '권한 대상 타입: user, organization, org_group';
    COMMENT ON COLUMN user_permissions.org_group_id IS '조직 그룹 ID (target_type=org_group일 때)';
    COMMENT ON COLUMN user_permissions.organization_id IS '조직 ID (target_type=organization일 때)';
    COMMENT ON COLUMN user_permissions.permission_level IS '권한 레벨: domain, mega, major, sub';
