-- =============================================================================
-- lock 테이블 스키마 드리프트 보정: user_name(+heartbeat_at) 컬럼
--
-- 증상: 프로세스 순서도에서 편집 모드 전환 실패 → 속성 패널 편집 불가.
-- 원인: 프론트 잠금 로직(ProcessGPTBackend.setLock/acquireLockWithStaleCheck,
--       ProcessHierarchy.loadLockMap)이 lock.user_name·heartbeat_at 을 조회/기록하는데,
--       이 컬럼이 없는 환경(외부 스테이징 실측: started_time만 있는 구스키마)에서는
--       PostgREST 42703 으로 잠금 획득이 실패해 순서도가 VIEW 모드에 갇힌다.
-- user_name 은 지금까지 어떤 마이그레이션에도 없던 로컬 수동 컬럼(드리프트)이라 여기서 정식화한다.
-- heartbeat_at/force_checkout_* 는 20260429_lock_heartbeat_columns.sql 과 중복이지만
-- 미적용 환경 대비 멱등(ADD COLUMN IF NOT EXISTS)으로 재선언한다.
-- =============================================================================

ALTER TABLE public.lock
    ADD COLUMN IF NOT EXISTS user_name TEXT,
    ADD COLUMN IF NOT EXISTS heartbeat_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS force_checkout_by TEXT,
    ADD COLUMN IF NOT EXISTS force_checkout_at TIMESTAMPTZ;

-- 구스키마(started_time)에서 넘어온 행의 heartbeat 백필 — started_time 컬럼이 있는 환경에서만
-- 동적 SQL로 실행(없는 환경에서 정적 참조하면 42703이므로 DO 블록 필수).
DO $body$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'lock' AND column_name = 'started_time') THEN
    EXECUTE 'UPDATE public.lock SET heartbeat_at = COALESCE(heartbeat_at, started_time) WHERE heartbeat_at IS NULL';
  END IF;
END
$body$;
