-- 패널 내장 속성을 사용자 정의 속성 목록으로 통합한다.
-- renderer=panel은 RACI/FTE/폼 연결처럼 전용 위젯이 있는 사용자 정의 속성을
-- 일반 탭의 범용 필드가 아닌 기존 패널 UI에 연결하는 렌더링 메타데이터다.
-- 관리자 UI에서 별도 내장 분류/수정 제한에는 사용하지 않는다.

UPDATE public.task_property_schema
   SET config = (COALESCE(config, '{}'::jsonb) - 'builtin')
                || jsonb_build_object(
                    'renderer', 'panel',
                    'panelProperty', true,
                    'panelTaskType', COALESCE(config->>'panelTaskType', task_type)
                )
 WHERE COALESCE(config->>'builtin', 'false') = 'true';

-- task_io는 절차 단계만 편집한다. 기존 프로세스 BPMN 안의 input/output 값은
-- 데이터 유실 방지를 위해 삭제하지 않고 레거시 값으로 그대로 보존한다.
UPDATE public.task_property_schema
   SET config = jsonb_set(
                    COALESCE(config, '{}'::jsonb),
                    '{binding}',
                    to_jsonb('taskForm.procedure'::text),
                    true
                ),
       description = CASE
           WHEN description IS NULL
             OR description LIKE '%Input%Output%'
             OR description LIKE '%Input/%/Output%'
           THEN 'Task 계열 요소의 단계별 업무 수행 절차'
           ELSE description
       END
 WHERE property_key = 'task_io'
   AND COALESCE(config->>'panelProperty', 'false') = 'true';
