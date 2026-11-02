-- ============================================================================
-- 핸드오버 이벤트 로그
--
-- 채팅방(/chat)과 워크아이템에서 발생하는 "업무 이관" 을 구조화된 이벤트로
-- 축적한다. process-miner 서비스가 이 로그로부터 핸드오버 네트워크(조직 마이닝)와
-- 프로세스 정의(제어 흐름 마이닝)를 도출한다.
--
-- 사람과 AI 에이전트는 모두 public.users 한 테이블에 있으므로(is_agent 플래그로만
-- 구분) 이 로그도 둘을 구분하지 않는다. from_is_agent / to_is_agent 는 분석 편의를
-- 위한 비정규화 스냅샷일 뿐이며, 네트워크는 하나로 계산된다.
--
-- source
--   chat_handover    : 사용자가 채팅방에서 '인계하기' 버튼을 눌러 명시적으로 넘김
--   agent_delegation : 채팅방에서 에이전트에게 암묵적으로 위임됨(초대/라우팅)
--   todolist         : 기존 BPMN 인스턴스 실행 이력에서 역산된 이관
-- ============================================================================

create table if not exists public.handover_events (
    id                    uuid        not null default gen_random_uuid(),
    tenant_id             text        not null default public.tenant_id(),

    -- 핸드오버 체인 = 하나의 업무 케이스(프로세스 마이닝의 Case ID)
    case_id               text        not null,
    source                text        not null,
    is_explicit           boolean     not null default true,

    -- 이관 전/후 컨텍스트
    from_room_id          text        null,
    to_room_id            text        null,
    from_task_id          uuid        null,
    to_task_id            uuid        null,

    -- 리소스(사람 또는 에이전트)
    from_user_id          text        null,
    from_user_name        text        null,
    from_role             text        null,
    from_is_agent         boolean     not null default false,
    to_user_id            text        not null,
    to_user_name          text        null,
    to_role               text        null,
    to_is_agent           boolean     not null default false,
    agent_orch            text        null,

    -- 활동 라벨
    activity_label        text        null,  -- 넘기는 사람이 적은 "지금까지 한 일"
    next_activity_label   text        null,  -- 넘기는 사람이 적은 "다음에 할 일"
    norm_activity_label   text        null,  -- process-miner 가 채우는 정규화 라벨
    instruction           text        null,
    reason                text        null,

    -- 산출물 / 참여 에이전트
    artifact_refs         jsonb       not null default '[]'::jsonb,
    participant_agents    jsonb       not null default '[]'::jsonb,
    trigger_message_uuid  text        null,

    proc_def_id           text        null,

    -- 타이밍
    occurred_at           timestamptz not null default now(),
    returned_at           timestamptz null,   -- 에이전트가 결과를 돌려준 시각
    handover_latency_sec  integer     null,   -- 직전 이벤트로부터의 이관 지연

    created_at            timestamptz not null default now(),
    updated_at            timestamptz not null default now(),

    constraint handover_events_pkey primary key (id),
    constraint handover_events_source_check check (
        source in ('chat_handover', 'agent_delegation', 'todolist')
    ),
    constraint handover_events_tenant_id_fkey foreign key (tenant_id)
        references public.tenants (id) on update cascade on delete cascade
) tablespace pg_default;

create index if not exists idx_handover_events_case
    on public.handover_events (tenant_id, case_id, occurred_at);
create index if not exists idx_handover_events_from_user
    on public.handover_events (tenant_id, from_user_id);
create index if not exists idx_handover_events_to_user
    on public.handover_events (tenant_id, to_user_id);
create index if not exists idx_handover_events_from_room
    on public.handover_events (tenant_id, from_room_id);
create index if not exists idx_handover_events_to_room
    on public.handover_events (tenant_id, to_room_id);
-- process-miner 의 미처리 행 스캔용
create index if not exists idx_handover_events_unlabeled
    on public.handover_events (tenant_id, occurred_at)
    where norm_activity_label is null;

-- todolist 실행 이력 역산 시 같은 워크아이템이 두 번 들어오지 않도록
create unique index if not exists uq_handover_events_todolist
    on public.handover_events (source, to_task_id)
    where to_task_id is not null;

-- 암묵 위임 중복 방지: 같은 방·같은 에이전트·같은 트리거 메시지는 1건
-- (새로고침 후 스트림 재접속 시 중복 삽입 차단)
--
-- WHERE 절 없는 전체 인덱스여야 한다. 부분 인덱스로 만들면 PostgREST 의
-- upsert(onConflict=...) 가 술어를 지정할 수 없어 "no unique or exclusion
-- constraint matching the ON CONFLICT specification" 로 실패한다.
-- trigger_message_uuid 는 암묵 위임에만 채워지고 나머지 source 는 NULL 인데,
-- Postgres 기본값(NULLS DISTINCT)에서 NULL 은 서로 충돌하지 않으므로
-- chat_handover / todolist 행에는 아무 제약도 걸리지 않는다.
create unique index if not exists uq_handover_events_agent_delegation
    on public.handover_events (from_room_id, to_user_id, trigger_message_uuid);

drop trigger if exists handover_events_updated_at on public.handover_events;
create trigger handover_events_updated_at
    before update on public.handover_events
    for each row execute function public.update_updated_at_column();

-- RLS (resource_pull_requests 패턴과 동일)
alter table public.handover_events enable row level security;

DROP POLICY IF EXISTS handover_events_insert_policy ON public.handover_events;
create policy handover_events_insert_policy on public.handover_events
    for insert to authenticated with check (tenant_id = public.tenant_id());
DROP POLICY IF EXISTS handover_events_select_policy ON public.handover_events;
create policy handover_events_select_policy on public.handover_events
    for select to authenticated using (tenant_id = public.tenant_id());
DROP POLICY IF EXISTS handover_events_update_policy ON public.handover_events;
create policy handover_events_update_policy on public.handover_events
    for update to authenticated using (tenant_id = public.tenant_id());
DROP POLICY IF EXISTS handover_events_delete_policy ON public.handover_events;
create policy handover_events_delete_policy on public.handover_events
    for delete to authenticated using (tenant_id = public.tenant_id());
