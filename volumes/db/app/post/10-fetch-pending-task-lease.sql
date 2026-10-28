-- 프론트 마이그레이션 202602230001 이 만든 옛 형태 — (p_agent_orch, p_consumer, p_env, p_limit) 이름 호출이
-- 아래 임대 버전과 구분되지 않아 PostgREST 가 PGRST203(Could not choose the best candidate function)으로 거절한다.
DROP FUNCTION IF EXISTS public.fetch_pending_task(text, text, text, integer);
DROP FUNCTION IF EXISTS public.fetch_pending_task(text, text, integer);
DROP FUNCTION IF EXISTS public.fetch_pending_task(text, text, integer, text);
DROP FUNCTION IF EXISTS public.fetch_pending_task(text, text, integer, text, integer);
DROP FUNCTION IF EXISTS public.fetch_pending_task(text, text, integer, text, integer, integer);

CREATE OR REPLACE FUNCTION public.fetch_pending_task(
  p_agent_orch     text,
  p_consumer       text,
  p_limit          integer,
  p_env            text,
  -- 이 두 인자는 기본값이 있다. 구버전 워커의 4-인자 호출이 그대로 동작해야 한다.
  p_lease_seconds  integer DEFAULT NULL,
  p_max_claims     integer DEFAULT 3
)
RETURNS SETOF todolist
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  v_max_claims integer := GREATEST(coalesce(p_max_claims, 3), 1);
BEGIN
  -- 1) 상한에 닿은 만료 점유를 FAILED 로 종결한다.
  --    폴링마다 돌지만 조건이 idx_todolist_lease_reclaim 그대로라 비용은 없다.
  UPDATE todolist AS t
     SET draft_status = 'FAILED',
         lease_until  = NULL
   WHERE t.status = 'IN_PROGRESS'
     AND t.draft_status = 'STARTED'
     AND t.lease_until IS NOT NULL
     AND t.lease_until < now()
     AND coalesce(t.claim_count, 0) >= v_max_claims
     AND (p_agent_orch IS NULL OR p_agent_orch = '' OR t.agent_orch::text = p_agent_orch);

  -- 2) 집을 수 있는 행 하나를 원자적으로 점유한다.
  RETURN QUERY
    WITH cte AS (
      SELECT t.id
      FROM todolist AS t
      WHERE t.status = 'IN_PROGRESS'
        -- agent_orch 필터(옵션)
        AND (p_agent_orch IS NULL OR p_agent_orch = '' OR t.agent_orch::text = p_agent_orch)
        AND (
          -- 신규 작업
          (t.agent_mode IN ('DRAFT','COMPLETE') AND t.draft IS NULL AND t.draft_status IS NULL)
          -- 사용자 피드백으로 되돌아온 작업
          OR t.draft_status = 'FB_REQUESTED'
          -- 점유가 만료된 작업(= 집은 워커가 더 이상 연장하지 못한다)
          --
          -- draft_status='STARTED' 만 본다. HUMAN_ASKED 처럼 사람 답변을 기다리는
          -- 정상 대기는 여기에 걸리지 않는다. 기다림은 장애가 아니고, 회수해도
          -- 다시 같은 질문 앞에서 멈출 뿐이다.
          OR (
            t.draft_status = 'STARTED'
            AND t.lease_until IS NOT NULL
            AND t.lease_until < now()
            AND coalesce(t.claim_count, 0) < v_max_claims
          )
        )
      ORDER BY t.start_date
      LIMIT p_limit
      FOR UPDATE SKIP LOCKED
    ),
    upd AS (
      UPDATE todolist AS t
         SET draft_status = 'STARTED',
             consumer     = p_consumer,
             lease_until  = CASE
                              WHEN p_lease_seconds IS NULL OR p_lease_seconds <= 0 THEN NULL
                              ELSE now() + make_interval(secs => p_lease_seconds)
                            END,
             -- 회수일 때만 누적한다. 피드백으로 되돌아온 정상 재집행
             -- (FB_REQUESTED)이 상한을 먹으면, 피드백을 몇 번 주고받은 작업이
             -- 멀쩡한데도 FAILED 로 끝난다.
             claim_count  = CASE
                              WHEN t.draft_status = 'STARTED' THEN coalesce(t.claim_count, 0) + 1
                              ELSE 1
                            END
        FROM cte
       WHERE t.id = cte.id
       RETURNING t.*
    )
    SELECT * FROM upd;
END;
$$;


-- lease 연장(heartbeat). 수행 중인 워커가 주기적으로 호출한다.
--
-- 단순 UPDATE 가 아니라 결과에 이유를 담아 돌려준다. 연장이 실패하는 경우가
-- 두 가지이고 워커가 할 일이 서로 다르기 때문이다.
--   not_owner   : 다른 워커가 이미 회수했다 → 지금 하는 일을 버려야 한다.
--                 그러지 않으면 같은 작업이 둘에서 동시에 수행된다.
--   not_started : COMPLETED/HUMAN_ASKED/CANCELLED 등으로 이미 넘어갔다 →
--                 연장할 점유가 없을 뿐이고, 버릴 일은 아니다.
CREATE OR REPLACE FUNCTION public.renew_task_lease(
  p_todo_id       uuid,
  p_consumer      text,
  p_lease_seconds integer
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  v_status   text;
  v_consumer text;
  v_until    timestamptz;
BEGIN
  IF p_todo_id IS NULL OR coalesce(p_consumer, '') = '' OR coalesce(p_lease_seconds, 0) <= 0 THEN
    RETURN jsonb_build_object('renewed', false, 'reason', 'bad_request');
  END IF;

  SELECT t.draft_status::text, t.consumer
    INTO v_status, v_consumer
    FROM todolist AS t
   WHERE t.id = p_todo_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('renewed', false, 'reason', 'missing');
  END IF;

  IF v_status IS DISTINCT FROM 'STARTED' THEN
    RETURN jsonb_build_object('renewed', false, 'reason', 'not_started',
                              'draft_status', v_status);
  END IF;

  IF v_consumer IS DISTINCT FROM p_consumer THEN
    RETURN jsonb_build_object('renewed', false, 'reason', 'not_owner',
                              'consumer', v_consumer);
  END IF;

  UPDATE todolist
     SET lease_until = now() + make_interval(secs => p_lease_seconds)
   WHERE id = p_todo_id
   RETURNING lease_until INTO v_until;

  RETURN jsonb_build_object('renewed', true, 'reason', 'ok', 'lease_until', v_until);
END;
$$;


-- 점유 해제. 워커가 정상적으로 작업을 떠날 때(= 더 이상 연장하지 않을 때) 쓴다.
-- 남은 lease 를 기다리지 않고 바로 다음 워커가 집을 수 있게 한다.
CREATE OR REPLACE FUNCTION public.release_task_lease(
  p_todo_id  uuid,
  p_consumer text
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
  v_rows integer;
BEGIN
  IF p_todo_id IS NULL OR coalesce(p_consumer, '') = '' THEN
    RETURN false;
  END IF;

  UPDATE todolist AS t
     SET lease_until = NULL
   WHERE t.id = p_todo_id
     AND t.consumer = p_consumer;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END;
$$;


-- 익명(anon) 역할에 실행 권한 부여
GRANT EXECUTE ON FUNCTION public.fetch_pending_task(text, text, integer, text, integer, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.renew_task_lease(uuid, text, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.release_task_lease(uuid, text) TO anon;


