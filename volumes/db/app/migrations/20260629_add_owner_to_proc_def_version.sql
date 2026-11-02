-- 저장 버전별로 저장한 사용자를 기록하기 위한 컬럼 추가
-- owner: 해당 버전을 저장한 시점의 사용자 식별자(사번 우선, email/uid fallback)
ALTER TABLE public.proc_def_version ADD COLUMN IF NOT EXISTS owner TEXT DEFAULT NULL;
