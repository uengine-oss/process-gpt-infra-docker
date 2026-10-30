-- =============================================================================
-- todolist 테이블 변경 시 task_execution_properties 자동 동기화 트리거
-- Kafka, Frontend, API 등 어떤 경로로든 todolist가 변경되면 자동 기록
-- =============================================================================

-- 기존 트리거/함수 삭제
DROP TRIGGER IF EXISTS trg_task_execution_insert ON public.todolist;
DROP TRIGGER IF EXISTS trg_task_execution_update ON public.todolist;
DROP FUNCTION IF EXISTS sync_task_execution_on_insert();
DROP FUNCTION IF EXISTS sync_task_execution_on_update();

-- 1. todolist INSERT 시 → task_execution_properties에 STARTED 레코드 생성
CREATE OR REPLACE FUNCTION sync_task_execution_on_insert()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.task_execution_properties (
        tenant_id,
        proc_def_id,
        proc_inst_id,
        activity_id,
        activity_name,
        todo_id,
        tool,
        execution_status,
        started_at,
        executor_email
    ) VALUES (
        NEW.tenant_id,
        NEW.proc_def_id,
        NEW.proc_inst_id,
        NEW.activity_id,
        NEW.activity_name,
        NEW.id,
        NEW.tool,
        'STARTED',
        now(),  -- 실제 태스크 생성 시점 사용 (start_date는 계획 날짜일 수 있음)
        NEW.user_id
    )
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. todolist UPDATE 시 → 상태 변경되면 완료 처리
CREATE OR REPLACE FUNCTION sync_task_execution_on_update()
RETURNS TRIGGER AS $$
DECLARE
    new_status text;
    completed_time timestamptz;
BEGIN
    -- 상태 매핑 (todolist ENUM → task_execution_properties TEXT)
    -- todolist status: NEW, RUNNING, DONE, PENDING, IN_PROGRESS, SUBMITTED, COMPLETED, CANCELLED
    IF NEW.status::text IN ('DONE', 'COMPLETED') THEN
        new_status := 'COMPLETED';
    ELSIF NEW.status::text = 'CANCELLED' THEN
        new_status := 'CANCELLED';
    ELSE
        new_status := 'STARTED';
    END IF;

    completed_time := COALESCE(NEW.end_date, NEW.updated_at, now());

    -- 기존 레코드 업데이트
    UPDATE public.task_execution_properties
    SET
        execution_status = new_status,
        completed_at = CASE WHEN new_status IN ('COMPLETED', 'CANCELLED') THEN completed_time ELSE NULL END,
        actual_duration = CASE WHEN new_status IN ('COMPLETED', 'CANCELLED') THEN completed_time - started_at ELSE NULL END,
        executor_email = COALESCE(NEW.user_id, executor_email),
        activity_name = COALESCE(NEW.activity_name, activity_name),
        tool = COALESCE(NEW.tool, tool)
    WHERE todo_id = NEW.id;

    -- 기존 레코드 없으면 새로 생성
    IF NOT FOUND THEN
        INSERT INTO public.task_execution_properties (
            tenant_id, proc_def_id, proc_inst_id, activity_id, activity_name,
            todo_id, tool, execution_status, started_at, completed_at, actual_duration, executor_email
        ) VALUES (
            NEW.tenant_id, NEW.proc_def_id, NEW.proc_inst_id, NEW.activity_id, NEW.activity_name,
            NEW.id, NEW.tool, new_status, now(),  -- 실제 시점 사용
            CASE WHEN new_status IN ('COMPLETED', 'CANCELLED') THEN completed_time ELSE NULL END,
            CASE WHEN new_status IN ('COMPLETED', 'CANCELLED') THEN completed_time - now() ELSE NULL END,
            NEW.user_id
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. 트리거 생성
CREATE TRIGGER trg_task_execution_insert
    AFTER INSERT ON public.todolist
    FOR EACH ROW
    EXECUTE FUNCTION sync_task_execution_on_insert();

CREATE TRIGGER trg_task_execution_update
    AFTER UPDATE ON public.todolist
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION sync_task_execution_on_update();
