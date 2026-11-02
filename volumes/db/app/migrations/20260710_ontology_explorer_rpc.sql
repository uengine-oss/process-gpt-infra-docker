-- =============================================================================
-- Ontology Explorer New — 그래프 읽기 RPC 3종 (specs/005 T004)
--
-- Apache AGE 그래프 process_gpt(스키마 0.2.x)를 프런트엔드(supabase-js .rpc)에
-- 노출하는 유일한 읽기 경로. 계약: specs/005-ontology-explorer-new/contracts/
-- graph-read-rpc.contract.md
--
-- 규약 (../process-gpt-vue3-main/ontology/INTEGRATION.md §4):
--  R1  vertex/edge 직접 반환 금지 — properties()/스칼라만 (::text 후 jsonb 파싱)
--  R2  사용자 입력은 바인드 파라미터 — cypher() 3번째 인자는 EXECUTE ... USING 경유
--  R3  모든 cypher에 tenant_id 필터 (그래프에 RLS 없음 — 이 계층이 격리 책임)
--  R4  읽기 전용 — MATCH/RETURN만. 쓰기는 scripts/seed-ontology-graph.mjs 만 수행
--
-- AGE 부재 내성: 그래프 접근은 전부 동적 EXECUTE 안에만 존재하므로 AGE 없는 DB
-- 에서도 CREATE FUNCTION 은 성공하고, 실행 시 installed:false 상태값을 반환한다
-- (예외 전파 금지, spec SC-005).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. 헬퍼 (순수 함수 — 그래프 미접근)
-- -----------------------------------------------------------------------------

-- 라벨 → 비즈니스 레이어 (data-model.md §1 — 5레벨). 화면 범위 밖 라벨은 NULL.
-- Pi* 는 이 리포 확장 라벨(10-pi-extensions.sql, INTEGRATION.md §7).
-- ⚠ 프런트 src/composables/ontologyNew/layerMapping.ts 와 반드시 동기.
CREATE OR REPLACE FUNCTION public.ontology_layer_of(p_label text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE p_label
        WHEN 'Perspective' THEN 'strategy'
        WHEN 'Objective' THEN 'strategy'
        WHEN 'KPI' THEN 'strategy'
        WHEN 'Initiative' THEN 'strategy'
        WHEN 'MegaProcess' THEN 'process'
        WHEN 'MajorProcess' THEN 'process'
        WHEN 'ProcessDefinition' THEN 'process'
        WHEN 'Activity' THEN 'task'
        WHEN 'Role' THEN 'task'
        WHEN 'User' THEN 'resource'
        WHEN 'Agent' THEN 'resource'
        WHEN 'Team' THEN 'resource'
        WHEN 'PiSystem' THEN 'resource'
        WHEN 'PiService' THEN 'resource'
        WHEN 'Skill' THEN 'knowledge'
        WHEN 'KnowledgeDoc' THEN 'knowledge'
        ELSE NULL
    END
$fn$;

-- 라벨별 업무키(SCHEMA.md §6, tenant_id 제외 부분) — 결정론적 노드 id 의 재료(V5).
CREATE OR REPLACE FUNCTION public.ontology_node_key(p_label text, p_props jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE p_label
        WHEN 'Activity' THEN (p_props->>'proc_def_id') || ':' || (p_props->>'element_id')
        WHEN 'Role' THEN (p_props->>'proc_def_id') || ':' || (p_props->>'name')
        WHEN 'Skill' THEN p_props->>'name'
        ELSE p_props->>'id'
    END
$fn$;

-- 캔버스 노드 id = `${label}:${tenant}:${업무키}` (graph vertex id 는 세션 간 불안정)
CREATE OR REPLACE FUNCTION public.ontology_node_id(p_label text, p_tenant text, p_props jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT p_label || ':' || p_tenant || ':' || COALESCE(public.ontology_node_key(p_label, p_props), '?')
$fn$;

-- 표시명 폴백: name → username → alias → file_name → 업무키
CREATE OR REPLACE FUNCTION public.ontology_node_name(p_label text, p_props jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT COALESCE(
        NULLIF(btrim(COALESCE(p_props->>'name', '')), ''),
        NULLIF(btrim(COALESCE(p_props->>'username', '')), ''),
        NULLIF(btrim(COALESCE(p_props->>'alias', '')), ''),
        NULLIF(btrim(COALESCE(p_props->>'file_name', '')), ''),
        public.ontology_node_key(p_label, p_props)
    )
$fn$;

-- -----------------------------------------------------------------------------
-- 1. ontology_graph_health(p_tenant_id) → jsonb
--    {installed, schema_version, layer_counts:{strategy,process,task,resource,knowledge}, dangling_count}
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ontology_graph_health(p_tenant_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ag_catalog, public, pg_temp
AS $fn$
DECLARE
    v_zero jsonb := jsonb_build_object('strategy', 0, 'process', 0, 'task', 0, 'resource', 0, 'knowledge', 0);
    v_counts jsonb := jsonb_build_object('strategy', 0, 'process', 0, 'task', 0, 'resource', 0, 'knowledge', 0);
    v_version text;
    v_graph_exists boolean := false;
    v_dangling bigint := 0;
    v_label text;
    v_layer text;
    v_cnt bigint;
BEGIN
    IF p_tenant_id IS NULL OR btrim(p_tenant_id) = '' THEN
        RAISE EXCEPTION 'ontology_graph_health: p_tenant_id is required';
    END IF;

    -- AGE 확장 + 그래프 존재 (전부 동적 — AGE 없는 DB 에서도 함수 생성/실행 가능)
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'age') THEN
        RETURN jsonb_build_object('installed', false, 'schema_version', NULL,
                                  'layer_counts', v_zero, 'dangling_count', 0);
    END IF;

    BEGIN
        EXECUTE $dyn$LOAD 'age'$dyn$;
        EXECUTE $dyn$SELECT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'process_gpt')$dyn$
            INTO v_graph_exists;
    EXCEPTION WHEN OTHERS THEN
        v_graph_exists := false;
    END;

    IF NOT v_graph_exists THEN
        RETURN jsonb_build_object('installed', false, 'schema_version', NULL,
                                  'layer_counts', v_zero, 'dangling_count', 0);
    END IF;

    -- GraphMeta.schema_version (부재 = 부분 설치 → 미설치 취급, spec edge case)
    BEGIN
        EXECUTE $dyn$
            SELECT public.agtext(v)
            FROM ag_catalog.cypher('process_gpt', $cy$
                MATCH (m:GraphMeta {id: 'meta'}) RETURN m.schema_version
            $cy$) AS (v ag_catalog.agtype)
        $dyn$ INTO v_version;
    EXCEPTION WHEN OTHERS THEN
        v_version := NULL;
    END;

    IF v_version IS NULL THEN
        RETURN jsonb_build_object('installed', false, 'schema_version', NULL,
                                  'layer_counts', v_zero, 'dangling_count', 0);
    END IF;

    -- 레이어별 count — 라벨별 tenant btree 인덱스(ix_v_<label>_tenant)를 타도록 라벨 단위 질의
    FOR v_label IN
        SELECT unnest(ARRAY['Perspective','Objective','KPI','Initiative',
                            'MegaProcess','MajorProcess','ProcessDefinition','Activity','Role',
                            'User','Agent','Team','PiSystem','PiService','Skill','KnowledgeDoc'])
    LOOP
        v_layer := public.ontology_layer_of(v_label);
        BEGIN
            EXECUTE format($dyn$
                SELECT (public.agtext(c))::bigint
                FROM ag_catalog.cypher('process_gpt', $cy$
                    MATCH (n:%s {tenant_id: $t}) RETURN count(n)
                $cy$, $1) AS (c ag_catalog.agtype)
            $dyn$, v_label)
            INTO v_cnt
            USING jsonb_build_object('t', p_tenant_id)::text::ag_catalog.agtype;
        EXCEPTION WHEN OTHERS THEN
            v_cnt := 0; -- 라벨 미생성(부분 설치) 등은 0 으로 강등
        END;
        v_counts := jsonb_set(v_counts, ARRAY[v_layer],
                              to_jsonb(COALESCE((v_counts->>v_layer)::bigint, 0) + COALESCE(v_cnt, 0)));
    END LOOP;

    -- 미해소 dangling (00-init 의 public.graph_sync_dangling; 테이블 부재 시 0)
    BEGIN
        IF to_regclass('public.graph_sync_dangling') IS NOT NULL THEN
            EXECUTE 'SELECT count(*) FROM public.graph_sync_dangling WHERE resolved_at IS NULL'
                INTO v_dangling;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_dangling := 0;
    END;

    RETURN jsonb_build_object(
        'installed', true,
        'schema_version', v_version,
        'layer_counts', v_counts,
        'dangling_count', COALESCE(v_dangling, 0)
    );
END;
$fn$;

-- -----------------------------------------------------------------------------
-- 2. ontology_business_graph(p_tenant_id, p_layers) → jsonb {nodes, edges, truncated?}
--    노드 16종 + 엣지 21종(엔드포인트 조합 26) 화이트리스트 서브그래프 (data-model.md §1·§3)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ontology_business_graph(
    p_tenant_id text,
    p_layers text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ag_catalog, public, pg_temp
AS $fn$
DECLARE
    c_node_limit constant int := 5000;
    v_health jsonb;
    -- ⚠ ag_catalog.agtype 로 선언하지 말 것 — DECLARE 의 타입 참조는 CREATE FUNCTION
    --   시점에 해석되어 AGE 없는 DB 에서 마이그레이션 전체가 실패한다(AGE 부재 내성 위반).
    --   text 로 두고 USING 표현식에서 캐스트한다(표현식은 첫 실행 시점 파싱).
    v_params text;
    v_nodes jsonb := '[]'::jsonb;
    v_edges jsonb := '[]'::jsonb;
    v_arr jsonb;
    v_label text;
    v_layer text;
    v_truncated boolean := false;
    v_node_count int := 0;
    v_spec text[];
    -- 엣지 화이트리스트: {엣지라벨, from라벨, to라벨} (data-model.md §3 — 멀티 endpoint 는 조합 전개)
    c_edge_specs constant text[][] := ARRAY[
        ARRAY['IN_PERSPECTIVE',     'Objective',         'Perspective'],
        ARRAY['CONTRIBUTES_TO',     'Objective',         'Objective'],
        ARRAY['MEASURES',           'KPI',               'Objective'],
        ARRAY['DRIVES',             'Initiative',        'Objective'],
        ARRAY['OWNED_BY',           'Initiative',        'User'],
        ARRAY['SOURCED_FROM',       'KPI',               'ProcessDefinition'],
        ARRAY['REALIZED_BY',        'Initiative',        'ProcessDefinition'],
        ARRAY['CONTAINS',           'MegaProcess',       'MajorProcess'],
        ARRAY['CONTAINS',           'MajorProcess',      'ProcessDefinition'],
        ARRAY['DEFINES',            'ProcessDefinition', 'Activity'],
        ARRAY['DEFINES',            'ProcessDefinition', 'Role'],
        ARRAY['FLOWS_TO',           'Activity',          'Activity'],
        ARRAY['CALLS',              'Activity',          'ProcessDefinition'],
        ARRAY['IN_LANE',            'Activity',          'Role'],
        ARRAY['RESOLVES_TO',        'Role',              'User'],
        ARRAY['RESOLVES_TO',        'Role',              'Team'],
        -- Role→Agent 는 이 리포 확장 조합(코어 SCHEMA §5.2 는 User|Team|OrgGroup) —
        -- 에이전트를 동등 수행 주체로 취급, seed 의 endpoint 해석과 동기
        ARRAY['RESOLVES_TO',        'Role',              'Agent'],
        ARRAY['PERFORMED_BY_AGENT', 'Activity',          'Agent'],
        ARRAY['MEMBER_OF',          'User',              'Team'],
        ARRAY['MEMBER_OF',          'Agent',             'Team'],
        ARRAY['PART_OF',            'Team',              'Team'],
        ARRAY['REQUIRES_SKILL',     'Activity',          'Skill'],
        ARRAY['HAS_SKILL',          'Agent',             'Skill'],
        ARRAY['EXTENDS',            'Skill',             'Skill'],
        -- PI 확장 (10-pi-extensions.sql) — 테스크→시스템/서비스 관문
        ARRAY['PI_USES_SYSTEM',     'Activity',          'PiSystem'],
        ARRAY['PI_USES_SERVICE',    'Activity',          'PiService']
    ];
BEGIN
    IF p_tenant_id IS NULL OR btrim(p_tenant_id) = '' THEN
        RAISE EXCEPTION 'ontology_business_graph: p_tenant_id is required';
    END IF;

    -- 미설치/부분 설치는 빈 그래프 반환 (헬스 게이트는 프런트 책임이나 방어적으로 처리)
    v_health := public.ontology_graph_health(p_tenant_id);
    IF NOT (v_health->>'installed')::boolean THEN
        RETURN jsonb_build_object('nodes', '[]'::jsonb, 'edges', '[]'::jsonb);
    END IF;

    v_params := jsonb_build_object('t', p_tenant_id)::text;

    -- ── 노드: 라벨별 수집 (p_layers 필터, label→name 정렬은 프런트 layout 이 결정론 재정렬) ──
    FOR v_label IN
        SELECT unnest(ARRAY['Perspective','Objective','KPI','Initiative',
                            'MegaProcess','MajorProcess','ProcessDefinition','Activity','Role',
                            'User','Agent','Team','PiSystem','PiService','Skill','KnowledgeDoc'])
    LOOP
        v_layer := public.ontology_layer_of(v_label);
        IF p_layers IS NOT NULL AND NOT (v_layer = ANY (p_layers)) THEN
            CONTINUE;
        END IF;
        IF v_node_count >= c_node_limit THEN
            -- 상한 도달 — 라벨 경계 단위의 coarse 절단 (contract: truncated 플래그로 고지)
            v_truncated := true;
            EXIT;
        END IF;

        BEGIN
            EXECUTE format($dyn$
                SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'id',         public.ontology_node_id(%L, %L, (props)::text::jsonb),
                    'label',      %L,
                    'layer',      %L,
                    'name',       public.ontology_node_name(%L, (props)::text::jsonb),
                    'properties', (props)::text::jsonb
                )), '[]'::jsonb)
                FROM ag_catalog.cypher('process_gpt', $cy$
                    MATCH (n:%s {tenant_id: $t}) RETURN properties(n)
                $cy$, $1) AS (props ag_catalog.agtype)
            $dyn$, v_label, p_tenant_id, v_label, v_layer, v_label, v_label)
            INTO v_arr
            USING v_params::ag_catalog.agtype;
        EXCEPTION WHEN OTHERS THEN
            v_arr := '[]'::jsonb; -- 라벨 미생성 등 — 빈 결과로 강등
        END;

        v_node_count := v_node_count + jsonb_array_length(v_arr);
        v_nodes := v_nodes || v_arr;
    END LOOP;

    -- ── 엣지: 화이트리스트 조합별 수집 — 양끝 라벨이 모두 반환 대상 레이어일 때만 ──
    FOREACH v_spec SLICE 1 IN ARRAY c_edge_specs
    LOOP
        IF p_layers IS NOT NULL AND (
            NOT (public.ontology_layer_of(v_spec[2]) = ANY (p_layers)) OR
            NOT (public.ontology_layer_of(v_spec[3]) = ANY (p_layers))
        ) THEN
            CONTINUE;
        END IF;

        -- 행 단위 plpgsql 루프 금지 — jsonb 배열 append 는 O(n²)(매번 전체 복사).
        -- id 조립(FLOWS_TO 는 MERGE 키 seq_id 접미 포함)까지 SQL 집계 한 번으로 처리한다.
        BEGIN
            EXECUTE format($dyn$
                SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'id', %L || ':' || src || '->' || dst
                          || CASE WHEN %L = 'FLOWS_TO' AND props ? 'seq_id'
                                  THEN '#' || (props->>'seq_id') ELSE '' END,
                    'type', %L,
                    'source', src,
                    'target', dst,
                    'properties', props)), '[]'::jsonb)
                FROM (
                    SELECT public.ontology_node_id(%L, %L, (pa)::text::jsonb) AS src,
                           public.ontology_node_id(%L, %L, (pb)::text::jsonb) AS dst,
                           COALESCE((pe)::text::jsonb, '{}'::jsonb) AS props
                    FROM ag_catalog.cypher('process_gpt', $cy$
                        MATCH (a:%s {tenant_id: $t})-[e:%s]->(b:%s {tenant_id: $t})
                        RETURN properties(a), properties(e), properties(b)
                    $cy$, $1) AS (pa ag_catalog.agtype, pe ag_catalog.agtype, pb ag_catalog.agtype)
                ) s
            $dyn$, v_spec[1], v_spec[1], v_spec[1],
                   v_spec[2], p_tenant_id, v_spec[3], p_tenant_id,
                   v_spec[2], v_spec[1], v_spec[3])
            INTO v_arr
            USING v_params::ag_catalog.agtype;
        EXCEPTION WHEN OTHERS THEN
            v_arr := '[]'::jsonb;
        END;

        v_edges := v_edges || v_arr;
    END LOOP;

    RETURN jsonb_build_object('nodes', v_nodes, 'edges', v_edges)
        || CASE WHEN v_truncated THEN jsonb_build_object('truncated', true) ELSE '{}'::jsonb END;
END;
$fn$;

-- -----------------------------------------------------------------------------
-- 3. ontology_execution_rollup(p_tenant_id) → jsonb {processes, activities, kpi_surveys}
--    정량 집계는 원천 테이블(bpm_proc_inst/todolist — 실측 시각) 사용,
--    정성(설문)은 그래프 SURVEYED 엣지 집계. 데이터/테이블 부재 시 빈 배열 (FR-010).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ontology_execution_rollup(p_tenant_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ag_catalog, public, pg_temp
AS $fn$
DECLARE
    v_processes jsonb := '[]'::jsonb;
    v_activities jsonb := '[]'::jsonb;
    v_surveys jsonb := '[]'::jsonb;
BEGIN
    IF p_tenant_id IS NULL OR btrim(p_tenant_id) = '' THEN
        RAISE EXCEPTION 'ontology_execution_rollup: p_tenant_id is required';
    END IF;

    -- 진행 중 인스턴스 수 (프로세스별)
    BEGIN
        IF to_regclass('public.bpm_proc_inst') IS NOT NULL THEN
            EXECUTE $dyn$
                SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'proc_def_id', proc_def_id, 'running_count', cnt)), '[]'::jsonb)
                FROM (
                    SELECT proc_def_id, count(*) AS cnt
                    FROM public.bpm_proc_inst
                    WHERE tenant_id = $1
                      AND status::text = 'RUNNING'
                      AND COALESCE(is_deleted, false) = false
                      AND proc_def_id IS NOT NULL
                    GROUP BY proc_def_id
                ) s
            $dyn$ INTO v_processes USING p_tenant_id;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_processes := '[]'::jsonb;
    END;

    -- 테스크(Activity)별 워크아이템 집계 — 병목 신호 (FR-010)
    BEGIN
        IF to_regclass('public.todolist') IS NOT NULL THEN
            EXECUTE $dyn$
                SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'proc_def_id', proc_def_id,
                    'element_id', activity_id,
                    'work_item_count', total_cnt,
                    'avg_duration_hours', avg_hours,
                    'rework_sum', rework_sum,
                    'in_progress_count', inprog_cnt)), '[]'::jsonb)
                FROM (
                    SELECT proc_def_id,
                           activity_id,
                           count(*) AS total_cnt,
                           round((avg(EXTRACT(EPOCH FROM (end_date - start_date)) / 3600.0)
                                  FILTER (WHERE status::text = 'DONE'
                                          AND start_date IS NOT NULL AND end_date IS NOT NULL
                                          AND end_date >= start_date))::numeric, 1) AS avg_hours,
                           COALESCE(sum(rework_count), 0) AS rework_sum,
                           count(*) FILTER (WHERE status::text IN ('TODO', 'IN_PROGRESS')) AS inprog_cnt
                    FROM public.todolist
                    WHERE tenant_id = $1
                      AND proc_def_id IS NOT NULL
                      AND activity_id IS NOT NULL
                    GROUP BY proc_def_id, activity_id
                ) s
            $dyn$ INTO v_activities USING p_tenant_id;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_activities := '[]'::jsonb;
    END;

    -- KPI 설문 평균 (정성 평가) — 그래프 SURVEYED 엣지 (strategy-service 계보; 부재 시 빈 배열)
    BEGIN
        IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'age') THEN
            EXECUTE $dyn$LOAD 'age'$dyn$;
            EXECUTE $dyn$
                SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'kpi_id', public.agtext(kid),
                    'avg_rating', round((public.agtext(avg_r))::numeric, 2),
                    'answered_count', (public.agtext(cnt))::int)), '[]'::jsonb)
                FROM ag_catalog.cypher('process_gpt', $cy$
                    MATCH (pi:ProcessInstance)-[s:SURVEYED]->(k:KPI {tenant_id: $t})
                    WHERE s.status = 'ANSWERED'
                    RETURN k.id, avg(s.avg_rating), count(s)
                $cy$, $1) AS (kid ag_catalog.agtype, avg_r ag_catalog.agtype, cnt ag_catalog.agtype)
            $dyn$ INTO v_surveys
            USING jsonb_build_object('t', p_tenant_id)::text::ag_catalog.agtype;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_surveys := '[]'::jsonb;
    END;

    RETURN jsonb_build_object(
        'processes', v_processes,
        'activities', v_activities,
        'kpi_surveys', v_surveys
    );
END;
$fn$;

-- -----------------------------------------------------------------------------
-- 4. 권한 — authenticated/service_role 전용 (anon 차단). 그래프에 RLS 가 없으므로
--    이 함수들이 유일한 노출면이다.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.ontology_graph_health(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ontology_business_graph(text, text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ontology_execution_rollup(text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.ontology_graph_health(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.ontology_business_graph(text, text[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.ontology_execution_rollup(text) TO authenticated, service_role;
