-- ============================================================
-- 피드백을 워크아이템 단위로 처리한다
--
-- 지금까지는 피드백 한 건 한 건이 처리 단위였다.
--   - 진행 중인 워크아이템의 피드백도 수집돼, 완료되기 전의 재작업 지시가 개선 근거로 섞였다
--   - 한 워크아이템에 피드백을 다섯 번 남기면 그것만으로 배치가 차서 분류됐다
--   - 분류가 도는 동안 들어온 피드백이 같은 배치에 붙어, 분류되지 않은 채 "처리됨"이 됐다
--
-- 바꾼 규칙
--   - 완료(DONE)된 워크아이템의 피드백만 수집한다
--   - 한 워크아이템에서 새로 생긴 피드백은 한 번에 같은 배치에 적재한다(워크아이템 한 단위)
--   - 배치는 분류를 시작할 때 CLASSIFYING 으로 닫는다. 그 뒤 같은 워크아이템에 남긴 피드백은
--     다음 COLLECTING 배치로 가서 다음 회차에 처리된다
-- ============================================================

ALTER TABLE public.feedback_proposals DROP CONSTRAINT IF EXISTS feedback_proposals_status_check;
ALTER TABLE public.feedback_proposals ADD CONSTRAINT feedback_proposals_status_check CHECK (
    status = ANY (ARRAY['COLLECTING', 'CLASSIFYING', 'PROPOSED', 'APPROVED', 'REJECTED', 'DISCARDED', 'RESOLVED'])
);

CREATE OR REPLACE FUNCTION public.agent_feedback_task(p_limit integer)
 RETURNS SETOF todolist
 LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN QUERY
    WITH cte AS (
      SELECT *
        FROM todolist
       WHERE feedback IS NOT NULL
         AND feedback != '[]'::jsonb
         AND feedback != '{}'::jsonb
         AND proc_def_id IS NOT NULL
         AND proc_def_id != ''
         -- 완료된 워크아이템만. 진행 중에 남긴 피드백은 완료된 뒤 그 워크아이템의 결과와 함께 수집된다.
         AND status = 'DONE'
         AND (
           (feedback_status IS NULL OR feedback_status = 'REQUESTED')
           OR (
             jsonb_typeof(feedback) = 'array'
             AND jsonb_array_length(feedback) > COALESCE(feedback_collected_count, 0)
           )
         )
       ORDER BY updated_at DESC
       LIMIT p_limit
       FOR UPDATE SKIP LOCKED
    ), upd AS (
      UPDATE todolist
         SET feedback_status = 'STARTED'
        FROM cte
       WHERE todolist.id = cte.id
       RETURNING todolist.*
    )
    SELECT * FROM upd;
END;
$function$;

-- 워크아이템 하나에서 새로 생긴 피드백 전부를 한 번에 적재한다.
-- 한 건씩 적재하면 그 사이에 배치가 분류로 넘어가 한 워크아이템의 피드백이 두 회차로 갈라질 수 있다.
-- p_items: [{todo_id, content, time, user_id}, ...]
CREATE OR REPLACE FUNCTION public.append_workitem_feedback_to_batch(
    p_tenant_id text,
    p_proc_def_id text,
    p_activity_id text,
    p_items jsonb
) RETURNS public.feedback_proposals
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch public.feedback_proposals;
BEGIN
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RETURN NULL;
    END IF;

    INSERT INTO public.feedback_proposals (
        tenant_id, proc_def_id, activity_id, status, collected_items, first_collected_at
    ) VALUES (
        p_tenant_id, p_proc_def_id, p_activity_id, 'COLLECTING', p_items, now()
    )
    ON CONFLICT (tenant_id, proc_def_id, activity_id) WHERE status = 'COLLECTING'
    DO UPDATE SET
        collected_items = public.feedback_proposals.collected_items || p_items
    RETURNING * INTO v_batch;

    RETURN v_batch;
END;
$$;
