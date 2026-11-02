-- =============================================================================
-- 알림이 실제로 도착하게 한다
--
-- 지금 무엇이 잘못돼 있는가 (운영 데이터로 확인한 것)
--
--   1. 새 업무 알림이 2025-12-23 이후로 한 건도 만들어지지 않았다.
--      `handle_todolist_change()` 함수는 있는데 그것을 부르는 트리거가 없다.
--      기준 스키마(docker-compose/volumes/db/init.sql)에는 있는 트리거다.
--      즉 "승인 요청과 새 업무를 알려 드립니다" 가 8개월 넘게 빈말이었다.
--
--   2. 대화 알림에는 조직(tenant_id)이 안 들어간다. 발송기는 조직으로 걸러
--      가져가는데, NULL 은 `=` 에도 `<>` 에도 걸리지 않아 **아무도 가져가지
--      않는다.** 그렇게 남은 것이 103건이다.
--
--   3. 기기가 사람당 하나였다(기본키가 이메일). 회사 PC 에서 웹을 켜면 휴대폰
--      토큰이 덮어써져 휴대폰 알림이 조용히 끊긴다. 반대도 같다.
--
-- 무엇으로 바꾸는가
--   기기마다 한 줄. 지금 쓰고 있는 기기로 보내고, 아무 기기도 안 쓰고 있으면
--   가진 기기 모두에 보낸다 — 메신저들이 하는 방식이다. 어느 것을 집어 들든
--   보이게 하는 것이 목적이다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. 기기마다 한 줄
-- -----------------------------------------------------------------------------

alter table public.user_devices
    add column if not exists id uuid not null default gen_random_uuid();

-- 기기가 스스로 만들어 보관하는 식별자. 토큰으로 기기를 구분하면 토큰이 갱신될
-- 때마다 새 기기가 하나씩 늘어 죽은 줄이 쌓인다.
alter table public.user_devices
    add column if not exists device_id text;

-- 'web' · 'android' · 'ios'. 발송 규칙은 이것을 보지 않는다(최근에 쓴 기기인가만
-- 본다). 사용자에게 "어느 기기로 가고 있는지" 를 말해 주기 위한 것이다.
alter table public.user_devices
    add column if not exists device_type text;

-- 이 기기를 마지막으로 쓴 시각. 어디로 보낼지 정하는 유일한 근거다.
alter table public.user_devices
    add column if not exists last_active_at timestamptz;

-- 기존 줄에는 식별자가 없다. 지금 있는 값에서 만들어 준다 — 비워 두면 유일성
-- 제약에서 서로 충돌한다.
update public.user_devices
   set device_id = coalesce(device_id, 'legacy-' || md5(user_email || coalesce(device_token, '')))
 where device_id is null;

-- 있던 값에서 최선을 다해 채운다. 없으면 비워 둔다 — 지어내면 "지금 쓰는 기기"
-- 판단이 틀어져 엉뚱한 곳으로 간다.
update public.user_devices
   set last_active_at = coalesce(last_active_at, last_access_at)
 where last_active_at is null;

alter table public.user_devices
    alter column device_id set not null;

-- 기본값을 둔다. 이 마이그레이션과 새 포털이 배포되는 사이에도 옛 코드는
-- `device_id` 없이 줄을 넣는다 — 기본값이 없으면 그 사이 로그인이 오류로
-- 끝난다. 그렇게 생긴 줄은 토큰이 없어 발송 대상이 되지 않는다.
alter table public.user_devices
    alter column device_id set default gen_random_uuid()::text;

-- 기본키를 이메일에서 떼어낸다. 이것이 사람당 기기 하나를 강제하던 자리다.
alter table public.user_devices
    drop constraint if exists user_devices_pkey;

alter table public.user_devices
    add constraint user_devices_pkey primary key (id);

-- 같은 기기가 두 줄이 되지 않게. 갱신은 이 열쇠로 한다(upsert).
create unique index if not exists user_devices_email_device_key
    on public.user_devices (user_email, device_id);

comment on column public.user_devices.device_id is
    '기기가 스스로 만들어 보관하는 식별자. 토큰이 바뀌어도 같은 줄을 갱신한다.';
comment on column public.user_devices.last_active_at is
    '이 기기를 마지막으로 쓴 시각. 알림을 어느 기기로 보낼지 정하는 근거.';
comment on table public.user_devices is
    '알림을 보낼 기기. 사람당 여러 대. 본인 행만 읽고 쓸 수 있다(RLS). 발송은 service_role 이 한다.';

-- -----------------------------------------------------------------------------
-- 2. 대화 알림에 조직을 넣는다
--
--    바뀐 곳은 tenant_id 한 줄뿐이다. 나머지(누가 받을지, 그 방을 보고 있으면
--    보내지 않는 것)는 그대로 둔다.
-- -----------------------------------------------------------------------------

create or replace function public.handle_chat_insert()
returns trigger
language plpgsql
as $function$
DECLARE
    chat_room_participant jsonb;
    participant_email text;
    participant_record record;
    chat_room_name text;
    chat_room_tenant text;
    user_is_in_chat_room boolean;
BEGIN
    -- 조직을 함께 읽는다. 이것이 없으면 발송기가 이 알림을 가져가지 못한다.
    SELECT name, tenant_id INTO chat_room_name, chat_room_tenant
      FROM public.chat_rooms WHERE id = NEW.id;

    FOR participant_record IN
        SELECT jsonb_array_elements(participants) as p
        FROM public.chat_rooms
        WHERE id = NEW.id
    LOOP
        chat_room_participant := participant_record.p;

        IF chat_room_participant->>'username' != 'System' AND chat_room_participant->>'email' != NEW.messages->>'email' THEN
            participant_email := chat_room_participant->>'email';

            -- 그 방을 지금 보고 있으면 알림을 만들지 않는다. 보고 있는 화면에
            -- 대고 알림을 울리는 것은 방해일 뿐이다.
            SELECT EXISTS(
                SELECT 1 FROM user_devices
                WHERE user_email = participant_email
                AND access_page = 'chat:' || NEW.id
                AND last_access_at > now() - interval '5 minutes'
            ) INTO user_is_in_chat_room;

            IF NOT user_is_in_chat_room THEN
                INSERT INTO notifications (id, user_id, title, type, description, is_checked, time_stamp, url, from_user_id, tenant_id)
                VALUES (
                    gen_random_uuid(),
                    participant_email,
                    NEW.messages->>'content',
                    'chat',
                    chat_room_name,
                    false,
                    now(),
                    '/chats?id=' || NEW.id,
                    NEW.messages->>'name',
                    coalesce(NEW.tenant_id, chat_room_tenant)
                )
                ON CONFLICT (id) DO UPDATE
                SET
                    user_id = EXCLUDED.user_id,
                    title = EXCLUDED.title,
                    time_stamp = EXCLUDED.time_stamp,
                    is_checked = EXCLUDED.is_checked,
                    url = EXCLUDED.url,
                    from_user_id = EXCLUDED.from_user_id,
                    tenant_id = EXCLUDED.tenant_id;
            END IF;
        END IF;
    END LOOP;

    RETURN NULL;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 3. 새 업무 알림을 되살린다
--
--    함수의 `SELECT proc_inst_name, tenant_id INTO v_proc_inst_name` 은 두 칸을
--    변수 하나에 넣으려 한다. 이것이 트리거가 사라진 이유일 수 있으므로 함께
--    고친다. 조직은 업무 행의 것을 먼저 쓰고, 없으면 건의 것을 쓴다.
-- -----------------------------------------------------------------------------

create or replace function public.handle_todolist_change()
returns trigger
language plpgsql
as $function$
DECLARE
    v_proc_inst_name text;
    v_proc_tenant_id text;
    v_by_agent boolean;
    should_notify boolean := false;
BEGIN
    -- 에이전트가 대신 하는 단계인가. 사람이 할 일과 알릴 시점이 다르다.
    v_by_agent := coalesce(NEW.agent_mode, '') <> '';

    -- 사람이 하는 일: 내 차례가 되는 순간 알린다.
    IF NOT v_by_agent THEN
        IF (TG_OP = 'INSERT' AND NEW.status = 'IN_PROGRESS') THEN
            should_notify := true;
        END IF;

        IF (TG_OP = 'UPDATE' AND NEW.status = 'IN_PROGRESS' AND (OLD.status IS NULL OR OLD.status != 'IN_PROGRESS')) THEN
            should_notify := true;
        END IF;
    END IF;

    -- 에이전트가 하는 일: 시작했다고 알릴 이유가 없다. 사람이 볼 것이 생겼을
    -- 때 — 초안이 나왔거나, 물어볼 것이 생겼거나, 실패했을 때 — 알린다.
    -- 앱이 화면에서 "끝나면 알림으로 알려 드립니다" 라고 약속하는 그 순간이다.
    IF v_by_agent AND TG_OP = 'UPDATE'
       AND NEW.draft_status IS DISTINCT FROM OLD.draft_status
       AND NEW.draft_status::text IN ('COMPLETED', 'FB_REQUESTED', 'HUMAN_ASKED', 'FAILED') THEN
        should_notify := true;
    END IF;

    -- 담당자가 없으면 알릴 곳이 없다.
    IF NEW.user_id IS NULL OR NEW.user_id = '' THEN
        should_notify := false;
    END IF;

    IF should_notify THEN
        SELECT proc_inst_name, tenant_id INTO v_proc_inst_name, v_proc_tenant_id
        FROM bpm_proc_inst
        WHERE proc_inst_id = NEW.proc_inst_id;

        INSERT INTO notifications (id, user_id, title, type, description, is_checked, time_stamp, tenant_id, url)
        VALUES (
            gen_random_uuid(),
            NEW.user_id,
            NEW.activity_name,
            CASE
                WHEN NEW.proc_inst_id IS NOT NULL AND NEW.proc_inst_id <> '' THEN 'workitem_bpm'
                ELSE 'workitem'
            END,
            COALESCE(v_proc_inst_name, NEW.activity_name),
            false,
            now(),
            COALESCE(NEW.tenant_id, v_proc_tenant_id),
            '/todolist/' || NEW.id
        );
    END IF;
    RETURN NULL;
END;
$function$;

drop trigger if exists todolist_change_trigger on public.todolist;
create trigger todolist_change_trigger
    after insert or update on public.todolist
    for each row
    execute function public.handle_todolist_change();

notify pgrst, 'reload schema';
