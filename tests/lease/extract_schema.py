#!/usr/bin/env python3
"""init.sql 에서 lease 검증에 필요한 조각만 뽑아 벤치용 schema.sql 을 만든다.

벤치 DB 에 init.sql 전체(133KB)를 넣을 수는 없다 — auth 스키마, pgvector,
supabase 역할처럼 이 검증과 무관한 전제가 너무 많다. 그렇다고 todolist DDL 과
RPC 를 손으로 다시 적으면, 검증한 것이 운영에 들어가는 것과 같다는 보장이 사라진다.

그래서 **텍스트를 그대로 뽑아 쓴다**. 아래 함수와 테이블 정의는 init.sql 에 있는
문자 그대로이고, 이 스크립트는 전제(enum, tenants, 트리거 함수)만 보탠다.
같은 스크립트를 git 의 과거 init.sql 에 돌리면 lease 이전의 RPC 로 똑같은 벤치를
세울 수 있다 — "되돌리면 실패한다" 를 실제로 돌려 보기 위한 장치다.
"""
import argparse
import re
import sys

PRELUDE = """-- 이 파일은 extract_schema.py 가 init.sql 에서 뽑아 만든다. 직접 고치지 않는다.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

DO $$ BEGIN
  CREATE TYPE todo_status AS ENUM ('NEW','TODO','IN_PROGRESS','SUBMITTED','PENDING','DONE','CANCELLED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE agent_mode AS ENUM ('NONE','DRAFT','COMPLETE','A2A');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE draft_status AS ENUM ('STARTED','CANCELLED','COMPLETED','FB_REQUESTED','HUMAN_ASKED','FAILED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 운영에서는 JWT 클레임을 읽는다. 벤치에서는 테넌트 분기를 보지 않으므로 고정값.
CREATE OR REPLACE FUNCTION public.tenant_id() RETURNS text
LANGUAGE sql STABLE AS $$ SELECT 'bench'::text $$;

CREATE TABLE IF NOT EXISTS public.tenants (
    id text PRIMARY KEY,
    name text
);
INSERT INTO public.tenants (id, name) VALUES ('bench','bench')
ON CONFLICT (id) DO NOTHING;

-- todolist 의 updated_at 트리거. lease 연장도 UPDATE 이므로 이 트리거를 타고,
-- 그 비용과 부수효과(갱신 횟수만큼 updated_at 이 바뀐다)까지 벤치에 포함시킨다.
CREATE OR REPLACE FUNCTION public.update_updated_at_column() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;
"""

POSTLUDE = """
DROP TRIGGER IF EXISTS set_updated_at ON public.todolist;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.todolist
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
"""

# agent_mode enum 에 'A2A' 같은 값이 운영에만 있을 수 있어, 테이블 DDL 의
# agent_mode 컬럼 타입은 init.sql 의 것을 그대로 쓴다(위 PRELUDE 와 맞춰 둔다).

FUNCS = ["fetch_pending_task", "renew_task_lease", "release_task_lease", "save_task_result"]


def extract_table(sql: str, name: str) -> str:
    m = re.search(
        r"create table if not exists public\.%s \(.*?\) tablespace pg_default;" % name,
        sql, re.S | re.I)
    if not m:
        raise SystemExit("테이블 DDL 을 찾지 못했다: %s" % name)
    return m.group(0)


def extract_function(sql: str, name: str) -> str:
    """CREATE OR REPLACE FUNCTION public.<name>( ... ) 를 본문 종료($$;)까지 뽑는다."""
    start = re.search(
        r"CREATE OR REPLACE FUNCTION public\.%s\s*\(" % re.escape(name), sql, re.I)
    if not start:
        return ""
    body = sql[start.start():]
    # 본문을 감싼 $$ ... $$; 의 끝. 함수 하나에 $$ 는 여는 것/닫는 것 두 번 나온다.
    first = body.index("$$")
    second = body.index("$$", first + 2)
    end = body.index(";", second)
    return body[:end + 1]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("init_sql")
    ap.add_argument("-o", "--out", default="-")
    ap.add_argument("--no-lease-columns", action="store_true",
                    help="lease 컬럼을 붙이지 않는다(= lease 도입 전 상태로 벤치를 세운다)")
    ap.add_argument("--upgrade-only", action="store_true",
                    help="이미 도는 DB 에 적용할 것만 낸다(테이블 생성 없이 "
                         "컬럼 추가 + 함수 교체 + 권한). 운영 중 적용을 흉내낸다")
    args = ap.parse_args()

    sql = open(args.init_sql, encoding="utf-8").read()

    if args.upgrade_only:
        # 운영 중 적용분. 테이블은 이미 있고 워커는 돌고 있다고 가정한다.
        #
        # GRANT 를 빼놓지 않는 것이 중요하다. 새 시그니처의 함수는 새 함수이고,
        # 권한은 따라오지 않는다. 빼먹으면 마이그레이션 직후 모든 워커가
        # "function does not exist" 로 폴링에 실패한다.
        parts = ["""
-- 한 트랜잭션으로 적용한다. Postgres 는 DDL 도 트랜잭션이므로, 워커들은
-- 적용 전이나 적용 후만 보고 중간 상태를 보지 않는다. 특히 아래 DROP 과
-- CREATE 사이가 열려 있으면 그 틈에 폴링한 워커는 함수를 찾지 못한다.
BEGIN;

-- 기존 4-인자 시그니처를 없앤다. 새 함수는 기본값이 있는 6-인자라, 둘이
-- 같이 있으면 구버전 워커의 4-인자 호출이 모호해져(둘 다 후보) 실패한다.
DROP FUNCTION IF EXISTS public.fetch_pending_task(text, text, integer, text);

ALTER TABLE public.todolist ADD COLUMN IF NOT EXISTS lease_until timestamptz;
ALTER TABLE public.todolist ADD COLUMN IF NOT EXISTS claim_count integer NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_todolist_lease_reclaim
    ON public.todolist (status, draft_status, lease_until);
"""]
        for fn in FUNCS:
            text = extract_function(sql, fn)
            if not text:
                raise SystemExit("운영 중 적용에는 public.%s 가 필요하다" % fn)
            parts.append(text)
        parts.append("""
GRANT EXECUTE ON FUNCTION public.fetch_pending_task(text, text, integer, text, integer, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.renew_task_lease(uuid, text, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.release_task_lease(uuid, text) TO anon;

COMMIT;

-- PostgREST 는 함수 시그니처를 캐시해 둔다. 알려 주지 않으면 새 인자
-- (p_lease_seconds)를 "그런 함수 없다" 로 거절한다.
NOTIFY pgrst, 'reload schema';
""")
        out = "\n\n".join(p.strip() for p in parts if p.strip()) + "\n"
        if args.out == "-":
            sys.stdout.write(out)
        else:
            open(args.out, "w", encoding="utf-8").write(out)
        return 0

    parts = [PRELUDE, extract_table(sql, "todolist"), POSTLUDE]

    # lease 도입 전 init.sql 에는 없는 함수가 있다. 없으면 없는 대로 둔다 —
    # 그 상태로 벤치를 돌리는 것이 "되돌렸을 때" 의 모습이다.
    for fn in FUNCS:
        text = extract_function(sql, fn)
        if not text:
            parts.append("-- (init.sql 에 public.%s 가 없다)" % fn)
            print("경고: %s 를 찾지 못했다" % fn, file=sys.stderr)
            continue
        parts.append(text)

    # lease 컬럼은 migration.sql 쪽에 있다. 운영에서 마이그레이션으로 붙는 것과
    # 같은 문장을 쓴다(테이블 DDL 에만 있는 환경과 양쪽 모두를 커버한다).
    if args.no_lease_columns:
        parts.append("-- (lease 컬럼 없이 세운다)")
    else:
        parts.append("""
ALTER TABLE public.todolist ADD COLUMN IF NOT EXISTS lease_until timestamptz;
ALTER TABLE public.todolist ADD COLUMN IF NOT EXISTS claim_count integer NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_todolist_lease_reclaim
    ON public.todolist (status, draft_status, lease_until);
""")

    out = "\n\n".join(p.strip() for p in parts if p.strip()) + "\n"
    if args.out == "-":
        sys.stdout.write(out)
    else:
        open(args.out, "w", encoding="utf-8").write(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
