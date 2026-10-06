-- 벤치 DB 의 역할 설정. 운영(Supabase)에서는 플랫폼이 만들어 주는 부분이다.
--
-- SDK 는 supabase-py 로 PostgREST 에 붙는다. 그 경로를 그대로 쓰기 위해
-- authenticator/anon 역할을 둔다 — "RPC 를 psql 로 직접 불러서 됐다" 가 아니라
-- 운영과 같은 호출 경로(HTTP → PostgREST → RPC)로 확인하기 위한 것이다.
DO $$ BEGIN
  CREATE ROLE anon NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD 'bench';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

GRANT anon TO authenticator;
GRANT USAGE ON SCHEMA public TO anon;
GRANT ALL ON ALL TABLES IN SCHEMA public TO anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon;

-- 벤치는 한 테넌트만 쓴다. RLS 는 이 검증의 대상이 아니다(점유 판정은
-- RPC 안에서 일어나고, 워커는 service 권한으로 붙는다).
