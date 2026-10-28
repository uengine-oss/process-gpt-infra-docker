-- =============================================================================
-- Hotfix: fetch_pending_task* 42804 (structure of query does not match function result type)
--
-- 증상
--   에이전트 워커가 작업을 하나도 가져가지 못하고 약 11초마다 아래 오류로 실패한다.
--     polling_pending_todos 최종 실패: {'code': '42804',
--       'details': 'Returned type text does not match expected type agent_mode in column 27.'}
--   → 프로세스 인스턴스의 에이전트 태스크가 영원히 실행되지 않고,
--     엔진 타임아웃 뒤 "응답이 지연되고 있습니다" 문구만 남긴 채 DONE 으로 넘어간다.
--
-- 원인
--   운영 DB 의 todolist.agent_mode / todolist.agent_orch 는 실제로 `text` 컬럼인데,
--   이 함수들의 RETURNS TABLE 선언은 27/29번째 컬럼을 enum(public.agent_mode / public.agent_orch)
--   으로 선언하고 있다. PL/pgSQL 의 RETURN QUERY 는 행이 0건이어도 실행 시점에
--   튜플 서술자를 검증하므로 폴링이 매번 실패한다.
--   (todolist.status / draft_status 는 운영에서 enum 이라 지금은 일치하지만,
--    환경별로 갈릴 수 있어 함께 text 로 고정한다.)
--
--   컬럼을 enum 으로 되돌리는 방식은 채택하지 않았다. 운영 데이터에
--   enum 에 없는 agent_orch 값('deepagents', 'deep-research-custom', 'default')이 존재해
--   변환 시 NULL 로 날아가고 해당 에이전트들이 통째로 죽는다.
--
-- 해결
--   enum 계열 출력 컬럼을 모두 text 로 선언하고 본문에서 ::text 로 명시 캐스팅한다.
--   컬럼이 enum 이든 text 이든 양쪽 모두에서 동작하므로 스키마 드리프트에 영향받지 않는다.
--   덤으로 기존 정의가 조용히 누락하던 컬럼(root_proc_inst_id, execution_scope, output_url,
--   query, version_tag, feedback_status, actual_start_date 등)까지 모두 반환한다.
--   task_type(변경 전 draft_status)은 openai-deep-research 서비스가 읽으므로 유지한다.
--     (/app/core/polling_manager.py:81 → row.get('task_type') == 'FB_REQUESTED')
--
-- 적용 대상 (2026-07-22 운영 점검 결과)
--   BROKEN : fetch_pending_task_dev, openai_deep_fetch_pending_task
--   예방적  : fetch_pending_task (동일 계열. ENV=prod 로 되돌릴 때 같은 벽에 부딪히지 않도록)
--   정상    : crewai_action_*, crewai_deep_*, deep_research_*, openai_deep_*_dev
-- =============================================================================

-- 이름이 같은 모든 오버로드를 제거한다(배포된 인자 순서를 가정하지 않기 위함).
DO $drop$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('fetch_pending_task', 'fetch_pending_task_dev', 'openai_deep_fetch_pending_task')
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', r.sig);
  END LOOP;
END
$drop$;

-- 1) 공용 폴링 (운영 경로). p_env 는 하위호환을 위해 받되 분기에 쓰지 않는다.
CREATE FUNCTION public.fetch_pending_task(
  p_agent_orch text,
  p_consumer   text,
  p_env        text,
  p_limit      integer
)
RETURNS TABLE (
  id uuid,
  user_id text,
  proc_inst_id text,
  proc_def_id text,
  activity_id text,
  activity_name text,
  start_date timestamp without time zone,
  end_date timestamp without time zone,
  description text,
  tool text,
  due_date timestamp without time zone,
  tenant_id text,
  reference_ids text[],
  adhoc boolean,
  assignees jsonb,
  duration integer,
  output jsonb,
  retry integer,
  consumer text,
  log text,
  project_id uuid,
  draft jsonb,
  feedback jsonb,
  updated_at timestamp with time zone,
  username text,
  status text,
  agent_mode text,
  temp_feedback text,
  agent_orch text,
  draft_status text,
  root_proc_inst_id text,
  execution_scope text,
  output_url text,
  rework_count integer,
  query text,
  version_tag text,
  version text,
  feedback_status text,
  executor_dept_id text,
  executor_dept_name text,
  actual_start_date timestamp with time zone,
  feedback_collected_count integer,
  task_type text
)
AS $fn$
BEGIN
  RETURN QUERY
    WITH cte AS (
      SELECT t.*, t.draft_status AS task_type
      FROM todolist AS t
      WHERE t.status = 'IN_PROGRESS'
        AND (p_agent_orch IS NULL OR p_agent_orch = '' OR t.agent_orch::text = p_agent_orch)
        AND (
          (t.agent_mode IN ('DRAFT','COMPLETE') AND t.draft IS NULL AND t.draft_status IS NULL)
          OR t.draft_status = 'FB_REQUESTED'
        )
      ORDER BY t.start_date
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED
    ),
    upd AS (
      UPDATE todolist AS t
         SET draft_status = 'STARTED',
             consumer     = p_consumer
        FROM cte
       WHERE t.id = cte.id
       RETURNING
         t.id,
         t.user_id,
         t.proc_inst_id,
         t.proc_def_id,
         t.activity_id,
         t.activity_name,
         t.start_date,
         t.end_date,
         t.description,
         t.tool,
         t.due_date,
         t.tenant_id,
         t.reference_ids,
         t.adhoc,
         t.assignees,
         t.duration,
         t.output,
         t.retry,
         t.consumer,
         t.log,
         t.project_id,
         t.draft,
         t.feedback,
         t.updated_at,
         t.username,
         t.status::text,
         t.agent_mode::text,
         t.temp_feedback,
         t.agent_orch::text,
         t.draft_status::text,
         t.root_proc_inst_id,
         t.execution_scope,
         t.output_url,
         t.rework_count,
         t.query,
         t.version_tag,
         t.version,
         t.feedback_status,
         t.executor_dept_id,
         t.executor_dept_name,
         t.actual_start_date,
         t.feedback_collected_count,
         cte.task_type::text
    )
    SELECT * FROM upd;
END;
$fn$ LANGUAGE plpgsql VOLATILE;

GRANT EXECUTE ON FUNCTION public.fetch_pending_task(text, text, text, integer) TO anon, authenticated, service_role;

-- 구버전 SDK 가 호출하는 3인자 오버로드
CREATE FUNCTION public.fetch_pending_task(
  p_agent_orch text,
  p_consumer   text,
  p_limit      integer
)
RETURNS TABLE (
  id uuid,
  user_id text,
  proc_inst_id text,
  proc_def_id text,
  activity_id text,
  activity_name text,
  start_date timestamp without time zone,
  end_date timestamp without time zone,
  description text,
  tool text,
  due_date timestamp without time zone,
  tenant_id text,
  reference_ids text[],
  adhoc boolean,
  assignees jsonb,
  duration integer,
  output jsonb,
  retry integer,
  consumer text,
  log text,
  project_id uuid,
  draft jsonb,
  feedback jsonb,
  updated_at timestamp with time zone,
  username text,
  status text,
  agent_mode text,
  temp_feedback text,
  agent_orch text,
  draft_status text,
  root_proc_inst_id text,
  execution_scope text,
  output_url text,
  rework_count integer,
  query text,
  version_tag text,
  version text,
  feedback_status text,
  executor_dept_id text,
  executor_dept_name text,
  actual_start_date timestamp with time zone,
  feedback_collected_count integer,
  task_type text
)
AS $fn$
BEGIN
  RETURN QUERY SELECT * FROM public.fetch_pending_task(p_agent_orch, p_consumer, 'prod', p_limit);
END;
$fn$ LANGUAGE plpgsql VOLATILE;

GRANT EXECUTE ON FUNCTION public.fetch_pending_task(text, text, integer) TO anon, authenticated, service_role;

-- 2) dev 폴링 (ENV=dev 일 때 SDK 가 호출. 테넌트로 한정)
CREATE FUNCTION public.fetch_pending_task_dev(
  p_agent_orch text,
  p_consumer   text,
  p_limit      integer,
  p_tenant_id  text
)
RETURNS TABLE (
  id uuid,
  user_id text,
  proc_inst_id text,
  proc_def_id text,
  activity_id text,
  activity_name text,
  start_date timestamp without time zone,
  end_date timestamp without time zone,
  description text,
  tool text,
  due_date timestamp without time zone,
  tenant_id text,
  reference_ids text[],
  adhoc boolean,
  assignees jsonb,
  duration integer,
  output jsonb,
  retry integer,
  consumer text,
  log text,
  project_id uuid,
  draft jsonb,
  feedback jsonb,
  updated_at timestamp with time zone,
  username text,
  status text,
  agent_mode text,
  temp_feedback text,
  agent_orch text,
  draft_status text,
  root_proc_inst_id text,
  execution_scope text,
  output_url text,
  rework_count integer,
  query text,
  version_tag text,
  version text,
  feedback_status text,
  executor_dept_id text,
  executor_dept_name text,
  actual_start_date timestamp with time zone,
  feedback_collected_count integer,
  task_type text
)
AS $fn$
BEGIN
  RETURN QUERY
    WITH cte AS (
      SELECT t.*, t.draft_status AS task_type
      FROM todolist AS t
      WHERE t.status = 'IN_PROGRESS'
        AND (p_agent_orch IS NULL OR p_agent_orch = '' OR t.agent_orch::text = p_agent_orch)
        AND t.tenant_id = p_tenant_id
        AND (
          (t.agent_mode IN ('DRAFT','COMPLETE') AND t.draft IS NULL AND t.draft_status IS NULL)
          OR t.draft_status = 'FB_REQUESTED'
        )
      ORDER BY t.start_date
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED
    ),
    upd AS (
      UPDATE todolist AS t
         SET draft_status = 'STARTED',
             consumer     = p_consumer
        FROM cte
       WHERE t.id = cte.id
       RETURNING
         t.id,
         t.user_id,
         t.proc_inst_id,
         t.proc_def_id,
         t.activity_id,
         t.activity_name,
         t.start_date,
         t.end_date,
         t.description,
         t.tool,
         t.due_date,
         t.tenant_id,
         t.reference_ids,
         t.adhoc,
         t.assignees,
         t.duration,
         t.output,
         t.retry,
         t.consumer,
         t.log,
         t.project_id,
         t.draft,
         t.feedback,
         t.updated_at,
         t.username,
         t.status::text,
         t.agent_mode::text,
         t.temp_feedback,
         t.agent_orch::text,
         t.draft_status::text,
         t.root_proc_inst_id,
         t.execution_scope,
         t.output_url,
         t.rework_count,
         t.query,
         t.version_tag,
         t.version,
         t.feedback_status,
         t.executor_dept_id,
         t.executor_dept_name,
         t.actual_start_date,
         t.feedback_collected_count,
         cte.task_type::text
    )
    SELECT * FROM upd;
END;
$fn$ LANGUAGE plpgsql VOLATILE;

GRANT EXECUTE ON FUNCTION public.fetch_pending_task_dev(text, text, integer, text) TO anon, authenticated, service_role;

-- 3) openai-deep-research 전용 폴링
CREATE FUNCTION public.openai_deep_fetch_pending_task(
  p_limit    integer,
  p_consumer text
)
RETURNS TABLE (
  id uuid,
  user_id text,
  proc_inst_id text,
  proc_def_id text,
  activity_id text,
  activity_name text,
  start_date timestamp without time zone,
  end_date timestamp without time zone,
  description text,
  tool text,
  due_date timestamp without time zone,
  tenant_id text,
  reference_ids text[],
  adhoc boolean,
  assignees jsonb,
  duration integer,
  output jsonb,
  retry integer,
  consumer text,
  log text,
  project_id uuid,
  draft jsonb,
  feedback jsonb,
  updated_at timestamp with time zone,
  username text,
  status text,
  agent_mode text,
  temp_feedback text,
  agent_orch text,
  draft_status text,
  root_proc_inst_id text,
  execution_scope text,
  output_url text,
  rework_count integer,
  query text,
  version_tag text,
  version text,
  feedback_status text,
  executor_dept_id text,
  executor_dept_name text,
  actual_start_date timestamp with time zone,
  feedback_collected_count integer,
  task_type text
)
AS $fn$
BEGIN
  RETURN QUERY
    WITH cte AS (
      SELECT t.*, t.draft_status AS task_type
      FROM todolist AS t
      WHERE t.status = 'IN_PROGRESS'
        AND t.agent_orch::text = 'openai-deep-research'
        AND (
          (t.agent_mode IN ('DRAFT','COMPLETE') AND t.draft IS NULL AND t.draft_status IS NULL)
          OR t.draft_status = 'FB_REQUESTED'
        )
      ORDER BY t.start_date
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED
    ),
    upd AS (
      UPDATE todolist AS t
         SET draft_status = 'STARTED',
             consumer     = p_consumer
        FROM cte
       WHERE t.id = cte.id
       RETURNING
         t.id,
         t.user_id,
         t.proc_inst_id,
         t.proc_def_id,
         t.activity_id,
         t.activity_name,
         t.start_date,
         t.end_date,
         t.description,
         t.tool,
         t.due_date,
         t.tenant_id,
         t.reference_ids,
         t.adhoc,
         t.assignees,
         t.duration,
         t.output,
         t.retry,
         t.consumer,
         t.log,
         t.project_id,
         t.draft,
         t.feedback,
         t.updated_at,
         t.username,
         t.status::text,
         t.agent_mode::text,
         t.temp_feedback,
         t.agent_orch::text,
         t.draft_status::text,
         t.root_proc_inst_id,
         t.execution_scope,
         t.output_url,
         t.rework_count,
         t.query,
         t.version_tag,
         t.version,
         t.feedback_status,
         t.executor_dept_id,
         t.executor_dept_name,
         t.actual_start_date,
         t.feedback_collected_count,
         cte.task_type::text
    )
    SELECT * FROM upd;
END;
$fn$ LANGUAGE plpgsql VOLATILE;

GRANT EXECUTE ON FUNCTION public.openai_deep_fetch_pending_task(integer, text) TO anon, authenticated, service_role;
