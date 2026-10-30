-- ============================================
-- actual_start_date 추가 마이그레이션
-- status가 IN_PROGRESS로 변경될 때 실제 시작 시간 기록
-- ============================================

-- 1. todolist에 actual_start_date 컬럼 추가
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'todolist' AND column_name = 'actual_start_date') THEN
        ALTER TABLE public.todolist ADD COLUMN actual_start_date TIMESTAMPTZ;
    END IF;
END $$;

-- 인덱스 추가
CREATE INDEX IF NOT EXISTS idx_todolist_actual_start ON public.todolist(actual_start_date);

-- 2. status 변경 시 actual_start_date 자동 설정 트리거
CREATE OR REPLACE FUNCTION public.set_actual_start_date()
RETURNS TRIGGER AS $$
BEGIN
    -- status가 IN_PROGRESS로 변경되고, actual_start_date가 아직 설정되지 않은 경우
    IF NEW.status = 'IN_PROGRESS' AND OLD.status IS DISTINCT FROM 'IN_PROGRESS' THEN
        IF NEW.actual_start_date IS NULL THEN
            NEW.actual_start_date := NOW();
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_actual_start_date ON public.todolist;
CREATE TRIGGER trg_set_actual_start_date
    BEFORE UPDATE OF status ON public.todolist
    FOR EACH ROW
    EXECUTE FUNCTION public.set_actual_start_date();

-- 3. 기존 데이터 백필: IN_PROGRESS 또는 DONE 상태인 task의 actual_start_date 설정
-- start_date가 있으면 그 값 사용, 없으면 updated_at 사용
UPDATE public.todolist
SET actual_start_date = COALESCE(start_date, updated_at)
WHERE status IN ('IN_PROGRESS', 'DONE')
  AND actual_start_date IS NULL;

-- 4. bpm_proc_inst에도 actual_start_date 추가 (프로세스 인스턴스용)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'bpm_proc_inst' AND column_name = 'actual_start_date') THEN
        ALTER TABLE public.bpm_proc_inst ADD COLUMN actual_start_date TIMESTAMPTZ;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_bpm_proc_inst_actual_start ON public.bpm_proc_inst(actual_start_date);

-- 5. bpm_proc_inst status 변경 트리거
CREATE OR REPLACE FUNCTION public.set_proc_inst_actual_start_date()
RETURNS TRIGGER AS $$
BEGIN
    -- status가 RUNNING으로 변경되고, actual_start_date가 아직 설정되지 않은 경우
    IF NEW.status = 'RUNNING' AND OLD.status IS DISTINCT FROM 'RUNNING' THEN
        IF NEW.actual_start_date IS NULL THEN
            NEW.actual_start_date := NOW();
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_proc_inst_actual_start_date ON public.bpm_proc_inst;
CREATE TRIGGER trg_set_proc_inst_actual_start_date
    BEFORE UPDATE OF status ON public.bpm_proc_inst
    FOR EACH ROW
    EXECUTE FUNCTION public.set_proc_inst_actual_start_date();

-- 6. 기존 bpm_proc_inst 백필
UPDATE public.bpm_proc_inst
SET actual_start_date = COALESCE(start_date, updated_at)
WHERE status IN ('RUNNING', 'COMPLETED')
  AND actual_start_date IS NULL;

COMMENT ON COLUMN public.todolist.actual_start_date IS '실제 작업 시작 시간 (IN_PROGRESS 상태로 변경된 시점)';
COMMENT ON COLUMN public.bpm_proc_inst.actual_start_date IS '실제 프로세스 시작 시간 (RUNNING 상태로 변경된 시점)';
