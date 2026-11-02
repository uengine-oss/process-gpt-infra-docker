-- ============================================================================
-- 핸드오버 스레드 상관키(origin_room_id)
--
-- 이메일 스레드가 References/In-Reply-To 로 루트 Message-ID 를 앞으로 끌고 가듯,
-- 인계도 "이 업무가 최초로 시작된 방" 을 인계받는 방으로 계속 전파한다.
-- 그래야 A→B→C→D 로 이어진 인계가 Gmail 의 forward 묶음처럼 한 스레드로 모인다.
--
-- case_id 와의 관계:
--   origin_room_id — 구조적 상관키. 항상 채워지며 스레드 묶음의 기준.
--   case_id        — 분석용 케이스 키. 지금은 origin_room_id 와 같은 값이지만,
--                    나중에 업무 키(견적번호 등)나 케이스 분할이 도입되면 갈라진다.
-- 둘을 분리해 두어야 나중에 case 를 쪼개도 스레드 표시는 깨지지 않는다.
-- ============================================================================

alter table public.handover_events
    add column if not exists origin_room_id text;

-- 기존 행 백필: 지금까지는 case_id 가 곧 루트 방 id 였다.
update public.handover_events
set origin_room_id = case_id
where origin_room_id is null;

create index if not exists idx_handover_events_origin_room
    on public.handover_events (tenant_id, origin_room_id, occurred_at);

comment on column public.handover_events.origin_room_id is
    '이 업무가 최초로 시작된 채팅방 id. 인계받는 방으로 계속 전파되어 스레드 묶음의 기준이 된다.';
comment on column public.handover_events.case_id is
    '프로세스 마이닝의 Case ID. 기본값은 origin_room_id 이며 업무 키 도입 시 분리될 수 있다.';
