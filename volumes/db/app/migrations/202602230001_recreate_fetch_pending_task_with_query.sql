-- =============================================================================
-- Recreate fetch_pending_task overloads with correct return shape
-- - Fixes 42804: structure of query does not match function result type
-- - Adds `query text` column before `task_type`
-- =============================================================================

-- Drop overloads first (4-arg depends on 3-arg)
DROP FUNCTION IF EXISTS public.fetch_pending_task(text, text, text, integer);
DROP FUNCTION IF EXISTS public.fetch_pending_task(text, text, integer);

-- 3-arg implementation
CREATE FUNCTION public.fetch_pending_task(
  p_agent_orch text,
  p_consumer text,
  p_limit integer
)
RETURNS TABLE(
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
  draft jsonb,
  project_id uuid,
  feedback jsonb,
  updated_at timestamp with time zone,
  username text,
  status todo_status,
  agent_mode agent_mode,
  agent_orch agent_orch,
  temp_feedback text,
  draft_status draft_status,
  query text,
  task_type draft_status
)
LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN QUERY
    WITH cte AS (
      SELECT
        t.*,
        t.draft_status AS task_type
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
         t.draft,
         t.project_id,
         t.feedback,
         t.updated_at,
         t.username,
         t.status,
         t.agent_mode,
         t.agent_orch,
         t.temp_feedback,
         t.draft_status,
         t.query,
         cte.task_type
    )
    SELECT * FROM upd;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fetch_pending_task(text, text, integer) TO anon, authenticated, service_role;

-- 4-arg compatibility wrapper (p_env currently ignored)
CREATE FUNCTION public.fetch_pending_task(
  p_agent_orch text,
  p_consumer text,
  p_env text,
  p_limit integer
)
RETURNS TABLE(
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
  draft jsonb,
  project_id uuid,
  feedback jsonb,
  updated_at timestamp with time zone,
  username text,
  status todo_status,
  agent_mode agent_mode,
  agent_orch agent_orch,
  temp_feedback text,
  draft_status draft_status,
  query text,
  task_type draft_status
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
    SELECT *
    FROM public.fetch_pending_task(p_agent_orch, p_consumer, p_limit);
END;
$$;

GRANT EXECUTE ON FUNCTION public.fetch_pending_task(text, text, text, integer) TO anon, authenticated, service_role;

