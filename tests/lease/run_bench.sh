#!/usr/bin/env bash
# todolist 작업 점유(lease)를 로컬 kind 클러스터에서 실측한다.
#
# 쓰는 법:
#   ./run_bench.sh up                 # 클러스터 + 스택 기동 (lease 적용본)
#   ./run_bench.sh sqltest            # RPC 계약 테스트(test_lease_rpc.sql)
#   ./run_bench.sh baseline           # lease 도입 전 RPC 로 고아 STARTED 재현
#   ./run_bench.sh kill               # 워커를 kill -9 → 재클레임까지의 실측
#   ./run_bench.sh alive              # 살아 있는 동안 넘어가지 않는지
#   ./run_bench.sh race N             # 워커 여러 개가 동시 폴링 → 중복 클레임
#   ./run_bench.sh cap                # 재시도 상한 → FAILED 종결
#   ./run_bench.sh human              # 사람 답변 대기는 회수되지 않는지
#   ./run_bench.sh fence              # 회수당한 워커가 하던 일을 버리는지
#   ./run_bench.sh mixed              # 구버전(lease 모르는) 워커가 섞여 돌 때
#   ./run_bench.sh migrate            # 워커가 도는 중에 마이그레이션 적용
#   ./run_bench.sh blocking           # 익스큐터가 루프를 붙잡아도 연장이 나가는지
#   ./run_bench.sh error              # 작업 오류 → 실패로 남고 점유가 풀리는지
#   ./run_bench.sh long               # 긴 작업(기본 600s)에서 연장이 끊기지 않는지
#   ./run_bench.sh cleanup            # 벤치가 만든 행만 삭제
#   ./run_bench.sh down               # 클러스터 삭제
#
# 대상 DB 는 TARGET 으로 고른다.
#   TARGET=bench     (기본) 네임스페이스 안의 최소 Postgres
#   TARGET=supabase  호스트의 로컬 Supabase(process-gpt-vue3) — 실제 스키마와
#                    트리거, Kong/PostgREST 를 그대로 탄다. 이때 벤치가 만드는
#                    행은 agent_orch='lease-bench' 로 표시되고 삭제도 그 범위다.
#
# 설계 메모: 점유 판정은 전부 RPC 안에서 일어나야 하므로, 이 스크립트는 워커에게
# 아무것도 묻지 않는다. 죽은 워커는 대답하지 못한다. 판정의 근거는 DB 의 행 상태와
# 워커가 남긴 로그(BENCH ...)뿐이다.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# todolist 스키마와 fetch_pending_task RPC 가 사는 곳(이 저장소).
INIT_SQL="${INIT_SQL:-$REPO/volumes/db/init.sql}"
# 워커로 쓸 SDK. 옆에 나란히 받아 두었다고 가정하고, 없으면 SDK_DIR 로 받는다.
SDK_DIR="${SDK_DIR:-$(cd "$REPO/../../../process-gpt-agent-sdk" 2>/dev/null && pwd || true)}"
if [[ -z "${SDK_DIR}" || ! -d "${SDK_DIR}/processgpt_agent_sdk" ]]; then
  echo "process-gpt-agent-sdk 를 찾지 못했다. SDK_DIR=<경로> 로 알려 달라." >&2
  exit 2
fi

CLUSTER="${CLUSTER:-bench-pgpt}"
NS="${NS:-lease-bench}"
KCTX="kind-${CLUSTER}"
K="kubectl --context ${KCTX} -n ${NS}"
STAGE="${STAGE:-${TMPDIR:-/tmp}/lease-bench-stage}"

# lease 설정(워커에 주는 값과 같아야 한다 — manifests.yaml 참고)
LEASE_SECONDS="${LEASE_SECONDS:-20}"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-5}"
MAX_CLAIMS="${MAX_CLAIMS:-3}"
WORK_SECONDS="${WORK_SECONDS:-60}"

BENCH_JWT=""     # up/baseline 에서 채운다
owner_line=""    # wait_for_owner 의 결과를 받는다

# ---------------------------------------------------------------- 대상 DB
#
# TARGET=bench     : 네임스페이스 안에 띄운 최소 Postgres(기본).
#                    테이블이 todolist 와 tenants 둘뿐이라 점유 수명만 본다.
# TARGET=supabase  : 호스트에서 돌고 있는 로컬 Supabase(process-gpt-vue3).
#                    실제 스키마 66 테이블 + 실제 트리거 9 개 + Kong/PostgREST 를
#                    그대로 탄다. 그래서 컨텍스트 조립과 events 쓰기까지 진짜로
#                    돈다 — 벤치 DB 로는 볼 수 없던 구간이다.
#
# **파괴적 조작의 범위가 둘에서 다르다.** 벤치 DB 는 통째로 비워도 되지만,
# 로컬 Supabase 에는 내 개발 데이터(수백 행)가 들어 있다. 그래서 이 스크립트가
# 만들고 지우는 행은 전부 SB_AGENT_ORCH 로 표시하고, 삭제는 그 범위로만 한다.
# `DELETE FROM todolist` 를 조건 없이 돌리는 경로는 supabase 타깃에 없어야 한다.
TARGET="${TARGET:-bench}"

# 로컬 Supabase 접속(= 운영과 같은 경로: supabase-py → Kong → PostgREST → RPC).
# 파드에서 호스트로 나가는 이름은 kind 노드가 풀어 준다.
SB_DB_CONTAINER="${SB_DB_CONTAINER:-supabase_db_process-gpt-vue3}"
SB_URL_FOR_PODS="${SB_URL_FOR_PODS:-http://host.docker.internal:54321}"
SB_SERVICE_KEY="${SB_SERVICE_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU}"
# 기존 행과 섞이지 않게 전용 값을 쓴다. 실제 DB 의 agent_orch 는
# deepagents / crewai-action / visionparse / pdf2bpmn / (null) 뿐이다.
SB_AGENT_ORCH="${SB_AGENT_ORCH:-lease-bench}"
SB_TENANT="${SB_TENANT:-localhost}"

# 워커가 집을 agent_orch. 타깃에 따라 다르다.
target_agent_orch() {
  [[ "$TARGET" == "supabase" ]] && echo "$SB_AGENT_ORCH" || echo "bench-agent"
}

# 집계 질의의 범위. supabase 에는 내 개발 행이 섞여 있으므로 벤치 행만 센다.
# 이걸 빼먹으면 "전부 완료" 판정이 남의 행까지 세어 영원히 끝나지 않는다.
todo_scope() {
  [[ "$TARGET" == "supabase" ]] && echo "agent_orch = '$SB_AGENT_ORCH'" || echo "TRUE"
}

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }

# ---------------------------------------------------------------- 공통 유틸
# psql 은 타깃에 따라 다른 곳으로 간다.
#  bench    → 네임스페이스 안의 Postgres 파드
#  supabase → 호스트 도커의 Supabase Postgres 컨테이너
psql_() {
  if [[ "$TARGET" == "supabase" ]]; then
    docker exec "$SB_DB_CONTAINER" psql -U postgres -d postgres -qAt -c "$1"
  else
    $K exec deploy/postgres -- psql -U postgres -d bench -qAt -c "$1"
  fi
}
psql_file() {
  if [[ "$TARGET" == "supabase" ]]; then
    docker exec -i "$SB_DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < "$1"
  else
    $K exec -i deploy/postgres -- psql -U postgres -d bench -v ON_ERROR_STOP=1 -f - < "$1"
  fi
}

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

anon_jwt() {
  python3 - "$1" <<'PY'
import base64, hashlib, hmac, json, sys
secret = sys.argv[1].encode()
def b64(raw): return base64.urlsafe_b64encode(raw).rstrip(b"=")
head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
# 만료를 멀리 둔다. 벤치가 도는 동안 토큰이 만료되면 폴링 실패를 lease 문제로
# 잘못 읽는다.
body = b64(json.dumps({"role": "anon", "exp": 4102444800}, separators=(",", ":")).encode())
sig = b64(hmac.new(secret, head + b"." + body, hashlib.sha256).digest())
print((head + b"." + body + b"." + sig).decode())
PY
}

new_todo() {
  # $1=uuid $2=draft_status(옵션) $3=claim_count(옵션)
  # claim_count 는 따로 UPDATE 한다 — 기준선(lease 도입 전) 스키마에는 그 컬럼이 없다.
  local id="$1" st="${2:-}" claims="${3:-0}"
  local st_sql="NULL"
  [[ -n "$st" ]] && st_sql="'$st'"
  local tenant orch proc_inst
  if [[ "$TARGET" == "supabase" ]]; then
    tenant="$SB_TENANT"; orch="$SB_AGENT_ORCH"
    # 실제 스키마에는 트리거가 걸려 있다. sync_task_execution_on_insert 가
    # task_execution_properties 에 행을 넣는데 거기 proc_inst_id 가 NOT NULL 이다.
    # 벤치 DB(테이블 둘)에서는 없던 제약이고, 비워 두면 INSERT 자체가 실패한다.
    # 정리할 때 알아보도록 접두어를 붙인다.
    proc_inst="lease-bench-${id}"
  else
    tenant="bench"; orch="bench-agent"; proc_inst="bench"
  fi
  psql_ "INSERT INTO todolist (id, tenant_id, status, agent_mode, agent_orch, activity_name,
           proc_inst_id, proc_def_id, activity_id, start_date, draft_status)
         VALUES ('$id', '$tenant', 'IN_PROGRESS', 'DRAFT', '$orch', 'lease-bench',
           '$proc_inst', 'lease-bench', 'lease-bench-act', now(), $st_sql);" >/dev/null
  if [[ "$claims" != "0" ]]; then
    psql_ "UPDATE todolist SET claim_count=$claims WHERE id='$id';" >/dev/null
  fi
}

# 벤치가 만든 행만 지운다.
#
# supabase 타깃에서 조건 없는 DELETE 는 내 개발 데이터를 지운다. 범위를
# agent_orch 로 못박는다 — 이 스크립트가 만드는 행에만 그 값이 들어간다.
clear_todos() {
  if [[ "$TARGET" == "supabase" ]]; then
    # todolist 뿐 아니라 트리거가 파생시킨 행도 같이 치운다. 남겨 두면 내
    # 개발 DB 에 벤치 찌꺼기가 쌓인다.
    #   sync_task_execution_on_insert → task_execution_properties
    #   handle_todolist_change        → notifications
    psql_ "DELETE FROM task_execution_properties WHERE proc_inst_id LIKE 'lease-bench-%';" >/dev/null
    psql_ "DELETE FROM notifications WHERE id IN (
             SELECT n.id FROM notifications n
              WHERE n.title LIKE '%lease-bench%' OR n.url LIKE '%lease-bench%');" >/dev/null 2>&1 || true
    psql_ "DELETE FROM todolist WHERE agent_orch = '$SB_AGENT_ORCH';" >/dev/null
  else
    psql_ "DELETE FROM todolist;" >/dev/null
  fi
}

# 행의 현재 점유자. 없으면 빈 문자열.
owner_of() { psql_ "SELECT coalesce(consumer,'') FROM todolist WHERE id='$1';"; }
status_of() { psql_ "SELECT coalesce(draft_status::text,'(null)') FROM todolist WHERE id='$1';"; }
claims_of() { psql_ "SELECT claim_count FROM todolist WHERE id='$1';"; }

# $1=uuid, $2=제외할 consumer(빈 문자열이면 아무나), $3=제한 시간(초)
# 점유자가 생기면 "consumer 경과초" 를 찍고 0, 시간이 다하면 1.
#
# 호출할 때 `read ... < <(wait_for_owner ...)` 를 쓰면 안 된다 — read 의 종료
# 상태가 돌아와서 시간 초과가 묻히고, 그 뒤 코드가 경과초를 파드 이름으로 쓴다.
# `out="$(wait_for_owner ...)" || 실패처리` 로 받는다.
wait_for_owner() {
  local id="$1" exclude="$2" limit="$3" start owner elapsed
  start="$(now_ms)"
  while :; do
    owner="$(owner_of "$id" || true)"
    elapsed="$(python3 -c "print(($(now_ms)-$start)/1000)")"
    if [[ -n "$owner" && "$owner" != "$exclude" ]]; then
      echo "$owner $elapsed"
      return 0
    fi
    if (( $(python3 -c "print(1 if $elapsed > $limit else 0)") )); then
      echo " $elapsed"
      return 1
    fi
    sleep 0.5
  done
}

worker_pods() { $K get pods -l app=worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }

# BENCH 로그를 모든 워커(재시작한 컨테이너의 이전 로그까지)에서 긁는다.
bench_logs() {
  local pod
  for pod in $(worker_pods); do
    $K logs "$pod" --timestamps 2>/dev/null | grep -F 'BENCH ' || true
    $K logs "$pod" --previous --timestamps 2>/dev/null | grep -F 'BENCH ' || true
  done
}

# 워커 프로세스가 정말 죽었는지는 컨테이너 재시작 횟수로 확인한다.
# 죽은 워커에게 "너 죽었니" 를 물어볼 수는 없다.
restarts_of() { $K get pod "$1" -o jsonpath='{.status.containerStatuses[0].restartCount}'; }

# $1=pod $2=재시작 횟수(죽이기 전) $3=제한 시간(초)
assert_killed() {
  local pod="$1" before="$2" limit="${3:-60}" t=0 cur
  while (( t < limit )); do
    cur="$(restarts_of "$pod" 2>/dev/null || echo "$before")"
    if [[ -n "$cur" && "$cur" -gt "$before" ]]; then
      info "워커가 죽었다(컨테이너 재시작 ${before}→${cur})"
      return 0
    fi
    sleep 1; t=$((t+1))
  done
  echo "실패: kill -9 가 먹지 않았다(재시작 횟수 ${before} 그대로) — 측정이 무의미하다"
  return 1
}

# PostgREST 는 기동 시점에 스키마 캐시를 읽는다. Postgres 를 다시 띄우면 그
# 캐시가 끊겨 PGRST002("Could not query the database for the schema cache")로
# 모든 RPC 가 실패한다 — 워커 쪽에서는 폴링 실패로 보여서 lease 문제와
# 헷갈린다. 그래서 DB 를 새로 띄울 때마다 API 도 같이 다시 띄우고, RPC 가
# 실제로 답할 때까지 기다린다.
api_probe() {
  # 토큰은 환경변수로 넘긴다. 셸 두 겹(bash → sh)을 지나는 동안 JSON 의
  # 따옴표가 상하지 않게 바깥을 작은따옴표로 고정한다.
  # 존재하지 않는 agent_orch 로 부르므로 아무 작업도 집지 않는다.
  $K exec deploy/pgrest -c path-fix -- env TOKEN="$BENCH_JWT" sh -c '
    wget -q -O- --header="Authorization: Bearer $TOKEN" \
         --header="Content-Type: application/json" \
         --post-data="{\"p_agent_orch\":\"__probe__\",\"p_consumer\":\"probe\",\"p_limit\":1,\"p_env\":\"dev\"}" \
         http://127.0.0.1:8080/rest/v1/rpc/fetch_pending_task' 2>/dev/null
}

wait_api() { wait_api_for 120; }

# $1=제한 시간(초) $2="quiet" 면 실패를 보고하지 않는다(한 번 더 시도할 때 쓴다 —
# 중간 단계의 "실패" 가 기록에 남으면 전체가 실패한 것처럼 읽힌다)
wait_api_for() {
  local limit="$1" quiet="${2:-}" t=0 out=""
  while (( t < limit )); do
    # `out="$(api_probe)"` 를 맨몸으로 쓰면 안 된다 — set -e 아래에서 대입문의
    # 종료 상태는 명령 치환의 상태이고, 첫 시도가 실패하는 순간 스크립트가
    # 여기서 죽는다(재시도 루프가 돌지 못한다). if 가 그것을 막아 준다.
    if out="$(api_probe 2>&1)"; then
      info "API 응답 확인 (${t}s)"
      return 0
    fi
    sleep 2; t=$((t+2))
  done
  if [[ "$quiet" == "quiet" ]]; then
    return 1
  fi
  # 왜 못 붙었는지를 남긴다. 이게 없으면 "폴링이 안 된다" 를 lease 문제로 읽는다.
  echo "실패: PostgREST 가 ${t}s 안에 RPC 에 답하지 못했다"
  echo "      마지막 응답: ${out:-(없음)}"
  $K logs deploy/pgrest -c postgrest --tail=5 2>&1 | sed 's/^/      /'
  return 1
}

# 파드가 Ready(pg_isready)라는 것과 스키마가 다 올라왔다는 것은 다르다.
# initdb 스크립트가 도는 중에도 pg_isready 는 통과한다.
wait_db() {
  local t=0
  while (( t < 180 )); do
    if psql_ "SELECT count(*) FROM public.todolist;" >/dev/null 2>&1; then
      info "DB 응답 확인 (${t}s)"
      return 0
    fi
    sleep 2; t=$((t+2))
  done
  echo "실패: Postgres 가 ${t}s 안에 스키마를 올리지 못했다"
  $K logs deploy/postgres --tail=10 2>&1 | sed 's/^/      /'
  return 1
}

# 서비스 이름으로 DB 에 닿는지 본다. 위의 wait_db 는 파드에 직접 exec 하므로
# DNS 와 엔드포인트가 새 파드를 가리키는지는 확인하지 못한다. PostgREST 가
# 사라진 파드의 주소로 첫 연결을 시도하면 지수 백오프(최대 ~32초)로 물러나
# 2분 넘게 503 을 돌려준다 — 실제로 그렇게 한 번 속았다.
wait_db_dns() {
  local t=0
  while (( t < 120 )); do
    if $K exec deploy/pgrest -c path-fix -- nc -z postgres 5432 >/dev/null 2>&1; then
      info "서비스 이름으로 DB 에 닿는다 (${t}s)"
      return 0
    fi
    sleep 2; t=$((t+2))
  done
  echo "실패: postgres 서비스에 닿지 못했다"
  return 1
}

restart_db_and_api() {
  # initdb 는 빈 데이터디렉터리에서만 돌기 때문에, 스키마를 바꿨으면 DB 를
  # 새로 띄워야 한다.
  $K rollout restart deploy/postgres >/dev/null
  $K rollout status deploy/postgres --timeout=180s
  wait_db
  wait_db_dns
  $K rollout restart deploy/pgrest >/dev/null
  $K rollout status deploy/pgrest --timeout=180s
  # 그래도 백오프에 걸려 있으면 한 번 더 깨운다. 기다리는 것보다 빠르다.
  if ! wait_api_for 60 quiet; then
    info "API 가 60s 안에 답하지 않았다 — PostgREST 를 한 번 더 깨운다(백오프 해제)"
    $K rollout restart deploy/pgrest >/dev/null
    $K rollout status deploy/pgrest --timeout=180s
    wait_api
  fi
}

# ---------------------------------------------------------------- 기동/정리
build_image() {
  say "워커 이미지 빌드"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  # SDK 소스를 그대로 넣는다(설치본이 아니라 지금 고친 코드로 돈다).
  rsync -a --exclude .venv --exclude .git --exclude '*.egg-info' \
        --exclude '__pycache__' "$SDK_DIR/" "$STAGE/sdk/"
  cp "$HERE/bench/worker.py" "$HERE/bench/Dockerfile" "$STAGE/"
  docker build -q -t bench-worker:dev "$STAGE" >/dev/null
  kind load docker-image bench-worker:dev --name "$CLUSTER"
  info "bench-worker:dev 적재 완료"
}

apply_schema() {
  say "벤치 스키마 적용 (init.sql 에서 추출)"
  python3 "$HERE/extract_schema.py" "$INIT_SQL" "$@" -o "$STAGE/01-schema.sql"
  cp "$HERE/bench/roles.sql" "$STAGE/02-roles.sql"
  $K delete configmap bench-schema --ignore-not-found >/dev/null
  $K create configmap bench-schema \
      --from-file="$STAGE/01-schema.sql" --from-file="$STAGE/02-roles.sql" >/dev/null
  info "$(grep -c 'CREATE OR REPLACE FUNCTION' "$STAGE/01-schema.sql") 개 함수 포함"
}

up() {
  if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    say "kind 클러스터 생성: $CLUSTER"
    kind create cluster --name "$CLUSTER" --wait 180s
  fi
  kubectl --context "$KCTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$KCTX" apply -f - >/dev/null
  mkdir -p "$STAGE"
  build_image
  apply_schema "$@"

  say "스택 기동"
  BENCH_JWT="$(anon_jwt 'bench-jwt-secret-0123456789-abcdefgh')"
  $K delete secret bench-anon-key --ignore-not-found >/dev/null
  $K create secret generic bench-anon-key --from-literal=key="$BENCH_JWT" >/dev/null
  # 워커는 지우고 다시 세운다. supabase 타깃으로 돌린 뒤에는 SUPABASE_KEY 가
  # 리터럴 값으로 박혀 있는데, 매니페스트는 그 자리에 secretKeyRef 를 선언한다.
  # apply 는 둘을 합치려다 "value 와 valueFrom 을 함께 쓸 수 없다" 로 거절한다.
  $K delete deploy/worker --ignore-not-found >/dev/null
  $K apply -f "$HERE/bench/manifests.yaml" >/dev/null
  restart_db_and_api
  $K rollout restart deploy/worker >/dev/null
  $K rollout status deploy/worker --timeout=180s
  info "워커: $(worker_pods | tr '\n' ' ')"
}

down() {
  say "클러스터 삭제: $CLUSTER"
  kind delete cluster --name "$CLUSTER"
}

scale_workers() {
  $K scale deploy/worker --replicas="$1" >/dev/null
  $K rollout status deploy/worker --timeout=180s >/dev/null
  info "워커 $1 개"
}

set_worker_mode() {
  $K set env deploy/worker WORKER_MODE="$1" >/dev/null
  $K rollout status deploy/worker --timeout=180s >/dev/null
}

# 시나리오마다 워커를 처음부터 세운다: 비우고 → 설정을 박고 → 올린다.
#
# 이전 시나리오가 남긴 설정을 "원래대로 되돌리기" 에 기대지 않는다. 한 번
# 그렇게 하다가 WORK_SECONDS 가 3 초로 남은 채 펜싱 시나리오가 돌아, 작업이
# 회수를 시험해 보기도 전에 끝나 버렸다. 레플리카가 0 인 동안 템플릿을 바꾸므로
# 올라오는 파드는 반드시 이 설정으로 뜬다.
#
# 워커가 어느 DB 를 보는지, 어떤 익스큐터로 도는지를 템플릿에 박는다.
# 레플리카가 0 인 동안 부른다 — 올라오는 파드가 반드시 이 설정으로 뜨게.
#
# $1=EXEC_MODE(기본 sleep)
configure_target_env() {
  local exec_mode="${1:-sleep}"
  if [[ "$TARGET" == "supabase" ]]; then
    # 실제 스키마가 있으므로 컨텍스트 조립을 진짜로 돌린다(STUB_CONTEXT=0).
    # 그 조회 시간도 점유 아래에서 일어나는 일이라 검증 대상이다.
    $K set env deploy/worker \
        SUPABASE_URL="$SB_URL_FOR_PODS" \
        SUPABASE_KEY="$SB_SERVICE_KEY" \
        AGENT_ORCH="$SB_AGENT_ORCH" \
        STUB_CONTEXT=0 \
        EXEC_MODE="$exec_mode" >/dev/null
    # secretKeyRef 로 박혀 있던 SUPABASE_KEY 를 위 값으로 덮으려면 참조를 끊어야 한다.
    $K set env deploy/worker --keys=SUPABASE_KEY --from=secret/bench-anon-key --remove >/dev/null 2>&1 || true
  else
    $K set env deploy/worker \
        SUPABASE_URL="http://pgrest:8080" \
        AGENT_ORCH="bench-agent" \
        STUB_CONTEXT=1 \
        EXEC_MODE="$exec_mode" >/dev/null
  fi
}

# $1=레플리카 수 $2=WORK_SECONDS $3=WORKER_MODE(기본 sdk) $4=EXEC_MODE(기본 sleep)
prepare_workers() {
  local replicas="$1" work="$2" mode="${3:-sdk}" exec_mode="${4:-sleep}"
  quiesce
  $K set env deploy/worker WORK_SECONDS="$work" WORKER_MODE="$mode" >/dev/null
  configure_target_env "$exec_mode"
  scale_workers "$replicas"
  info "작업 수행시간 ${work}s, 모드 ${mode}, 익스큐터 ${exec_mode}, 대상 ${TARGET}"
  (( replicas > 0 )) && wait_workers_polling "$replicas"
  return 0
}

# 파드가 Ready 라는 것은 폴링을 시작했다는 뜻이 아니다. 이 이미지는 import 에
# 10~20초가 걸리고(litellm 이 모델 단가표를 받으려다 실패하고 포기하는 시간이
# 포함된다) 그 전에는 아무것도 집지 않는다. 그걸 기다리지 않고 작업을 넣으면
# 첫 클레임이 늦어, 측정 시간이 "워커 기동 시간 + 폴링 간격" 으로 오염된다.
wait_workers_polling() {
  local want="$1" ready=0 pod log_text
  local start; start="$(now_ms)"
  local elapsed=0
  while (( elapsed < 240 )); do
    ready=0
    for pod in $(worker_pods); do
      # 로그를 변수로 먼저 받는다. `kubectl logs | grep -q` 로 쓰면 안 된다 —
      # grep -q 는 첫 매치에서 바로 끝나고, 그러면 아직 쓰고 있던 kubectl 이
      # SIGPIPE 로 죽는다. 이 스크립트는 pipefail 이므로 **매치했는데도**
      # 파이프라인이 실패로 집계된다. 로그가 길수록 걸린다(litellm 이 기동에
      # 수십 줄을 찍는다). 실제로 이것 때문에 멀쩡한 워커를 "폴링 안 함" 으로
      # 읽고 시나리오가 실패했다.
      log_text="$($K logs "$pod" --tail=400 2>/dev/null || true)"
      if grep -qE '폴링 시작|ProcessGPT Agent Server START|mode=legacy' <<<"$log_text"; then
        ready=$((ready+1))
      fi
    done
    elapsed=$(( ($(now_ms) - start) / 1000 ))
    if (( ready >= want )); then
      info "워커 ${ready}개가 폴링을 시작했다 (${elapsed}s)"
      return 0
    fi
    sleep 2
  done
  echo "실패: ${want}개 중 ${ready}개만 ${elapsed}s 안에 폴링을 시작했다"
  $K get pods -l app=worker 2>&1 | sed 's/^/      /'
  return 1
}

quiesce() {
  # 진행 중인 작업이 다음 시나리오를 오염시키지 않게 비운다.
  #
  # 파드가 **완전히 사라질 때까지** 기다린다. `rollout status` 는 종료 중인
  # 파드를 기다려 주지 않는데, 그 파드도 죽기 전까지 폴링을 계속한다. 그것이
  # 다음 시나리오의 작업을 집고 곧 종료되면, 올바른 lease 회수가 일어나면서도
  # "살아 있는 워커의 작업이 넘어갔다" 로 잘못 읽힌다.
  scale_workers 0
  local t=0
  while [[ -n "$(worker_pods)" ]]; do
    sleep 1; t=$((t+1))
    (( t > 120 )) && { echo "실패: 워커 파드가 사라지지 않는다"; return 1; }
  done
  clear_todos
}

# ---------------------------------------------------------------- 시나리오
sqltest() {
  say "RPC 계약 테스트: test_lease_rpc.sql"
  psql_file "$HERE/test_lease_rpc.sql" 2>&1 | grep -E '^(NOTICE|ERROR|psql)' || true
}

scenario_kill() {
  say "시나리오 1 — 작업을 집은 워커를 kill -9 하면 다른 워커가 이어받는가"
  prepare_workers 3 "$WORK_SECONDS"
  local id="aaaa0001-0000-0000-0000-000000000001"
  new_todo "$id"

  local first owner_elapsed
  owner_line="$(wait_for_owner "$id" "" 120)" || {
    echo "실패: 아무도 작업을 집지 않았다"; return 1; }
  read -r first owner_elapsed <<<"$owner_line"
  info "최초 점유자: $first (${owner_elapsed}s 만에 집었다)"

  # 점유자 파드를 찾아 그 안의 워커 프로세스를 SIGKILL 한다.
  # (consumer 는 "hostname:pid" 이고 hostname 은 파드 이름이다)
  local pod="${first%%:*}" pid="${first##*:}"
  local restarts_before; restarts_before="$(restarts_of "$pod")"
  info "kill -9 ${pid} in ${pod}"
  local kill_at; kill_at="$(now_ms)"
  $K exec "$pod" -- sh -c "kill -9 $pid" || true
  assert_killed "$pod" "$restarts_before" || return 1

  local second reclaim_elapsed
  owner_line="$(wait_for_owner "$id" "$first" 120)" || {
    echo "실패: ${reclaim_elapsed}s 동안 재클레임이 없었다(고아 STARTED)"; return 1; }
  read -r second reclaim_elapsed <<<"$owner_line"
  info "재클레임: $second"
  info "kill → 재클레임 실측: $(python3 -c "print(round(($(now_ms)-$kill_at)/1000,1))")s"
  info "lease=${LEASE_SECONDS}s heartbeat=${HEARTBEAT_SECONDS}s 폴링간격=10s → 이론 상한 $((LEASE_SECONDS+10))s"
  info "claim_count=$(claims_of "$id")"

  # 이어받은 워커가 끝까지 수행하는지 본다.
  local waited=0
  while [[ "$(status_of "$id")" != "COMPLETED" ]]; do
    sleep 2; waited=$((waited+2))
    if (( waited > WORK_SECONDS + 60 )); then
      echo "실패: 이어받은 작업이 끝나지 않았다 (status=$(status_of "$id"))"; return 1
    fi
  done
  info "이어받은 워커가 수행 완료 (kill 이후 ${waited}s 안쪽)"
  say "결과: 통과 — 죽은 워커의 작업이 회수되어 완료되었다"
}

scenario_alive() {
  say "시나리오 2 — 워커가 살아 있는 동안 같은 작업이 넘어가지 않는가"
  prepare_workers 3 "$WORK_SECONDS"
  local id="aaaa0002-0000-0000-0000-000000000002"
  new_todo "$id"

  local first _e
  owner_line="$(wait_for_owner "$id" "" 120)" || {
    echo "실패: 아무도 집지 않았다"; return 1; }
  read -r first _e <<<"$owner_line"
  info "점유자: $first"

  # lease 길이의 3배를 지켜본다. 연장이 끊기면 이 사이에 반드시 넘어간다.
  local watch=$((LEASE_SECONDS * 3)) t=0 changed=0
  while (( t < watch )); do
    sleep 2; t=$((t+2))
    local cur; cur="$(owner_of "$id")"
    if [[ -n "$cur" && "$cur" != "$first" ]]; then
      echo "실패: ${t}s 지점에서 점유자가 $cur 로 바뀌었다"; changed=1; break
    fi
  done
  (( changed )) && return 1
  info "${watch}s 동안 점유자 불변"

  # 같은 작업을 두 워커가 수행한 흔적이 없어야 한다.
  local starts
  starts="$(bench_logs | grep -c "BENCH start todo=$id" || true)"
  info "이 작업의 start 로그: ${starts}건"
  [[ "$starts" == "1" ]] || { echo "실패: 동시 수행 ${starts}건"; return 1; }
  say "결과: 통과 — 연장이 되는 동안 회수되지 않았고 동시 수행 0건"
}

scenario_race() {
  local n="${1:-6}" tasks="${2:-12}"
  say "시나리오 3 — 워커 ${n}개가 동시에 폴링할 때 중복 클레임"
  # 작업이 금방 끝나야 여러 워커가 연달아 집는 상황이 많이 만들어진다.
  prepare_workers "$n" 3

  local i
  for ((i = 1; i <= tasks; i++)); do
    new_todo "$(printf 'aaaa0003-0000-0000-0000-%012d' "$i")"
  done
  info "${tasks}개 투입, 완료 대기"

  local t=0
  while :; do
    local done_n; done_n="$(psql_ "SELECT count(*) FROM todolist WHERE draft_status='COMPLETED' AND $(todo_scope);")"
    [[ "$done_n" == "$tasks" ]] && break
    sleep 2; t=$((t+2))
    if (( t > 240 )); then
      echo "실패: ${done_n}/${tasks} 만 끝났다"; return 1
    fi
  done
  info "전부 완료 (${t}s)"

  # 중복 클레임의 증거는 "같은 todo 에 start 로그가 둘 이상" 이다.
  local dup
  dup="$(bench_logs | grep -oE 'BENCH start todo=[^ ]+' | sort | uniq -c | awk '$1>1' || true)"
  if [[ -n "$dup" ]]; then
    echo "실패: 중복 클레임"; echo "$dup"; return 1
  fi
  info "중복 클레임 0건 (start 로그 $(bench_logs | grep -c 'BENCH start' || true)건 / ${tasks}작업)"
  local maxc; maxc="$(psql_ "SELECT max(claim_count) FROM todolist WHERE $(todo_scope);")"
  info "claim_count 최댓값: $maxc (1이면 회수가 한 번도 필요하지 않았다는 뜻)"
  say "결과: 통과 — 중복 클레임 0건"
}

scenario_cap() {
  say "시나리오 4 — 재시도 상한에 닿은 작업"
  prepare_workers 1 "$WORK_SECONDS"
  local id="aaaa0004-0000-0000-0000-000000000004"
  # 상한만큼 이미 점유된 뒤 만료된 모양으로 넣는다.
  new_todo "$id" "STARTED" "$MAX_CLAIMS"
  psql_ "UPDATE todolist SET lease_until = now() - interval '1 second', consumer='dead-worker' WHERE id='$id';" >/dev/null
  info "claim_count=$MAX_CLAIMS, lease 만료 상태로 투입 (상한=$MAX_CLAIMS)"

  # 폴링을 몇 번 돌 시간을 준다.
  sleep 25
  local st owner
  st="$(status_of "$id")"; owner="$(owner_of "$id")"
  info "status=$st consumer=$owner claim_count=$(claims_of "$id")"
  [[ "$st" == "FAILED" ]] || { echo "실패: 상한 초과인데 $st 로 남았다"; return 1; }
  local starts; starts="$(bench_logs | grep -c "BENCH start todo=$id" || true)"
  [[ "$starts" == "0" ]] || { echo "실패: 상한 초과인데 ${starts}번 더 집혔다"; return 1; }
  info "다시 집히지 않았고 FAILED 로 식별된다"
  say "결과: 통과 — 상한 초과는 FAILED 로 종결되고 재집행되지 않는다"
}

scenario_human() {
  say "시나리오 5 — 사람 답변 대기 작업은 lease 만료로 회수되지 않는가"
  prepare_workers 2 "$WORK_SECONDS"
  local id="aaaa0005-0000-0000-0000-000000000005"
  new_todo "$id" "HUMAN_ASKED" 1
  psql_ "UPDATE todolist SET lease_until = now() - interval '1 hour', consumer='asker' WHERE id='$id';" >/dev/null
  info "HUMAN_ASKED + lease 1시간 전 만료 상태로 투입"

  sleep $((LEASE_SECONDS + 20))
  local st owner
  st="$(status_of "$id")"; owner="$(owner_of "$id")"
  info "status=$st consumer=$owner"
  [[ "$st" == "HUMAN_ASKED" && "$owner" == "asker" ]] || {
    echo "실패: 정상 대기 작업이 회수되었다 (status=$st consumer=$owner)"; return 1; }
  say "결과: 통과 — 기다리는 작업은 건드리지 않는다"
}

scenario_blocking() {
  say "시나리오 9 — 익스큐터가 이벤트 루프를 붙잡고 있어도 연장이 나가는가"
  # 이 시나리오가 이 벤치에서 가장 중요하다. heartbeat 을 asyncio 태스크가
  # 아니라 별도 OS 스레드에 둔 유일한 이유가 여기 있기 때문이다.
  #
  # 익스큐터가 동기 호출(time.sleep)로 루프를 붙잡으면, 연장이 루프 위에 있었을
  # 경우 함께 멈춘다. 그러면 lease 가 만료되고 **살아서 일하는 중인 작업이**
  # 회수되어 두 번 수행된다. 실제 에이전트의 동기 LLM 호출·서브프로세스 대기가
  # 바로 이 모양이라, 이게 막히지 않으면 설계가 틀린 것이다.
  local block=$((LEASE_SECONDS * 3))
  prepare_workers 2 "$block" sdk blocking

  local id="aaaa0009-0000-0000-0000-000000000009"
  new_todo "$id"
  local first _e
  owner_line="$(wait_for_owner "$id" "" 120)" || {
    echo "실패: 아무도 집지 않았다"; return 1; }
  read -r first _e <<<"$owner_line"
  info "점유자: $first (루프를 ${block}s 동안 붙잡는다 = lease 의 3배)"

  # 붙잡고 있는 동안 점유자가 바뀌지 않아야 한다.
  # 지켜보는 동안 점유자가 바뀌면 회수된 것이다.
  #
  # 주의: 정상 완료도 consumer 를 비운다(save_task_result). 그걸 "점유자가
  # 사라졌다 = 회수" 로 읽으면 멀쩡한 통과가 실패로 보인다 — 실제로 한 번
  # 그렇게 읽었다. 회수의 증거는 "빈 점유자" 가 아니라 "다른 점유자" 다.
  local t=0 owner st
  while (( t < block )); do
    sleep 5; t=$((t+5))
    st="$(status_of "$id")"
    [[ "$st" == "COMPLETED" ]] && break
    owner="$(owner_of "$id")"
    [[ -z "$owner" || "$owner" == "$first" ]] || {
      echo "실패: 루프가 막힌 사이 ${t}s 에 회수되었다 ($first → $owner)"; return 1; }
  done
  info "${block}s 동안 점유자 불변 — 블로킹 중에도 연장이 나갔다"

  # 끝까지 수행되고, 수행은 한 번뿐이어야 한다.
  local t2=0
  while (( t2 < 60 )); do
    [[ "$(status_of "$id")" == "COMPLETED" ]] && break
    sleep 2; t2=$((t2+2))
  done
  local starts; starts="$(bench_logs | grep -c "BENCH start todo=$id" || true)"
  info "status=$(status_of "$id") claim_count=$(claims_of "$id") start 로그 ${starts}건"
  [[ "$starts" == "1" ]] || { echo "실패: 같은 작업이 ${starts}번 수행되었다"; return 1; }
  [[ "$(claims_of "$id")" == "1" ]] || { echo "실패: 회수가 일어났다"; return 1; }
  say "결과: 통과 — 루프가 막혀도 점유가 유지되고 수행은 한 번뿐이다"
}

scenario_error() {
  say "시나리오 10 — 작업이 오류로 끝나면 점유가 풀리고 실패로 남는가"
  prepare_workers 1 "$WORK_SECONDS" sdk error

  local id="aaaa000a-0000-0000-0000-00000000000a"
  new_todo "$id"
  local first _e
  owner_line="$(wait_for_owner "$id" "" 120)" || {
    echo "실패: 아무도 집지 않았다"; return 1; }
  read -r first _e <<<"$owner_line"
  info "점유자: $first (잠시 뒤 예외를 던진다)"

  local t=0 st
  while (( t < 90 )); do
    st="$(status_of "$id")"
    [[ "$st" == "FAILED" ]] && break
    sleep 2; t=$((t+2))
  done
  local lu; lu="$(psql_ "SELECT coalesce(lease_until::text,'(null)') FROM todolist WHERE id='$id';")"
  info "status=$st lease_until=$lu consumer=$(owner_of "$id")"
  [[ "$st" == "FAILED" ]] || { echo "실패: 오류인데 $st 로 남았다"; return 1; }
  # 실패로 끝난 작업은 회수 대상이 아니다. lease 를 남겨 두면 "아직 누가
  # 들고 있다" 로 읽히므로 비워져야 한다.
  [[ "$lu" == "(null)" ]] || { echo "실패: 실패 처리 후에도 lease 가 남아 있다 ($lu)"; return 1; }

  # 상한 전이라도 FAILED 는 다시 집히지 않아야 한다(선택 조건에 없다).
  sleep $((LEASE_SECONDS + 10))
  local starts; starts="$(bench_logs | grep -c "BENCH start todo=$id" || true)"
  [[ "$starts" == "1" ]] || { echo "실패: 실패한 작업이 ${starts}번 집혔다"; return 1; }
  info "실패 후 다시 집히지 않았다 (start 로그 1건)"
  say "결과: 통과 — 오류는 실패로 남고 점유가 풀린다"
}

scenario_long() {
  say "시나리오 11 — 긴 작업(연장 수십~수백 회)에서도 점유가 유지되는가"
  # 시나리오 2 는 lease 의 3배(연장 12회)까지만 봤다. 운영의 에이전트 작업은
  # 분 단위이고 연장은 수백 회가 된다. 연장이 한 번이라도 조용히 끊기면
  # 그때부터 회수 대상이 되므로, 긴 구간을 한 번은 봐야 한다.
  local work="${LONG_WORK_SECONDS:-600}"
  prepare_workers 2 "$work" sdk sleep

  local id="aaaa000b-0000-0000-0000-00000000000b"
  new_todo "$id"
  local first _e
  owner_line="$(wait_for_owner "$id" "" 120)" || {
    echo "실패: 아무도 집지 않았다"; return 1; }
  read -r first _e <<<"$owner_line"
  local expect=$((work / HEARTBEAT_SECONDS))
  info "점유자: $first (${work}s 수행 = 연장 약 ${expect}회 예상)"

  local t=0 owner st
  while (( t < work )); do
    sleep 15; t=$((t+15))
    st="$(status_of "$id")"
    [[ "$st" == "COMPLETED" ]] && break
    owner="$(owner_of "$id")"
    [[ -z "$owner" || "$owner" == "$first" ]] || {
      echo "실패: ${t}s 에 회수되었다 ($first → $owner)"; return 1; }
  done
  info "${work}s 동안 점유자 불변"

  local t2=0
  while (( t2 < 90 )); do
    [[ "$(status_of "$id")" == "COMPLETED" ]] && break
    sleep 3; t2=$((t2+3))
  done
  local starts; starts="$(bench_logs | grep -c "BENCH start todo=$id" || true)"
  info "status=$(status_of "$id") claim_count=$(claims_of "$id") start 로그 ${starts}건"
  [[ "$starts" == "1" && "$(claims_of "$id")" == "1" ]] || {
    echo "실패: 긴 작업이 회수되거나 중복 수행되었다"; return 1; }
  say "결과: 통과 — 긴 작업도 연장만으로 점유가 유지된다"
}

scenario_mixed() {
  say "시나리오 6 — 구버전(lease 모르는) 워커가 섞여 돌 때"
  prepare_workers 0 "$WORK_SECONDS"
  # 1) 마이그레이션 이전에 남은 고아 행: lease_until 이 비어 있다.
  local orphan="aaaa0006-0000-0000-0000-000000000001"
  new_todo "$orphan" "STARTED" 1
  psql_ "UPDATE todolist SET consumer='pre-migration-worker', lease_until=NULL WHERE id='$orphan';" >/dev/null

  # 2) 구버전 워커가 집어 수행 중인 작업
  local legacy_task="aaaa0006-0000-0000-0000-000000000002"
  $K set env deploy/worker WORKER_MODE=legacy >/dev/null
  scale_workers 1
  new_todo "$legacy_task"

  local legacy_owner _e
  owner_line="$(wait_for_owner "$legacy_task" "" 120)" || {
    echo "실패: 구버전 워커가 집지 않았다"; return 1; }
  read -r legacy_owner _e <<<"$owner_line"
  info "구버전 워커가 집었다: $legacy_owner"
  local lease_val; lease_val="$(psql_ "SELECT coalesce(lease_until::text,'(null)') FROM todolist WHERE id='$legacy_task';")"
  info "그 행의 lease_until=$lease_val (구버전 호출은 만료 없는 점유다)"
  [[ "$lease_val" == "(null)" ]] || { echo "실패: 구버전 호출에 lease 가 걸렸다"; return 1; }

  # 3) 신버전 워커를 같이 띄운다. 위 두 행을 건드리면 안 된다.
  $K scale deploy/worker --replicas=0 >/dev/null
  $K rollout status deploy/worker --timeout=120s >/dev/null
  info "(구버전 워커가 수행 중이던 행은 그대로 두고 신버전 워커를 올린다)"
  set_worker_mode sdk
  scale_workers 2

  sleep $((LEASE_SECONDS + 20))
  local o1 o2
  o1="$(owner_of "$orphan")"; o2="$(owner_of "$legacy_task")"
  info "기존 고아 행: consumer=$o1 status=$(status_of "$orphan")"
  info "구버전 점유 행: consumer=$o2 status=$(status_of "$legacy_task")"
  [[ "$o1" == "pre-migration-worker" ]] || {
    echo "실패: lease 없는 기존 행을 회수했다 → 그 워커가 살아 있었다면 중복 수행"; return 1; }
  [[ "$o2" == "$legacy_owner" ]] || {
    echo "실패: 구버전 워커가 수행 중인 작업을 가져갔다 → 중복 수행"; return 1; }

  # 4) 신버전 워커는 새 작업을 정상적으로 집고 끝낸다(유실 없음).
  local fresh="aaaa0006-0000-0000-0000-000000000003"
  new_todo "$fresh"
  local t=0
  while [[ "$(status_of "$fresh")" != "COMPLETED" ]]; do
    sleep 2; t=$((t+2))
    (( t > WORK_SECONDS + 90 )) && { echo "실패: 새 작업이 처리되지 않았다"; return 1; }
  done
  info "새 작업은 정상 처리 (${t}s)"
  say "결과: 통과 — 유실도 중복 수행도 없다"
}

scenario_fence() {
  say "시나리오 7 — 회수당한 워커는 하던 일을 버리는가(펜싱)"
  # 작업 수행시간을 길게 둔다. 얼려 두는 동안 작업이 끝나 버리면 회수를
  # 시험할 수 없다.
  prepare_workers 2 90
  local id="aaaa0007-0000-0000-0000-000000000007"
  new_todo "$id"

  local first _e
  owner_line="$(wait_for_owner "$id" "" 120)" || {
    echo "실패: 아무도 집지 않았다"; return 1; }
  read -r first _e <<<"$owner_line"
  info "점유자: $first"

  # 죽지는 않았지만 **멈춰 선** 워커를 만든다 — SIGSTOP. 긴 GC 정지, 멈춘
  # 디스크, 끊긴 네트워크가 현실에서 만드는 상태이고, lease 가 정말로 노리는
  # 경우다. 얼어 있는 동안에는 heartbeat 도 함께 멈추므로 lease 가 자연히
  # 만료된다(DB 시각을 손으로 밀어 넣지 않는다 — 그러면 heartbeat 과 경쟁하게
  # 되고, 무엇을 측정한 것인지도 흐려진다).
  local pod="${first%%:*}" pid="${first##*:}"
  info "kill -STOP ${pid} in ${pod} (살아 있지만 멈춘 워커)"
  $K exec "$pod" -- sh -c "kill -STOP $pid"

  local second reclaim_elapsed
  owner_line="$(wait_for_owner "$id" "$first" 120)" || {
    $K exec "$pod" -- sh -c "kill -CONT $pid" || true
    echo "실패: ${reclaim_elapsed}s 동안 회수되지 않았다"; return 1; }
  read -r second reclaim_elapsed <<<"$owner_line"
  info "회수: $second (멈춘 뒤 ${reclaim_elapsed}s)"

  # 이제 깨운다. 자기가 회수당한 줄 모르는 워커가 하던 일을 계속하려 한다.
  info "kill -CONT ${pid} (멈춘 워커를 깨운다)"
  $K exec "$pod" -- sh -c "kill -CONT $pid"

  # heartbeat 한 주기 안에 스스로 멈춰야 한다.
  local t2=0 cancelled=0
  while (( t2 < 60 )); do
    # grep -q 를 파이프로 받지 않는다(위 wait_workers_polling 의 주석 참고).
    if grep -q "BENCH cancelled todo=$id consumer=$first" <<<"$(bench_logs)"; then cancelled=1; break; fi
    sleep 2; t2=$((t2+2))
  done
  (( cancelled )) || { echo "실패: 회수당한 워커가 계속 일하고 있다(동시 수행)"; return 1; }
  info "깨어난 워커가 ${t2}s 안에 스스로 중단했다 (heartbeat 주기 ${HEARTBEAT_SECONDS}s)"
  info "점유 상실 로그: $($K logs "$pod" 2>/dev/null | grep -c '점유 상실' || true)건"

  # 끝까지 수행한 워커는 하나여야 한다.
  local t3=0
  while (( t3 < 240 )); do
    [[ "$(status_of "$id")" == "COMPLETED" ]] && break
    sleep 3; t3=$((t3+3))
  done
  local finishes
  finishes="$(bench_logs | grep -c "BENCH finish todo=$id" || true)"
  info "finish 로그: ${finishes}건 (status=$(status_of "$id") claim_count=$(claims_of "$id"))"
  [[ "$finishes" == "1" ]] || { echo "실패: 같은 작업이 ${finishes}번 끝났다"; return 1; }
  say "결과: 통과 — 회수된 쪽은 버리고, 끝낸 것은 한 번뿐이다"
}

scenario_migrate() {
  say "시나리오 8 — 워커가 도는 중에 마이그레이션을 적용한다"
  info "lease 도입 전 스키마로 되돌려 세운다"
  mkdir -p "$STAGE"
  git -C "$REPO" show HEAD:volumes/db/init.sql > "$STAGE/init-head.sql"
  INIT_SQL="$STAGE/init-head.sql" apply_schema --no-lease-columns
  restart_db_and_api

  # 구버전 워커(4-인자 호출, 연장 없음)가 계속 폴링하는 상태를 만든다.
  prepare_workers 2 3 legacy
  clear_todos

  # 1) 적용 전에 집혀 수행 중인 행 하나를 남긴다(= 운영에서 흔한 상태).
  local inflight="aaaa0008-0000-0000-0000-000000000001"
  $K set env deploy/worker WORK_SECONDS=600 >/dev/null
  $K rollout status deploy/worker --timeout=180s >/dev/null
  new_todo "$inflight"
  local holder _e
  owner_line="$(wait_for_owner "$inflight" "" 150)" || {
    echo "실패: 적용 전 작업을 아무도 집지 않았다"; return 1; }
  read -r holder _e <<<"$owner_line"
  info "적용 전부터 수행 중인 행: $holder 가 점유(10분짜리 작업)"

  # 2) 작업을 계속 흘려보내면서 적용한다. 적용 전/중/후에 들어온 작업이
  #    하나라도 사라지면 안 된다.
  $K set env deploy/worker WORK_SECONDS=3 >/dev/null
  $K rollout status deploy/worker --timeout=180s >/dev/null
  info "작업을 2초마다 투입하면서 마이그레이션을 적용한다"
  local feeder_n=15 i
  (
    for ((i = 1; i <= feeder_n; i++)); do
      new_todo "$(printf 'aaaa0008-0000-0000-0000-1%011d' "$i")"
      sleep 2
    done
  ) &
  local feeder=$!

  sleep 6
  say "  마이그레이션 적용 (한 트랜잭션)"
  python3 "$HERE/extract_schema.py" "$INIT_SQL" --upgrade-only -o "$STAGE/upgrade.sql"
  local t0; t0="$(now_ms)"
  psql_file "$STAGE/upgrade.sql" 2>&1 | grep -iE "error|notice" || true
  info "적용 소요: $(python3 -c "print(round(($(now_ms)-$t0)/1000,2))")s"

  wait "$feeder"
  info "${feeder_n}개 투입 완료, 처리 대기"

  local t=0 done_n
  while :; do
    done_n="$(psql_ "SELECT count(*) FROM todolist WHERE draft_status='COMPLETED';")"
    [[ "$done_n" == "$feeder_n" ]] && break
    sleep 3; t=$((t+3))
    if (( t > 180 )); then
      echo "실패: 투입한 ${feeder_n}개 중 ${done_n}개만 끝났다 → 마이그레이션 중 유실"
      psql_ "SELECT id, draft_status, consumer FROM todolist WHERE draft_status IS DISTINCT FROM 'COMPLETED';"
      return 1
    fi
  done
  info "적용 전/중/후에 들어온 ${feeder_n}개 전부 처리 (유실 0건)"

  # 3) 적용 전부터 점유 중이던 행은 건드리지 않아야 한다.
  #    lease_until 이 비어 있으므로(구버전이 집었다) 회수 대상이 아니다.
  local o lu
  o="$(owner_of "$inflight")"; lu="$(psql_ "SELECT coalesce(lease_until::text,'(null)') FROM todolist WHERE id='$inflight';")"
  info "적용 전 점유 행: consumer=$o lease_until=$lu status=$(status_of "$inflight")"
  [[ "$o" == "$holder" ]] || {
    echo "실패: 마이그레이션이 수행 중인 행의 점유자를 바꿨다"; return 1; }
  [[ "$lu" == "(null)" ]] || {
    echo "실패: 구버전이 집은 행에 lease 가 생겼다 → 만료되면 중복 수행된다"; return 1; }

  # 4) 적용 후 신버전 워커가 집는 행에는 lease 가 걸린다.
  prepare_workers 2 60 sdk
  local fresh="aaaa0008-0000-0000-0000-000000000009"
  new_todo "$fresh"
  local nowner _e2
  owner_line="$(wait_for_owner "$fresh" "" 120)" || {
    echo "실패: 적용 후 신버전 워커가 집지 않았다"; return 1; }
  read -r nowner _e2 <<<"$owner_line"
  lu="$(psql_ "SELECT coalesce(lease_until::text,'(null)') FROM todolist WHERE id='$fresh';")"
  info "적용 후 새 점유: $nowner lease_until=$lu claim_count=$(claims_of "$fresh")"
  [[ "$lu" != "(null)" ]] || { echo "실패: 적용 후에도 lease 가 걸리지 않는다"; return 1; }
  say "결과: 통과 — 적용 중 유실 0건, 기존 점유 불변, 이후 점유에는 lease"
}

baseline() {
  say "기준선 — lease 도입 전 RPC 로 고아 STARTED 재현"
  info "git HEAD 의 init.sql 로 스키마를 세운다(원본 RPC, lease 컬럼 없음)"
  mkdir -p "$STAGE"
  git -C "$REPO" show HEAD:volumes/db/init.sql > "$STAGE/init-head.sql"
  INIT_SQL="$STAGE/init-head.sql" apply_schema --no-lease-columns
  BENCH_JWT="$(anon_jwt 'bench-jwt-secret-0123456789-abcdefgh')"
  restart_db_and_api

  # 원본 RPC 는 4-인자뿐이므로 구버전 워커로 돈다.
  set_worker_mode legacy
  scale_workers 3
  clear_todos
  local id="bbbb0000-0000-0000-0000-000000000001"
  new_todo "$id"

  local first _e
  owner_line="$(wait_for_owner "$id" "" 120)" || {
    echo "실패: 아무도 집지 않았다"; return 1; }
  read -r first _e <<<"$owner_line"
  info "최초 점유자: $first"
  local pod="${first%%:*}" pid="${first##*:}"
  local restarts_before; restarts_before="$(restarts_of "$pod")"
  info "kill -9 ${pid} in ${pod}"
  $K exec "$pod" -- sh -c "kill -9 $pid" || true
  assert_killed "$pod" "$restarts_before" || return 1

  local watch=35 t=0
  info "${watch}초 동안 재클레임을 지켜본다"
  while (( t < watch )); do
    sleep 1; t=$((t+1))
    local cur; cur="$(owner_of "$id")"
    if [[ -n "$cur" && "$cur" != "$first" ]]; then
      info "뜻밖에 ${t}s 에 재클레임됨: $cur"
      say "기준선: 재현되지 않음(원본 RPC 에서도 회수가 일어났다)"
      return 0
    fi
  done
  info "status=$(status_of "$id") consumer=$(owner_of "$id")"
  say "기준선: ${watch}초 동안 재클레임 0회 — 보고서의 고아 STARTED 가 재현되었다"
}

all() {
  # supabase 타깃에서는 스키마를 갈아끼우는 시나리오를 돌리지 않는다.
  # sqltest 와 migrate 는 DB 를 lease 이전으로 되돌렸다가 세우는데, 그건
  # 벤치 전용 DB 에서나 할 일이다. 내 개발 DB 를 그렇게 다루면 안 된다.
  if [[ "$TARGET" != "supabase" ]]; then
    sqltest
  else
    info "supabase 타깃: sqltest/migrate 는 건너뛴다(스키마를 갈아끼우는 시나리오)"
  fi
  scenario_kill
  scenario_alive
  scenario_blocking
  scenario_error
  scenario_race "${1:-6}"
  scenario_cap
  scenario_human
  scenario_fence
  scenario_mixed
  [[ "$TARGET" != "supabase" ]] && scenario_migrate
  return 0
}

BENCH_JWT="$(anon_jwt 'bench-jwt-secret-0123456789-abcdefgh')"

cmd="${1:-}"; shift || true
case "$cmd" in
  up) up "$@" ;;
  down) down ;;
  sqltest) sqltest ;;
  kill) scenario_kill ;;
  alive) scenario_alive ;;
  race) scenario_race "$@" ;;
  cap) scenario_cap ;;
  human) scenario_human ;;
  fence) scenario_fence ;;
  mixed) scenario_mixed ;;
  blocking) scenario_blocking ;;
  error) scenario_error ;;
  long) scenario_long ;;
  migrate) scenario_migrate ;;
  baseline) baseline ;;
  all) all "$@" ;;
  logs) bench_logs ;;
  rows) psql_ "SELECT id, draft_status, consumer, claim_count, lease_until FROM todolist WHERE $(todo_scope) ORDER BY start_date;" ;;
  cleanup) clear_todos; info "벤치가 만든 행을 지웠다 (대상=$TARGET)" ;;
  *) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac
