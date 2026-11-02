-- =====================================================
-- KST(Asia/Seoul) 타임존 고정
-- Date: 2026-06-23
-- Description:
--   DB/역할 세션 타임존을 Asia/Seoul 로 설정해, 모든 세션과 PostgREST
--   응답의 timestamptz 직렬화(+09:00) 및 now()/current_timestamp/
--   localtimestamp 가 KST 기준이 되도록 통일한다.
--   - 컬럼 타입은 변경하지 않는다(비파괴적, 기존 데이터 안전).
--   - timestamp without time zone DEFAULT current_timestamp 컬럼도
--     이후 입력값이 KST 벽시계 시각으로 저장된다.
-- =====================================================

DO $$
BEGIN
  EXECUTE format('ALTER DATABASE %I SET timezone TO ''Asia/Seoul''', current_database());
END $$;

DO $$
DECLARE r text;
BEGIN
  -- supabase_* internal roles are reserved and cannot be altered by the
  -- migration runner. The database default above still applies to them.
  FOREACH r IN ARRAY ARRAY['authenticator','anon','authenticated','service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('ALTER ROLE %I SET timezone TO ''Asia/Seoul''', r);
    END IF;
  END LOOP;
END $$;

SET timezone TO 'Asia/Seoul';
