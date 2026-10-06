-- 로컬 Supabase(process-gpt-vue3)에 lease 변경분을 적용한다.
-- init.sql / migration.sql 에서 문장을 그대로 추출했다. 손으로 고치지 않는다.
-- supabase_admin 으로 적용한다(기존 함수 소유자). 한 트랜잭션이다.
--
-- openai_deep_fetch_pending_task / deep_research_fetch_pending_task 는 이 DB 에
-- 존재하지 않으므로 넣지 않는다. 없는 함수를 새로 만들면 검증 대상이 아닌 것이 는다.
BEGIN;
-- ===============================================
-- todolist: 작업 점유에 만료 시한(lease)을 둔다
-- ===============================================
-- 지금까지 점유는 `consumer` 에 점유자 이름을 적는 것뿐이었고 만료가 없었다.
-- 워커가 kill -9 로 죽으면 그 행은 draft_status='STARTED' 로 영구히 남아 아무도
-- 다시 집지 않는다(고아 STARTED). lease_until 로 점유에 시한을 주고, 살아 있는
-- 워커가 주기적으로 연장한다. 연장이 끊기면 fetch_pending_task 가 그 행을 다시
-- 집어간다.
--
-- 운영 중 적용 가능하다: 두 컬럼 모두 nullable 이거나 상수 기본값이라
-- 테이블 재작성 없이 메타데이터만 바뀐다(PG 11+).
--
-- lease_until 이 NULL 인 의미: "만료 개념 없이 점유된 행".
--   - 마이그레이션 이전에 이미 STARTED 로 남아 있던 기존 행
--   - lease 를 모르는 구버전 SDK 워커가 집은 행(p_lease_seconds 를 넘기지 않음)
-- 이 행들은 회수 대상이 아니다. 연장할 주체가 없는 점유를 회수하면 그 워커가
-- 아직 살아서 일하는 중일 때 같은 작업이 두 번 수행된다. NULL 은 예전 동작
-- 그대로 둔다 — 유실은 늘지 않고, 중복 수행은 생기지 않는다.
ALTER TABLE public.todolist ADD COLUMN IF NOT EXISTS lease_until timestamptz;

-- 점유된 횟수(최초 클레임 + 회수 클레임). 무한 재클레임을 막는 상한의 근거다.
-- 기존 `retry` 컬럼을 쓰지 않는다: 그 컬럼은 다른 서비스가 쓸 수 있고 의미도
-- 다르다(작업 자체의 재시도). 이 값은 "점유가 몇 번 일어났는가" 다.
ALTER TABLE public.todolist ADD COLUMN IF NOT EXISTS claim_count integer NOT NULL DEFAULT 0;

-- 회수 후보를 찾는 조건 그대로의 인덱스. 모든 워커가 이 조건으로 폴링한다.
CREATE INDEX IF NOT EXISTS idx_todolist_lease_reclaim
    ON public.todolist (status, draft_status, lease_until);

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

CREATE OR REPLACE FUNCTION public.save_task_result(
  p_todo_id uuid,
  p_payload jsonb,
  p_final   boolean
)
RETURNS void AS $$
DECLARE
  v_mode text;
BEGIN
  SELECT agent_mode
    INTO v_mode
    FROM todolist
   WHERE id = p_todo_id;

  IF p_final THEN
    IF v_mode = 'COMPLETE' THEN
      UPDATE todolist
         SET output       = p_payload,
             status       = 'SUBMITTED',
             draft_status = 'COMPLETED',
             consumer     = NULL,
             -- 점유도 같이 끝낸다. 남겨 두면 만료를 기다리는 동안 lease 가
             -- 끝난 작업을 가리킨다.
             lease_until  = NULL
       WHERE id = p_todo_id;
    ELSE
      UPDATE todolist
         SET draft        = p_payload,
             draft_status = 'COMPLETED',
             consumer     = NULL,
             lease_until  = NULL
       WHERE id = p_todo_id;
    END IF;
  ELSE
    UPDATE todolist
       SET draft = p_payload
     WHERE id = p_todo_id;
  END IF;
END;
$$ LANGUAGE plpgsql VOLATILE;

GRANT EXECUTE ON FUNCTION public.fetch_pending_task(text, text, integer, text, integer, integer) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.renew_task_lease(uuid, text, integer) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.release_task_lease(uuid, text) TO anon, authenticated, service_role;

COMMIT;
