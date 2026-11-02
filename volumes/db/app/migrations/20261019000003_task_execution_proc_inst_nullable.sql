-- =============================================================================
-- task_execution_properties.proc_inst_id NULL 허용
--
-- 20260202 마이그레이션이 standalone task(인스턴스 없는 할 일)를 받으려고
-- proc_def_id·activity_id 의 NOT NULL 을 풀었지만 proc_inst_id 는 남겨 두었다.
-- 그래서 인스턴스 없이 만든 할 일(대화창 업무 인계, 할 일 직접 추가)이 todolist
-- INSERT 트리거(sync_task_execution_on_insert)에서 not-null 위반으로 통째로 실패한다.
-- BPM 분석 뷰는 이미 proc_inst_id IS NOT NULL 인 행만 보므로 분석 결과는 바뀌지 않는다.
-- =============================================================================

ALTER TABLE public.task_execution_properties
    ALTER COLUMN proc_inst_id DROP NOT NULL;
