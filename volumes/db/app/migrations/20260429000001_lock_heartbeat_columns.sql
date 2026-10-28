-- lock 테이블에 heartbeat 및 force checkout 컬럼 추가
-- 체계도 편집 잠금 기능에서 사용

ALTER TABLE public.lock
    ADD COLUMN IF NOT EXISTS heartbeat_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS force_checkout_by TEXT,
    ADD COLUMN IF NOT EXISTS force_checkout_at TIMESTAMPTZ;
