-- todolist 작업 점유(lease)의 RPC 쪽 계약을 고정한다.
--
-- 전부 하나의 트랜잭션에서 돌고 마지막에 ROLLBACK 한다 — 벤치 DB 에 흔적을
-- 남기지 않는다. 한 트랜잭션 안에서 now() 는 고정이므로, "만료" 는 시간을
-- 기다려서 만드는 게 아니라 lease_until 을 과거로 직접 적어서 만든다. 진짜
-- 시간이 걸리는 시나리오(워커를 죽이고 다른 워커가 집기까지)는 kind 벤치
-- (run_bench.sh)가 맡는다.
--
-- lease 로직을 되돌리면 1·3·7·10·13·14 가 깨진다: 함수가 없거나(renew/release),
-- 만료 회수가 일어나지 않거나, lease_until 이 채워지지 않는다.

\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION bench_new_todo(
  p_id      uuid,
  p_draft   draft_status DEFAULT NULL,
  p_lease   timestamptz  DEFAULT NULL,
  p_claims  integer      DEFAULT 0,
  p_consumer text        DEFAULT NULL
) RETURNS void LANGUAGE sql AS $fn$
  INSERT INTO public.todolist
    (id, tenant_id, status, agent_mode, agent_orch, activity_name,
     start_date, draft, draft_status, lease_until, claim_count, consumer)
  VALUES
    (p_id, 'bench', 'IN_PROGRESS', 'DRAFT', 'bench-agent', 'bench',
     now(), NULL, p_draft, p_lease, p_claims, p_consumer);
$fn$;

CREATE OR REPLACE FUNCTION bench_check(p_name text, p_ok boolean, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  -- `IS NOT TRUE` 여야 한다. `NOT p_ok` 로 쓰면 NULL 을 통과시킨다.
  --
  -- plpgsql 의 `SELECT * INTO r FROM f()` 는 f() 가 아무 행도 내지 않아도
  -- 오류를 내지 않고 r 의 필드를 전부 NULL 로 둔다. 그러면 `r.id = '...'` 이
  -- NULL 이 되고, AND 로 엮인 조건 전체가 NULL 이 되고, `NOT NULL` 도 NULL 이라
  -- IF 가 거짓으로 보고 지나간다 — **집히지 않았는데 통과한다.**
  -- 실제로 lease 회수 분기를 지워 놓고 돌렸을 때 3번이 통과했다. 테스트가
  -- 무엇도 지켜 주지 못하고 있었다.
  IF p_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL % (판정=%) %', p_name, coalesce(p_ok::text, 'NULL'), p_detail;
  END IF;
  RAISE NOTICE 'ok   %', p_name;
END $fn$;

-- 1) 집으면 lease 가 걸리고 claim_count 는 1 이 된다.
DO $t$
DECLARE r todolist;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000001');
  SELECT * INTO r FROM fetch_pending_task('bench-agent','w1',1,'dev',20,3);
  PERFORM bench_check('1 claim_sets_lease',
    r.id = '00000000-0000-0000-0000-000000000001'
    AND r.draft_status = 'STARTED' AND r.consumer = 'w1'
    AND r.lease_until IS NOT NULL AND r.lease_until > now()
    AND r.claim_count = 1,
    format('lease_until=%s claim_count=%s', r.lease_until, r.claim_count));
END $t$;

-- 2) p_lease_seconds 를 넘기지 않는 구버전 워커의 호출은 lease 없이 집는다.
--    (만료 개념이 없는 점유 = 예전 동작 그대로)
DO $t$
DECLARE r todolist;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000002');
  SELECT * INTO r FROM fetch_pending_task('bench-agent','old-worker',1,'dev');
  PERFORM bench_check('2 legacy_claim_leaves_lease_null',
    r.draft_status = 'STARTED' AND r.lease_until IS NULL,
    format('lease_until=%s', r.lease_until));
END $t$;

-- 3) 만료된 점유는 다른 워커가 다시 집는다. 이게 고아 STARTED 를 없애는 지점이다.
DO $t$
DECLARE r todolist;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000003',
                         'STARTED', now() - interval '1 second', 1, 'dead-worker');
  SELECT * INTO r FROM fetch_pending_task('bench-agent','w2',1,'dev',20,3);
  PERFORM bench_check('3 expired_started_is_reclaimed',
    r.id = '00000000-0000-0000-0000-000000000003'
    AND r.consumer = 'w2' AND r.claim_count = 2
    AND r.lease_until > now(),
    format('consumer=%s claim_count=%s', r.consumer, r.claim_count));
END $t$;

-- 4) 살아 있는 점유(만료 전)는 누구도 가져가지 못한다 = 동시 수행이 생기지 않는다.
DO $t$
DECLARE n integer;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000004',
                         'STARTED', now() + interval '1 hour', 1, 'busy-worker');
  SELECT count(*) INTO n FROM fetch_pending_task('bench-agent','w3',1,'dev',20,3)
   WHERE id = '00000000-0000-0000-0000-000000000004';
  PERFORM bench_check('4 live_lease_is_not_reclaimed', n = 0, format('claimed=%s', n));
END $t$;

-- 5) lease_until 이 비어 있는 STARTED 행은 회수하지 않는다.
--    마이그레이션 이전의 기존 행과 구버전 워커가 집은 행이 여기 해당한다.
--    연장할 주체가 없는 점유를 회수하면, 그 워커가 아직 일하는 중일 때
--    같은 작업이 두 번 수행된다.
DO $t$
DECLARE n integer;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000005',
                         'STARTED', NULL, 1, 'legacy-worker');
  SELECT count(*) INTO n FROM fetch_pending_task('bench-agent','w4',1,'dev',20,3)
   WHERE id = '00000000-0000-0000-0000-000000000005';
  PERFORM bench_check('5 null_lease_is_never_reclaimed', n = 0, format('claimed=%s', n));
END $t$;

-- 6) 사람 답변 대기(HUMAN_ASKED)는 lease 가 만료돼도 회수되지 않는다.
--    기다림은 장애가 아니다.
DO $t$
DECLARE n integer; st draft_status;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000006',
                         'HUMAN_ASKED', now() - interval '1 hour', 1, 'w-asked');
  SELECT count(*) INTO n FROM fetch_pending_task('bench-agent','w5',1,'dev',20,3)
   WHERE id = '00000000-0000-0000-0000-000000000006';
  SELECT draft_status INTO st FROM todolist
   WHERE id = '00000000-0000-0000-0000-000000000006';
  PERFORM bench_check('6 human_asked_is_not_reclaimed',
    n = 0 AND st = 'HUMAN_ASKED', format('claimed=%s status=%s', n, st));
END $t$;

-- 7) 재클레임 상한에 닿은 작업은 더 집히지 않고 FAILED 로 종결된다.
DO $t$
DECLARE n integer; st draft_status; lu timestamptz;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000007',
                         'STARTED', now() - interval '1 second', 3, 'dead-3');
  SELECT count(*) INTO n FROM fetch_pending_task('bench-agent','w6',1,'dev',20,3)
   WHERE id = '00000000-0000-0000-0000-000000000007';
  SELECT draft_status, lease_until INTO st, lu FROM todolist
   WHERE id = '00000000-0000-0000-0000-000000000007';
  PERFORM bench_check('7 claim_cap_terminates_as_failed',
    n = 0 AND st = 'FAILED' AND lu IS NULL,
    format('claimed=%s status=%s lease=%s', n, st, lu));
END $t$;

-- 8) FAILED 로 종결된 행은 다음 폴링에도 집히지 않는다(무한 재집행 금지).
DO $t$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM fetch_pending_task('bench-agent','w7',1,'dev',20,3)
   WHERE id = '00000000-0000-0000-0000-000000000007';
  PERFORM bench_check('8 failed_row_stays_failed', n = 0, format('claimed=%s', n));
END $t$;

-- 9) 피드백으로 되돌아온 정상 재집행은 claim_count 를 1 로 되돌린다.
--    그러지 않으면 피드백을 세 번 주고받은 작업이 멀쩡한데도 상한에 걸려 FAILED 가 된다.
DO $t$
DECLARE r todolist;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000009',
                         'FB_REQUESTED', NULL, 3, 'w-prev');
  SELECT * INTO r FROM fetch_pending_task('bench-agent','w8',1,'dev',20,3);
  PERFORM bench_check('9 fb_requested_resets_claim_count',
    r.id = '00000000-0000-0000-0000-000000000009' AND r.claim_count = 1,
    format('claim_count=%s', r.claim_count));
END $t$;

-- 10) 소유자의 heartbeat 는 lease 를 연장한다.
DO $t$
DECLARE res jsonb; before timestamptz; after_ timestamptz;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000010',
                         'STARTED', now() - interval '5 seconds', 1, 'owner');
  SELECT lease_until INTO before FROM todolist WHERE id = '00000000-0000-0000-0000-000000000010';
  res := renew_task_lease('00000000-0000-0000-0000-000000000010', 'owner', 20);
  SELECT lease_until INTO after_ FROM todolist WHERE id = '00000000-0000-0000-0000-000000000010';
  PERFORM bench_check('10 renew_by_owner_extends',
    (res->>'renewed')::boolean AND after_ > before AND after_ > now(),
    format('res=%s before=%s after=%s', res, before, after_));
END $t$;

-- 11) 회수된 뒤 뒤늦게 깨어난 워커의 heartbeat 는 거절되고, 그 사실을 알려 준다.
--     워커는 이걸 보고 하던 일을 버린다(펜싱).
DO $t$
DECLARE res jsonb; lu timestamptz;
BEGIN
  res := renew_task_lease('00000000-0000-0000-0000-000000000010', 'someone-else', 20);
  SELECT lease_until INTO lu FROM todolist WHERE id = '00000000-0000-0000-0000-000000000010';
  PERFORM bench_check('11 renew_by_stranger_is_not_owner',
    (res->>'renewed')::boolean IS FALSE
    AND res->>'reason' = 'not_owner'
    AND lu > now(),
    format('res=%s', res));
END $t$;

-- 12) 이미 끝난(또는 사람 대기로 넘어간) 작업의 heartbeat 는 실패하지만
--     "버려라" 가 아니다 — 이유를 구분해서 돌려준다.
DO $t$
DECLARE res jsonb;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000012',
                         'HUMAN_ASKED', now() + interval '1 minute', 1, 'owner');
  res := renew_task_lease('00000000-0000-0000-0000-000000000012', 'owner', 20);
  PERFORM bench_check('12 renew_on_non_started_reports_not_started',
    (res->>'renewed')::boolean IS FALSE
    AND res->>'reason' = 'not_started'
    AND res->>'draft_status' = 'HUMAN_ASKED',
    format('res=%s', res));
END $t$;

-- 13) 점유 해제는 남은 lease 를 즉시 비운다(= 다음 워커가 기다리지 않는다).
DO $t$
DECLARE ok boolean; lu timestamptz;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000013',
                         'STARTED', now() + interval '1 hour', 1, 'owner');
  ok := release_task_lease('00000000-0000-0000-0000-000000000013', 'owner');
  SELECT lease_until INTO lu FROM todolist WHERE id = '00000000-0000-0000-0000-000000000013';
  PERFORM bench_check('13 release_clears_lease', ok AND lu IS NULL, format('lease=%s', lu));
END $t$;

-- 14) 결과를 최종 저장하면 점유도 같이 끝난다.
DO $t$
DECLARE lu timestamptz; cs text; st draft_status;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000014',
                         'STARTED', now() + interval '1 hour', 1, 'owner');
  PERFORM save_task_result('00000000-0000-0000-0000-000000000014', '{"ok":true}'::jsonb, true);
  SELECT lease_until, consumer, draft_status INTO lu, cs, st
    FROM todolist WHERE id = '00000000-0000-0000-0000-000000000014';
  PERFORM bench_check('14 final_save_clears_lease',
    lu IS NULL AND cs IS NULL AND st = 'COMPLETED',
    format('lease=%s consumer=%s status=%s', lu, cs, st));
END $t$;

-- 15) 중간 저장은 점유를 유지한다(아직 일하는 중이다).
DO $t$
DECLARE lu timestamptz; cs text;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000015',
                         'STARTED', now() + interval '1 hour', 1, 'owner');
  PERFORM save_task_result('00000000-0000-0000-0000-000000000015', '{"partial":true}'::jsonb, false);
  SELECT lease_until, consumer INTO lu, cs
    FROM todolist WHERE id = '00000000-0000-0000-0000-000000000015';
  PERFORM bench_check('15 partial_save_keeps_lease',
    lu IS NOT NULL AND cs = 'owner', format('lease=%s consumer=%s', lu, cs));
END $t$;

-- 16) 한 번의 폴링에서 같은 행이 두 워커에게 나가지 않는다.
--     (같은 세션에서 연달아 호출해도 두 번째는 빈손이어야 한다)
DO $t$
DECLARE a integer; b integer;
BEGIN
  PERFORM bench_new_todo('00000000-0000-0000-0000-000000000016');
  SELECT count(*) INTO a FROM fetch_pending_task('bench-agent','wA',1,'dev',20,3)
   WHERE id = '00000000-0000-0000-0000-000000000016';
  SELECT count(*) INTO b FROM fetch_pending_task('bench-agent','wB',1,'dev',20,3)
   WHERE id = '00000000-0000-0000-0000-000000000016';
  PERFORM bench_check('16 no_double_claim_in_one_pass', a = 1 AND b = 0,
    format('a=%s b=%s', a, b));
END $t$;

ROLLBACK;
