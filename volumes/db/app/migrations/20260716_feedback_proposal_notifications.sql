-- 피드백 기반 개선 제안과 그 병합 요청을 리소스 소유자에게 알린다.
-- 제안 생성은 외부 agent-feedback 서비스가 수행하므로 클라이언트가 아닌 DB 상태
-- 전이를 기준으로 처리해야 접속 여부와 관계없이 알림이 한 번만 생성된다.

CREATE OR REPLACE FUNCTION public.insert_feedback_resource_notification(
    p_tenant_id text,
    p_target jsonb,
    p_proc_def_id text,
    p_candidate_skill_names text[],
    p_event text,
    p_from_user_id text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_type text := p_target ->> 'type';
    v_resource_id text;
    v_resource_name text;
    v_owner_id text;
    v_url text;
    v_label text;
    v_event_label text;
BEGIN
    IF v_type = 'SKILL' THEN
        v_resource_name := NULLIF(p_target ->> 'skill_name', '');
        IF v_resource_name IS NULL AND COALESCE(array_length(p_candidate_skill_names, 1), 0) = 1 THEN
            v_resource_name := p_candidate_skill_names[1];
        END IF;
        IF v_resource_name IS NULL THEN RETURN; END IF;

        SELECT owner_id::text INTO v_owner_id
          FROM public.tenant_skills
         WHERE tenant_id = p_tenant_id AND skill_name = v_resource_name
         LIMIT 1;
        v_url := '/skills/' || v_resource_name;
        v_label := 'SKILL';
    ELSIF v_type IN ('DMN_RULE', 'PROCESS_DEFINITION', 'PROCESS') THEN
        v_resource_id := COALESCE(NULLIF(p_target ->> 'id', ''), NULLIF(p_target ->> 'resource_id', ''));
        IF v_resource_id IS NULL AND v_type IN ('PROCESS_DEFINITION', 'PROCESS') THEN
            v_resource_id := p_proc_def_id;
        END IF;
        IF v_resource_id IS NULL THEN RETURN; END IF;

        SELECT owner::text, COALESCE(NULLIF(name, ''), v_resource_id)
          INTO v_owner_id, v_resource_name
          FROM public.proc_def
         WHERE tenant_id = p_tenant_id AND id = v_resource_id
         LIMIT 1;

        IF v_type = 'DMN_RULE' THEN
            v_url := '/dmn/' || v_resource_id;
            v_label := 'DMN RULE';
        ELSE
            v_url := '/definitions/' || v_resource_id;
            v_label := 'PROCESS';
        END IF;
    ELSE
        RETURN;
    END IF;

    IF v_owner_id IS NULL THEN RETURN; END IF;

    v_resource_name := COALESCE(v_resource_name, v_resource_id);
    v_event_label := CASE p_event
        WHEN 'CREATED' THEN '개선 제안 생성'
        WHEN 'APPROVED' THEN '개선 제안 승인'
        WHEN 'MERGE_REQUESTED' THEN '병합 요청'
        ELSE NULL
    END;
    IF v_event_label IS NULL THEN RETURN; END IF;

    INSERT INTO public.notifications (
        id, user_id, type, title, description, url,
        is_checked, time_stamp, from_user_id, tenant_id
    ) VALUES (
        gen_random_uuid(), v_owner_id, 'merge_request',
        '[' || v_label || '] ' || v_event_label,
        v_resource_name || '에 대한 ' || v_event_label || '이(가) 있습니다.',
        v_url, false, now(), p_from_user_id, p_tenant_id
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_feedback_proposal_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_target jsonb;
    v_old_target jsonb;
    v_index integer;
BEGIN
    FOR v_target, v_index IN
        SELECT value, ordinality::integer - 1
          FROM jsonb_array_elements(COALESCE(NEW.targets, '[]'::jsonb)) WITH ORDINALITY
    LOOP
        IF NEW.status = 'PROPOSED' AND v_target ->> 'status' = 'PENDING' AND (
            TG_OP = 'INSERT'
            OR OLD.status IS DISTINCT FROM NEW.status
            OR NOT COALESCE(OLD.targets, '[]'::jsonb) @> jsonb_build_array(v_target)
        ) THEN
            PERFORM public.insert_feedback_resource_notification(
                NEW.tenant_id, v_target, NEW.proc_def_id,
                NEW.candidate_skill_names, 'CREATED', NULL
            );
        END IF;

        IF TG_OP = 'UPDATE' AND v_target ->> 'status' = 'APPROVED' THEN
            v_old_target := COALESCE(OLD.targets, '[]'::jsonb) -> v_index;
            IF v_old_target ->> 'status' IS DISTINCT FROM 'APPROVED' THEN
                PERFORM public.insert_feedback_resource_notification(
                    NEW.tenant_id, v_target, NEW.proc_def_id,
                    NEW.candidate_skill_names, 'APPROVED', v_target ->> 'decided_by'
                );
            END IF;
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS feedback_proposal_notification_trigger ON public.feedback_proposals;
CREATE TRIGGER feedback_proposal_notification_trigger
AFTER INSERT OR UPDATE OF status, targets ON public.feedback_proposals
FOR EACH ROW EXECUTE FUNCTION public.notify_feedback_proposal_change();

CREATE OR REPLACE FUNCTION public.notify_feedback_merge_request()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_target jsonb;
BEGIN
    v_target := CASE NEW.resource_type
        WHEN 'skill' THEN jsonb_build_object('type', 'SKILL', 'skill_name', NEW.resource_id)
        WHEN 'dmn' THEN jsonb_build_object('type', 'DMN_RULE', 'id', NEW.resource_id)
        WHEN 'bpmn' THEN jsonb_build_object('type', 'PROCESS_DEFINITION', 'id', NEW.resource_id)
        WHEN 'proc_def' THEN jsonb_build_object('type', 'PROCESS_DEFINITION', 'id', NEW.resource_id)
        ELSE '{}'::jsonb
    END;

    PERFORM public.insert_feedback_resource_notification(
        NEW.tenant_id, v_target, NEW.resource_id, NULL,
        'MERGE_REQUESTED',
        CASE
            WHEN jsonb_typeof(to_jsonb(NEW.requester_id)) = 'array' THEN to_jsonb(NEW.requester_id) ->> 0
            ELSE NEW.requester_id::text
        END
    );
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS feedback_merge_request_notification_trigger ON public.resource_pull_requests;
CREATE TRIGGER feedback_merge_request_notification_trigger
AFTER INSERT ON public.resource_pull_requests
FOR EACH ROW EXECUTE FUNCTION public.notify_feedback_merge_request();
