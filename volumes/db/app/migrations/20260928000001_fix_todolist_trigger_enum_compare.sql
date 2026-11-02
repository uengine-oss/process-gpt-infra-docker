-- 업무 알림 트리거가 todolist 쓰기를 통째로 막던 것을 고친다.
--
-- 무엇이 잘못됐나
--   20260907000001 이 넣은 handle_todolist_change() 는 이렇게 썼다.
--
--       v_by_agent := coalesce(NEW.agent_mode, '') <> '';
--
--   agent_mode 는 text 가 아니라 enum 이다(20260101_base_schema: DRAFT · COMPLETE).
--   그래서 '' 를 agent_mode 로 바꾸려다 실패한다.
--
--       ERROR: invalid input value for enum agent_mode: ""
--
--   트리거는 INSERT·UPDATE 양쪽에 걸려 있으므로, 이 마이그레이션이 적용된 곳에서는
--   **todolist 에 한 줄도 쓰지 못한다.** 엔진이 다음 업무를 만들지 못하니 프로세스가
--   그 자리에서 멈춘다. 알림을 고치려던 변경이 업무 자체를 막은 셈이다.
--
-- 어떻게 고치나
--   원래 뜻은 "에이전트가 대신 하는 단계인가" 이고, enum 에서 '비어 있음' 은 NULL
--   하나뿐이다. 그러니 NULL 인지만 보면 된다. 형변환으로 우회하지 않는 이유는,
--   ::text 로 바꿔 비교하면 값이 하나 늘 때마다 같은 실수를 되풀이할 자리가 남기
--   때문이다.
--
--   나머지 본문은 20260907000001 의 것을 그대로 둔다 — 고칠 곳은 그 한 줄이다.

create or replace function public.handle_todolist_change()
returns trigger
language plpgsql
as $function$
DECLARE
    v_proc_inst_name text;
    v_proc_tenant_id text;
    v_by_agent boolean;
    should_notify boolean := false;
BEGIN
    -- 에이전트가 대신 하는 단계인가. 사람이 할 일과 알릴 시점이 다르다.
    -- agent_mode 는 enum 이라 '' 와 견줄 수 없다. 비어 있음은 NULL 뿐이다.
    v_by_agent := NEW.agent_mode IS NOT NULL;

    -- 사람이 하는 일: 내 차례가 되는 순간 알린다.
    IF NOT v_by_agent THEN
        IF (TG_OP = 'INSERT' AND NEW.status = 'IN_PROGRESS') THEN
            should_notify := true;
        END IF;

        IF (TG_OP = 'UPDATE' AND NEW.status = 'IN_PROGRESS' AND (OLD.status IS NULL OR OLD.status != 'IN_PROGRESS')) THEN
            should_notify := true;
        END IF;
    END IF;

    -- 에이전트가 하는 일: 시작했다고 알릴 이유가 없다. 사람이 볼 것이 생겼을
    -- 때 — 초안이 나왔거나, 물어볼 것이 생겼거나, 실패했을 때 — 알린다.
    IF v_by_agent AND TG_OP = 'UPDATE'
       AND NEW.draft_status IS DISTINCT FROM OLD.draft_status
       AND NEW.draft_status::text IN ('COMPLETED', 'FB_REQUESTED', 'HUMAN_ASKED', 'FAILED') THEN
        should_notify := true;
    END IF;

    -- 담당자가 없으면 알릴 곳이 없다.
    IF NEW.user_id IS NULL OR NEW.user_id = '' THEN
        should_notify := false;
    END IF;

    IF should_notify THEN
        SELECT proc_inst_name, tenant_id INTO v_proc_inst_name, v_proc_tenant_id
        FROM bpm_proc_inst
        WHERE proc_inst_id = NEW.proc_inst_id;

        INSERT INTO notifications (id, user_id, title, type, description, is_checked, time_stamp, tenant_id, url)
        VALUES (
            gen_random_uuid(),
            NEW.user_id,
            NEW.activity_name,
            CASE
                WHEN NEW.proc_inst_id IS NOT NULL AND NEW.proc_inst_id <> '' THEN 'workitem_bpm'
                ELSE 'workitem'
            END,
            COALESCE(v_proc_inst_name, NEW.activity_name),
            false,
            now(),
            COALESCE(NEW.tenant_id, v_proc_tenant_id),
            '/todolist/' || NEW.id
        );
    END IF;
    RETURN NULL;
END;
$function$;

drop trigger if exists todolist_change_trigger on public.todolist;
create trigger todolist_change_trigger
    after insert or update on public.todolist
    for each row
    execute function public.handle_todolist_change();

notify pgrst, 'reload schema';
