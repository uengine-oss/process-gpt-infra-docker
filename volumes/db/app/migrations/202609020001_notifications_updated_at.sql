-- notifications.updated_at 추가
--
-- 왜 필요한가
--   fcm_service 는 알림을 발송하기 전에 `consumer`(처리한 파드 이름)와
--   `updated_at` 을 함께 찍어 **선점**한다. 여러 파드가 같은 알림을 두 번
--   보내지 않게 하려는 것이다.
--
--   그런데 이 표에 `updated_at` 컬럼이 없으면 그 UPDATE 가 통째로 실패한다
--   (PostgREST PGRST204: "Could not find the 'updated_at' column").
--   선점이 실패하면 알림은 영원히 '미처리'로 남고 **한 건도 발송되지 않는다.**
--   로그에는 경고만 남아 조용히 멈춘 것처럼 보인다 — 실제로 그랬다.
--
--   컬럼만 있으면 되고, 기존 행에는 시간 정보가 없으므로 기본값을 두지 않는다.

alter table public.notifications
    add column if not exists updated_at timestamptz;

comment on column public.notifications.updated_at is
    'fcm_service 가 이 알림을 선점(발송 담당 지정)한 시각. consumer 와 함께 기록된다.';
