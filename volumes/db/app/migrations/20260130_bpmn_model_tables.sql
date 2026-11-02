-- ============================================
-- Phase 1: BPMN Model Tables
-- XML 파싱 결과를 정규화된 테이블에 저장
-- ============================================

-- 1. TB_BPMN_MODEL (모델 메타데이터)
-- 기존 proc_def 테이블과 연동하여 파싱된 메타정보 저장
CREATE TABLE IF NOT EXISTS public.tb_bpmn_model (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id TEXT NOT NULL DEFAULT 'default',
    proc_def_id TEXT NOT NULL,  -- 기존 proc_def 테이블 참조
    name VARCHAR(500),
    description TEXT,
    status VARCHAR(50) DEFAULT 'draft',  -- draft, review, published, archived
    parent_proc_def_id TEXT,  -- 상위 프로세스 (mega/major/sub 계층)
    domain_id TEXT,
    hierarchy_level VARCHAR(20),  -- mega, major, sub
    process_id VARCHAR(255),  -- BPMN 내 process ID (예: Process_1)
    is_executable BOOLEAN DEFAULT false,
    xml_hash VARCHAR(64),  -- XML 변경 감지용 해시
    node_count INTEGER DEFAULT 0,
    link_count INTEGER DEFAULT 0,
    lane_count INTEGER DEFAULT 0,
    parsed_at TIMESTAMPTZ,
    created_by TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT tb_bpmn_model_proc_def_unique UNIQUE (tenant_id, proc_def_id)
);

-- 2. TB_BPMN_LANE (Pool/Lane 정보)
CREATE TABLE IF NOT EXISTS public.tb_bpmn_lane (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_id UUID NOT NULL REFERENCES public.tb_bpmn_model(id) ON DELETE CASCADE,
    element_id VARCHAR(255) NOT NULL,  -- BPMN element ID (예: Lane_1abc)
    element_type VARCHAR(100) NOT NULL,  -- Participant, Lane
    name VARCHAR(500),
    participant_ref VARCHAR(255),  -- Pool이 참조하는 Process
    parent_lane_id UUID REFERENCES public.tb_bpmn_lane(id) ON DELETE SET NULL,
    is_horizontal BOOLEAN DEFAULT true,
    x NUMERIC,
    y NUMERIC,
    width NUMERIC,
    height NUMERIC,
    properties JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT tb_bpmn_lane_unique UNIQUE (model_id, element_id)
);

-- 3. TB_BPMN_NODE (노드 정보)
CREATE TABLE IF NOT EXISTS public.tb_bpmn_node (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_id UUID NOT NULL REFERENCES public.tb_bpmn_model(id) ON DELETE CASCADE,
    element_id VARCHAR(255) NOT NULL,  -- BPMN element ID (예: Activity_1abc)
    element_type VARCHAR(100) NOT NULL,  -- UserTask, ServiceTask, Gateway, Event, SubProcess 등
    name VARCHAR(500),
    x NUMERIC,
    y NUMERIC,
    width NUMERIC,
    height NUMERIC,
    lane_id UUID REFERENCES public.tb_bpmn_lane(id) ON DELETE SET NULL,
    -- Task 관련 속성
    task_type VARCHAR(50),  -- manual, user, service, script, gpt
    assignee TEXT,
    candidate_groups TEXT,
    candidate_users TEXT,
    due_date TEXT,
    -- Gateway 관련 속성
    gateway_direction VARCHAR(20),  -- diverging, converging, mixed
    -- Event 관련 속성
    event_type VARCHAR(50),  -- start, end, intermediate
    event_definition VARCHAR(50),  -- timer, message, signal, error, etc.
    -- SubProcess 관련 속성
    is_expanded BOOLEAN DEFAULT true,
    called_element VARCHAR(255),  -- Call Activity용
    -- 공통 속성
    documentation TEXT,
    properties JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT tb_bpmn_node_unique UNIQUE (model_id, element_id)
);

-- 4. TB_BPMN_LINK (연결선 정보)
CREATE TABLE IF NOT EXISTS public.tb_bpmn_link (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_id UUID NOT NULL REFERENCES public.tb_bpmn_model(id) ON DELETE CASCADE,
    element_id VARCHAR(255) NOT NULL,  -- BPMN element ID (예: Flow_1abc)
    element_type VARCHAR(100) NOT NULL,  -- SequenceFlow, MessageFlow, Association
    name VARCHAR(500),
    source_node_id UUID REFERENCES public.tb_bpmn_node(id) ON DELETE SET NULL,
    target_node_id UUID REFERENCES public.tb_bpmn_node(id) ON DELETE SET NULL,
    source_element_id VARCHAR(255),  -- BPMN source ref
    target_element_id VARCHAR(255),  -- BPMN target ref
    condition_expression TEXT,
    is_default BOOLEAN DEFAULT false,
    waypoints JSONB,  -- [{x, y}, {x, y}, ...]
    properties JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT tb_bpmn_link_unique UNIQUE (model_id, element_id)
);

-- 5. TB_BPMN_VERSION (버전 이력)
CREATE TABLE IF NOT EXISTS public.tb_bpmn_version (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_id UUID NOT NULL REFERENCES public.tb_bpmn_model(id) ON DELETE CASCADE,
    version_number INTEGER NOT NULL,
    version_label VARCHAR(50),  -- v1.0, v1.1, etc.
    xml_snapshot TEXT NOT NULL,  -- 버전 시점의 XML
    change_log TEXT,
    node_count INTEGER DEFAULT 0,
    link_count INTEGER DEFAULT 0,
    created_by TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT tb_bpmn_version_unique UNIQUE (model_id, version_number)
);

-- 6. TB_BPMN_MODEL_LOCK (편집 잠금)
CREATE TABLE IF NOT EXISTS public.tb_bpmn_model_lock (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_id UUID NOT NULL REFERENCES public.tb_bpmn_model(id) ON DELETE CASCADE,
    locked_by TEXT NOT NULL,
    locked_by_name VARCHAR(255),
    locked_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ,  -- 자동 잠금 해제 시간
    CONSTRAINT tb_bpmn_model_lock_unique UNIQUE (model_id)
);

-- ============================================
-- Indexes
-- ============================================

-- TB_BPMN_MODEL indexes
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_model_tenant ON public.tb_bpmn_model(tenant_id);
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_model_proc_def ON public.tb_bpmn_model(proc_def_id);
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_model_status ON public.tb_bpmn_model(status);
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_model_parent ON public.tb_bpmn_model(parent_proc_def_id);
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_model_domain ON public.tb_bpmn_model(domain_id);

-- TB_BPMN_LANE indexes
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_lane_model ON public.tb_bpmn_lane(model_id);
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_lane_type ON public.tb_bpmn_lane(element_type);

-- TB_BPMN_NODE indexes
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_node_model ON public.tb_bpmn_node(model_id);
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_node_type ON public.tb_bpmn_node(element_type);
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_node_lane ON public.tb_bpmn_node(lane_id);
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_node_task_type ON public.tb_bpmn_node(task_type);

-- TB_BPMN_LINK indexes
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_link_model ON public.tb_bpmn_link(model_id);
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_link_source ON public.tb_bpmn_link(source_node_id);
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_link_target ON public.tb_bpmn_link(target_node_id);

-- TB_BPMN_VERSION indexes
CREATE INDEX IF NOT EXISTS idx_tb_bpmn_version_model ON public.tb_bpmn_version(model_id);

-- ============================================
-- Row Level Security (RLS)
-- ============================================

ALTER TABLE public.tb_bpmn_model ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tb_bpmn_lane ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tb_bpmn_node ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tb_bpmn_link ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tb_bpmn_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tb_bpmn_model_lock ENABLE ROW LEVEL SECURITY;

-- Model policies
CREATE POLICY "tb_bpmn_model_select_policy" ON public.tb_bpmn_model FOR SELECT USING (true);
CREATE POLICY "tb_bpmn_model_insert_policy" ON public.tb_bpmn_model FOR INSERT WITH CHECK (true);
CREATE POLICY "tb_bpmn_model_update_policy" ON public.tb_bpmn_model FOR UPDATE USING (true);
CREATE POLICY "tb_bpmn_model_delete_policy" ON public.tb_bpmn_model FOR DELETE USING (true);

-- Lane policies
CREATE POLICY "tb_bpmn_lane_select_policy" ON public.tb_bpmn_lane FOR SELECT USING (true);
CREATE POLICY "tb_bpmn_lane_insert_policy" ON public.tb_bpmn_lane FOR INSERT WITH CHECK (true);
CREATE POLICY "tb_bpmn_lane_update_policy" ON public.tb_bpmn_lane FOR UPDATE USING (true);
CREATE POLICY "tb_bpmn_lane_delete_policy" ON public.tb_bpmn_lane FOR DELETE USING (true);

-- Node policies
CREATE POLICY "tb_bpmn_node_select_policy" ON public.tb_bpmn_node FOR SELECT USING (true);
CREATE POLICY "tb_bpmn_node_insert_policy" ON public.tb_bpmn_node FOR INSERT WITH CHECK (true);
CREATE POLICY "tb_bpmn_node_update_policy" ON public.tb_bpmn_node FOR UPDATE USING (true);
CREATE POLICY "tb_bpmn_node_delete_policy" ON public.tb_bpmn_node FOR DELETE USING (true);

-- Link policies
CREATE POLICY "tb_bpmn_link_select_policy" ON public.tb_bpmn_link FOR SELECT USING (true);
CREATE POLICY "tb_bpmn_link_insert_policy" ON public.tb_bpmn_link FOR INSERT WITH CHECK (true);
CREATE POLICY "tb_bpmn_link_update_policy" ON public.tb_bpmn_link FOR UPDATE USING (true);
CREATE POLICY "tb_bpmn_link_delete_policy" ON public.tb_bpmn_link FOR DELETE USING (true);

-- Version policies
CREATE POLICY "tb_bpmn_version_select_policy" ON public.tb_bpmn_version FOR SELECT USING (true);
CREATE POLICY "tb_bpmn_version_insert_policy" ON public.tb_bpmn_version FOR INSERT WITH CHECK (true);
CREATE POLICY "tb_bpmn_version_update_policy" ON public.tb_bpmn_version FOR UPDATE USING (true);
CREATE POLICY "tb_bpmn_version_delete_policy" ON public.tb_bpmn_version FOR DELETE USING (true);

-- Lock policies
CREATE POLICY "tb_bpmn_model_lock_select_policy" ON public.tb_bpmn_model_lock FOR SELECT USING (true);
CREATE POLICY "tb_bpmn_model_lock_insert_policy" ON public.tb_bpmn_model_lock FOR INSERT WITH CHECK (true);
CREATE POLICY "tb_bpmn_model_lock_update_policy" ON public.tb_bpmn_model_lock FOR UPDATE USING (true);
CREATE POLICY "tb_bpmn_model_lock_delete_policy" ON public.tb_bpmn_model_lock FOR DELETE USING (true);

-- ============================================
-- Triggers for updated_at
-- ============================================

CREATE OR REPLACE FUNCTION update_tb_bpmn_model_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_tb_bpmn_model_updated_at
    BEFORE UPDATE ON public.tb_bpmn_model
    FOR EACH ROW
    EXECUTE FUNCTION update_tb_bpmn_model_updated_at();

-- ============================================
-- Helper Functions
-- ============================================

-- 모델의 다음 버전 번호 가져오기
CREATE OR REPLACE FUNCTION get_next_version_number(p_model_id UUID)
RETURNS INTEGER AS $$
DECLARE
    v_max_version INTEGER;
BEGIN
    SELECT COALESCE(MAX(version_number), 0) + 1
    INTO v_max_version
    FROM public.tb_bpmn_version
    WHERE model_id = p_model_id;

    RETURN v_max_version;
END;
$$ LANGUAGE plpgsql;

-- 모델 통계 업데이트 함수
CREATE OR REPLACE FUNCTION update_model_counts(p_model_id UUID)
RETURNS void AS $$
BEGIN
    UPDATE public.tb_bpmn_model
    SET
        node_count = (SELECT COUNT(*) FROM public.tb_bpmn_node WHERE model_id = p_model_id),
        link_count = (SELECT COUNT(*) FROM public.tb_bpmn_link WHERE model_id = p_model_id),
        lane_count = (SELECT COUNT(*) FROM public.tb_bpmn_lane WHERE model_id = p_model_id),
        parsed_at = NOW()
    WHERE id = p_model_id;
END;
$$ LANGUAGE plpgsql;

-- 만료된 잠금 자동 해제 함수
CREATE OR REPLACE FUNCTION cleanup_expired_locks()
RETURNS INTEGER AS $$
DECLARE
    v_deleted_count INTEGER;
BEGIN
    DELETE FROM public.tb_bpmn_model_lock
    WHERE expires_at IS NOT NULL AND expires_at < NOW();

    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    RETURN v_deleted_count;
END;
$$ LANGUAGE plpgsql;
