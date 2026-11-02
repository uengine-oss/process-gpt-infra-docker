-- 피드백 수집(agent-feedback) 보정: agent_feedback_task(migrations/20260922000002) 가 읽는 todolist.feedback_collected_count 가
-- init.sql 에 없어 agent-feedback 이 7초마다 「column "feedback_collected_count" does not exist」로 실패하고, 업무 피드백이
-- 하나도 수집되지 않았다(feedback_proposals 0행). 프론트 저장소 docker-compose/volumes/db/init.sql 과 같은 정의.
ALTER TABLE public.todolist
    ADD COLUMN IF NOT EXISTS feedback_collected_count integer NOT NULL DEFAULT 0;

NOTIFY pgrst, 'reload schema';
