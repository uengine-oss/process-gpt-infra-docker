-- ============================================================================
-- 병렬 인계 묶음(group_id)
--
-- 한 번의 인계로 여러 사람(에이전트)에게 일을 나눠 줄 수 있다. 받는 사람마다 한 행을
-- 남기고, 같은 인계에서 나온 행은 같은 group_id 로 묶는다. 묶음 안에서 다음 할 일이
-- 서로 다르면 병렬, 같으면 다중 인스턴스로 도출한다. 한 사람에게 넘긴 행은 비워 둔다.
-- ============================================================================

alter table public.handover_events
    add column if not exists group_id uuid;

create index if not exists handover_events_group_idx
    on public.handover_events (group_id)
    where group_id is not null;

comment on column public.handover_events.group_id is
    '한 번의 인계로 여러 명에게 넘긴 행들의 묶음. 한 사람에게 넘긴 인계는 null.';
