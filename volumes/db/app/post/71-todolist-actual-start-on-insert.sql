-- 실제 시작 시각 보정: actual_start_date 는 status 가 IN_PROGRESS 로 「바뀔 때」만 기록됐다(migrations/20260128_actual_start_date).
-- 실행 창이 첫 단계 할 일을 처음부터 IN_PROGRESS 로 넣으면 바뀜이 없어 비어 있고, 분석(process-gpt-analytic)은 예정 시각
-- start_date 로 재게 된다 — 그 값은 프론트가 UTC 벽시계로 넣어(시간대 없는 열) 첫 단계가 9시간 걸린 것처럼 보였다.
-- 넣을 때 IN_PROGRESS 면 그때를 실제 시작으로 기록한다(멱등).
CREATE OR REPLACE FUNCTION public.set_actual_start_date()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'IN_PROGRESS'
       AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'IN_PROGRESS')
       AND NEW.actual_start_date IS NULL THEN
        NEW.actual_start_date := NOW();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_actual_start_date ON public.todolist;
CREATE TRIGGER trg_set_actual_start_date
    BEFORE INSERT OR UPDATE OF status ON public.todolist
    FOR EACH ROW
    EXECUTE FUNCTION public.set_actual_start_date();
