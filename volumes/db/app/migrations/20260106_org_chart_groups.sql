-- ============================================
-- Org Chart Groups 테이블 (프로세스 권한 설정용 조직 그룹)
-- ============================================
CREATE TABLE IF NOT EXISTS org_chart_groups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    description TEXT,
    tenant_id VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 그룹에 속한 팀 연결 테이블
CREATE TABLE IF NOT EXISTS org_chart_group_teams (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id UUID NOT NULL REFERENCES org_chart_groups(id) ON DELETE CASCADE,
    team_id VARCHAR(255) NOT NULL,
    team_name VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_org_chart_groups_tenant ON org_chart_groups(tenant_id);
CREATE INDEX IF NOT EXISTS idx_org_chart_group_teams_group ON org_chart_group_teams(group_id);
CREATE INDEX IF NOT EXISTS idx_org_chart_group_teams_team ON org_chart_group_teams(team_id);

-- RLS Policies
ALTER TABLE org_chart_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_chart_group_teams ENABLE ROW LEVEL SECURITY;

CREATE POLICY "org_chart_groups_select" ON org_chart_groups FOR SELECT USING (tenant_id = public.tenant_id());
CREATE POLICY "org_chart_groups_insert" ON org_chart_groups FOR INSERT WITH CHECK (tenant_id = public.tenant_id());
CREATE POLICY "org_chart_groups_update" ON org_chart_groups FOR UPDATE USING (tenant_id = public.tenant_id());
CREATE POLICY "org_chart_groups_delete" ON org_chart_groups FOR DELETE USING (tenant_id = public.tenant_id());

CREATE POLICY "org_chart_group_teams_select" ON org_chart_group_teams FOR SELECT USING (
    EXISTS (SELECT 1 FROM org_chart_groups g WHERE g.id = group_id AND g.tenant_id = public.tenant_id())
);
CREATE POLICY "org_chart_group_teams_insert" ON org_chart_group_teams FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM org_chart_groups g WHERE g.id = group_id AND g.tenant_id = public.tenant_id())
);
CREATE POLICY "org_chart_group_teams_update" ON org_chart_group_teams FOR UPDATE USING (
    EXISTS (SELECT 1 FROM org_chart_groups g WHERE g.id = group_id AND g.tenant_id = public.tenant_id())
);
CREATE POLICY "org_chart_group_teams_delete" ON org_chart_group_teams FOR DELETE USING (
    EXISTS (SELECT 1 FROM org_chart_groups g WHERE g.id = group_id AND g.tenant_id = public.tenant_id())
);

-- 권한 부여
GRANT ALL ON org_chart_groups TO authenticated;
GRANT SELECT ON org_chart_groups TO anon;
GRANT ALL ON org_chart_group_teams TO authenticated;
GRANT SELECT ON org_chart_group_teams TO anon;

-- Comments
COMMENT ON TABLE org_chart_groups IS '조직도 그룹 - 프로세스 권한 설정용';
COMMENT ON TABLE org_chart_group_teams IS '그룹에 속한 팀 매핑';
COMMENT ON COLUMN org_chart_groups.name IS '그룹 이름';
COMMENT ON COLUMN org_chart_groups.description IS '그룹 설명';
COMMENT ON COLUMN org_chart_group_teams.team_id IS '조직도의 팀 ID';
COMMENT ON COLUMN org_chart_group_teams.team_name IS '팀 이름 (조회 편의용)';
