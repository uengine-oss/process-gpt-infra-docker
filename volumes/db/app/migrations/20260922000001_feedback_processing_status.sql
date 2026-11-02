-- ============================================================
-- 피드백 처리 과정을 피드백 작성자에게 보여주기 위한 기록
--
-- 피드백은 배치로 모여 분류되고, 승인된 target 은 병합 요청이 된다. 지금까지는
-- 그 결과가 제안 쪽에 남지 않아 "내 피드백이 무엇이 되었는지" 를 알 수 없었다.
--   - 폐기된 배치는 왜 폐기됐는지 남지 않았다                → discard_reason
--   - 분류됐지만 개선할 기존 리소스가 없어 빠진 target 은 사라졌다 → dropped_targets
--   - 승인된 target 이 어떤 병합 요청이 됐는지 남지 않았다       → targets[i].apply_*
-- ============================================================

ALTER TABLE public.feedback_proposals
    ADD COLUMN IF NOT EXISTS discard_reason text NULL,
    ADD COLUMN IF NOT EXISTS dropped_targets jsonb NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.feedback_proposals.discard_reason IS
    '배치가 DISCARDED 된 사유(사용자에게 그대로 보여주는 문장). 예전 배치는 NULL.';
COMMENT ON COLUMN public.feedback_proposals.dropped_targets IS
    '분류는 됐지만 개선할 기존 리소스를 찾지 못해 제안에서 빠진 target 들. 항목마다 drop_reason 을 가진다.';

-- target 하나에만 필드를 덧붙인다(적용 상태·결과 기록용).
-- 같은 배치의 두 target 이 동시에 적용 결과를 쓰면 읽고-고쳐-쓰기는 서로를 덮으므로
-- 행 잠금 안에서 그 위치의 원소만 고친다. status 는 이 함수로 바꾸지 않는다(결정은
-- decide_feedback_proposal_target* 의 몫이다).
CREATE OR REPLACE FUNCTION public.patch_feedback_proposal_target(
    p_batch_id uuid,
    p_target_index integer,
    p_patch jsonb
) RETURNS public.feedback_proposals
LANGUAGE plpgsql
AS $$
DECLARE
    v_row public.feedback_proposals;
    v_elem jsonb;
BEGIN
    SELECT * INTO v_row FROM public.feedback_proposals WHERE id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    IF p_target_index < 0 OR p_target_index >= jsonb_array_length(v_row.targets) THEN
        RETURN NULL;
    END IF;

    v_elem := (v_row.targets -> p_target_index) || (p_patch - 'status');

    UPDATE public.feedback_proposals
       SET targets = jsonb_set(targets, ARRAY[p_target_index::text], v_elem)
     WHERE id = p_batch_id
    RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;

-- 누른 target 을 그대로 결정한다.
-- decide_feedback_proposal_target 은 같은 type 의 첫 PENDING 을 결정해서, 한 배치에
-- 같은 type 의 target 이 여럿이면 사용자가 누른 것과 다른 target 이 결정될 수 있었다.
CREATE OR REPLACE FUNCTION public.decide_feedback_proposal_target_at(
    p_batch_id uuid,
    p_target_index integer,
    p_target_type text,
    p_status text,
    p_decided_by uuid,
    p_decided_by_name text,
    p_decided_by_email text,
    p_decision_note text
) RETURNS public.feedback_proposals
LANGUAGE plpgsql
AS $$
DECLARE
    v_row public.feedback_proposals;
    v_targets jsonb;
    v_elem jsonb;
    v_all_decided boolean := true;
    i int;
BEGIN
    SELECT * INTO v_row
      FROM public.feedback_proposals
     WHERE id = p_batch_id AND status = 'PROPOSED'
     FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    v_targets := v_row.targets;
    IF p_target_index < 0 OR p_target_index >= jsonb_array_length(v_targets) THEN
        RETURN NULL;
    END IF;

    v_elem := v_targets -> p_target_index;
    IF (v_elem ->> 'type') IS DISTINCT FROM p_target_type OR (v_elem ->> 'status') IS DISTINCT FROM 'PENDING' THEN
        RETURN NULL;
    END IF;

    v_elem := v_elem || jsonb_build_object(
        'status', p_status,
        'decided_by', p_decided_by,
        'decided_by_name', p_decided_by_name,
        'decided_by_email', p_decided_by_email,
        'decision_note', p_decision_note,
        'decided_at', to_jsonb(now())
    );
    v_targets := jsonb_set(v_targets, ARRAY[p_target_index::text], v_elem);

    FOR i IN 0 .. jsonb_array_length(v_targets) - 1 LOOP
        IF (v_targets -> i ->> 'status') = 'PENDING' THEN
            v_all_decided := false;
        END IF;
    END LOOP;

    UPDATE public.feedback_proposals
       SET targets = v_targets,
           status = CASE WHEN v_all_decided THEN 'RESOLVED' ELSE status END
     WHERE id = p_batch_id
    RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;
