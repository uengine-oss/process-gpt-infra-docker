-- 에이전트 이벤트 종류(event_type_enum) 보정.
-- init.sql 의 열거형은 10개뿐인데, 지금의 서비스는 값을 더 쓴다. 없는 값으로 events 에 넣으면
-- 「invalid input value for enum event_type_enum」으로 실패한다 — 예: bpmn-extractor 가 사람에게 확인을 물을 때
-- 'waiting_for_user' 를 못 남겨 질문이 화면에 오지 않고 작업이 IN_PROGRESS 로 멈춘다.
ALTER TYPE public.event_type_enum ADD VALUE IF NOT EXISTS 'waiting_for_user';
ALTER TYPE public.event_type_enum ADD VALUE IF NOT EXISTS 'task_cancelled';
ALTER TYPE public.event_type_enum ADD VALUE IF NOT EXISTS 'human_feedback_submitted';
ALTER TYPE public.event_type_enum ADD VALUE IF NOT EXISTS 'gateway_decision';
ALTER TYPE public.event_type_enum ADD VALUE IF NOT EXISTS 'gateway_decision_trace';
ALTER TYPE public.event_type_enum ADD VALUE IF NOT EXISTS 'mcp_call_started';
ALTER TYPE public.event_type_enum ADD VALUE IF NOT EXISTS 'mcp_call_finished';
ALTER TYPE public.event_type_enum ADD VALUE IF NOT EXISTS 'mcp_call_failed';
ALTER TYPE public.event_type_enum ADD VALUE IF NOT EXISTS 'mcp_tools_loaded';
ALTER TYPE public.event_type_enum ADD VALUE IF NOT EXISTS 'mcp_server_health_changed';
ALTER TYPE public.event_type_enum ADD VALUE IF NOT EXISTS 'llm_call_finished';
