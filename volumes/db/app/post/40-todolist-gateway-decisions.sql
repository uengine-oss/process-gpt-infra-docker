-- 워크아이템의 게이트웨이 분기 판정 열(todolist.gateway_decisions) 보정.
-- 지금의 polling-service 는 WorkItem 을 todolist 에 쓸 때 이 열을 함께 쓴다. init.sql 에는 없어서, 어떤 프로세스든 첫 제출에서
-- 「Could not find the 'gateway_decisions' column of 'todolist' in the schema cache (PGRST204)」로 세 번 재시도한 뒤 멈춘다.
-- 원본: process-gpt-completion supabase/migrations/20260908000001_todolist_gateway_decisions.sql
ALTER TABLE public.todolist
    ADD COLUMN IF NOT EXISTS gateway_decisions jsonb;

COMMENT ON COLUMN public.todolist.gateway_decisions IS
    '이 워크아이템 완료 시점의 게이트웨이 분기 판정. {gateway_id: {selected: [seq_id], sequences: {seq_id: {target, condition, eval, reason}}}}.';

NOTIFY pgrst, 'reload schema';
