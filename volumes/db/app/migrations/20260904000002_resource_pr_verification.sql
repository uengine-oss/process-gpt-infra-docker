-- ============================================================
-- 병합 요청 검증(pre-merge verification) — 시나리오 + base/head 비교 결과
--
-- 목적: "이 병합 요청을 반영하면 기존 동작이 깨지지 않는가" 를 병합 **전에** 확인한다.
-- 리뷰어가 PR 화면에서 검증을 실행하면, 저장된 주요 시나리오를
--   - base(변경 전, 보통 main) 버전
--   - head(변경 후, PR 브랜치) 버전
-- 두 벌로 실행해 채점하고, **통과하던 단계가 깨진 것**을 골라낸다.
--
-- 시나리오는 리소스가 처음 만들어질 때(스킬 생성 시 test-runner/evaluator 단계)
-- 확보되어 여기에 보관되고, 이후 모든 PR 검증이 같은 시나리오를 재사용한다.
--
-- resource_type 은 resource_pull_requests 와 같은 어휘('skill'|'bpmn'|'dmn')를 쓴다.
-- 현재 실행기는 skill 만 지원하지만, 테이블·API·화면은 3종 공용으로 둔다.
--
--   resource_eval_suites  1 : N  resource_eval_cases    (리소스별 시나리오 모음)
--   resource_eval_suites  1 : N  resource_eval_runs     (검증 실행 회차)
--   resource_eval_runs    1 : N  resource_eval_results  (회차 × 시나리오 × variant)
-- ============================================================

-- ------------------------------------------------------------
-- 1) 스위트: 리소스 하나당 시나리오 모음 하나
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.resource_eval_suites (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id              text NOT NULL DEFAULT public.tenant_id(),
    resource_type          text NOT NULL,
    -- skill: 스킬 이름 / bpmn: proc_def id / dmn: dmn id
    resource_id            text NOT NULL,
    -- 시나리오가 처음 만들어진(=리소스가 생성된) 대화방
    source_conversation_id text NULL,
    created_by             uuid NULL,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT resource_eval_suites_type_check
        CHECK (resource_type IN ('skill', 'bpmn', 'dmn')),
    CONSTRAINT resource_eval_suites_tenant_resource_key
        UNIQUE (tenant_id, resource_type, resource_id)
);

CREATE INDEX IF NOT EXISTS idx_resource_eval_suites_tenant
    ON public.resource_eval_suites (tenant_id, resource_type, resource_id);

-- ------------------------------------------------------------
-- 2) 케이스: 주요 시나리오 한 건
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.resource_eval_cases (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    suite_id        uuid NOT NULL REFERENCES public.resource_eval_suites (id) ON DELETE CASCADE,
    tenant_id       text NOT NULL DEFAULT public.tenant_id(),
    -- 디렉터리명으로도 쓰이는 식별자
    eval_name       text NOT NULL,
    prompt          text NOT NULL,
    expected_output text NULL,
    -- 입력 파일(스토리지 경로 등): ["files/<uuid>.docx", ...]
    files           jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- 검증 "단계" 목록. 병합 전후로 이 단계별 통과 여부를 비교한다.
    assertions      jsonb NOT NULL DEFAULT '[]'::jsonb,
    position        integer NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT resource_eval_cases_suite_name_key UNIQUE (suite_id, eval_name)
);

CREATE INDEX IF NOT EXISTS idx_resource_eval_cases_suite
    ON public.resource_eval_cases (suite_id, position);

-- ------------------------------------------------------------
-- 3) 실행 회차
--    trigger = 'creation'     → 리소스 생성 시 시나리오를 확보한 최초 실행
--              'pull_request' → 병합 요청 검증(base vs head). 병합 판단의 근거.
--              'manual'       → 사용자가 임의로 돌린 실행
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.resource_eval_runs (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    suite_id        uuid NOT NULL REFERENCES public.resource_eval_suites (id) ON DELETE CASCADE,
    tenant_id       text NOT NULL DEFAULT public.tenant_id(),
    resource_type   text NOT NULL,
    resource_id     text NOT NULL,
    trigger         text NOT NULL DEFAULT 'pull_request',

    -- 검증 대상 병합 요청. trigger='pull_request' 일 때 필수.
    pr_id           uuid NULL REFERENCES public.resource_pull_requests (id) ON DELETE CASCADE,
    base_ref        text NULL,
    head_ref        text NULL,
    -- 각 버전 내용의 sha256 — 같은 head 를 다시 검증했는지 판별한다.
    base_digest     text NULL,
    head_digest     text NULL,

    status          text NOT NULL DEFAULT 'running',
    error           text NULL,

    -- 변경 후(head) 통과율과 변경 전(base) 통과율
    pass_rate       numeric(5, 4) NULL,
    base_pass_rate  numeric(5, 4) NULL,
    -- base 에서 통과하던 단계가 head 에서 깨진 개수 (이 값이 0보다 크면 병합 시 위험)
    broken_count    integer NOT NULL DEFAULT 0,
    -- base 에서 실패하던 단계가 head 에서 통과하게 된 개수
    fixed_count     integer NOT NULL DEFAULT 0,
    -- 시나리오별 단계 비교 결과({"<eval_name>": {"broken": [...], "fixed": [...]}} 등)
    summary         jsonb NOT NULL DEFAULT '{}'::jsonb,

    created_by      uuid NULL,
    started_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz NULL,

    CONSTRAINT resource_eval_runs_trigger_check
        CHECK (trigger IN ('creation', 'pull_request', 'manual')),
    CONSTRAINT resource_eval_runs_status_check
        CHECK (status IN ('running', 'succeeded', 'failed')),
    -- 병합 요청 검증인데 어느 PR 인지 없으면 병합 판단의 근거가 될 수 없다.
    CONSTRAINT resource_eval_runs_pr_required
        CHECK (trigger <> 'pull_request' OR pr_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_resource_eval_runs_pr
    ON public.resource_eval_runs (pr_id, started_at DESC);

CREATE INDEX IF NOT EXISTS idx_resource_eval_runs_suite
    ON public.resource_eval_runs (suite_id, started_at DESC);

-- ------------------------------------------------------------
-- 4) 회차 × 시나리오 × variant 결과
--    variant = 'base'          → 변경 전(병합하지 않았을 때의 동작)
--              'head'          → 변경 후(병합했을 때의 동작)
--              'with_skill'    → 생성 시 기준선: 스킬을 붙이고 실행
--              'without_skill' → 생성 시 대조군: 스킬 없이 실행
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.resource_eval_results (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id      uuid NOT NULL REFERENCES public.resource_eval_runs (id) ON DELETE CASCADE,
    case_id     uuid NULL REFERENCES public.resource_eval_cases (id) ON DELETE SET NULL,
    tenant_id   text NOT NULL DEFAULT public.tenant_id(),
    eval_name   text NOT NULL,
    variant     text NOT NULL,
    passed      integer NOT NULL DEFAULT 0,
    total       integer NOT NULL DEFAULT 0,
    pass_rate   numeric(5, 4) NULL,
    -- 단계별 채점: [{"text": "...", "passed": true, "evidence": "..."}, ...]
    assertions  jsonb NOT NULL DEFAULT '[]'::jsonb,
    outputs_dir text NULL,
    notes       text NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT resource_eval_results_variant_check
        CHECK (variant IN ('base', 'head', 'with_skill', 'without_skill')),
    CONSTRAINT resource_eval_results_run_case_variant_key
        UNIQUE (run_id, eval_name, variant)
);

CREATE INDEX IF NOT EXISTS idx_resource_eval_results_run
    ON public.resource_eval_results (run_id);

-- ------------------------------------------------------------
-- RLS: 모든 테이블 테넌트 격리
-- ------------------------------------------------------------
ALTER TABLE public.resource_eval_suites  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resource_eval_cases   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resource_eval_runs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resource_eval_results ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS resource_eval_suites_tenant_policy ON public.resource_eval_suites;
CREATE POLICY resource_eval_suites_tenant_policy ON public.resource_eval_suites
    FOR ALL TO authenticated
    USING (tenant_id = public.tenant_id())
    WITH CHECK (tenant_id = public.tenant_id());

DROP POLICY IF EXISTS resource_eval_cases_tenant_policy ON public.resource_eval_cases;
CREATE POLICY resource_eval_cases_tenant_policy ON public.resource_eval_cases
    FOR ALL TO authenticated
    USING (tenant_id = public.tenant_id())
    WITH CHECK (tenant_id = public.tenant_id());

DROP POLICY IF EXISTS resource_eval_runs_tenant_policy ON public.resource_eval_runs;
CREATE POLICY resource_eval_runs_tenant_policy ON public.resource_eval_runs
    FOR ALL TO authenticated
    USING (tenant_id = public.tenant_id())
    WITH CHECK (tenant_id = public.tenant_id());

DROP POLICY IF EXISTS resource_eval_results_tenant_policy ON public.resource_eval_results;
CREATE POLICY resource_eval_results_tenant_policy ON public.resource_eval_results
    FOR ALL TO authenticated
    USING (tenant_id = public.tenant_id())
    WITH CHECK (tenant_id = public.tenant_id());

COMMENT ON TABLE public.resource_eval_suites IS
    '리소스(스킬/BPMN/DMN)별 주요 시나리오 모음. 병합 요청 검증이 이 시나리오를 재사용한다.';
COMMENT ON TABLE public.resource_eval_cases IS
    '주요 시나리오 한 건(프롬프트 + 검증 단계 목록).';
COMMENT ON TABLE public.resource_eval_runs IS
    '검증 실행 회차. trigger=pull_request 는 병합 전 base/head 비교이며 broken_count>0 이면 기존 동작이 깨진다.';
COMMENT ON TABLE public.resource_eval_results IS
    '회차 × 시나리오 × variant(base/head) 별 단계 채점 결과.';
