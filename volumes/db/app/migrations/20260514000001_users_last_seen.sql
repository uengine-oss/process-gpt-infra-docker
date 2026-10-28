-- =============================================================================
-- users.last_seen_at
--   사용자가 마지막으로 활동한 시각.
--   탭이 visible 상태일 때만 update — visibility 변경 시점 + 5분 간격
--   heartbeat 로 갱신한다. (main.ts 의 setupLastSeenHeartbeat 참조)
--
--   ※ supabase auth.users.last_sign_in_at 은 "로그인" 시각만 반영하므로,
--     실제 사용자 활동을 보기 위해 별도 컬럼을 둔다.
-- =============================================================================

ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS last_seen_at timestamptz;

COMMENT ON COLUMN public.users.last_seen_at IS '마지막 활동 시각 (탭 visible + 5분 heartbeat 기준).';

CREATE INDEX IF NOT EXISTS idx_users_last_seen_at
    ON public.users (last_seen_at);
