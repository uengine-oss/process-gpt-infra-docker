# 작업 점유에 만료 시한(lease)을 두다 — 설계와 실측

## 무엇이 문제였나

폴링 워커가 `fetch_pending_task` 로 todolist 한 건을 집으면 그 행은
`draft_status='STARTED'` 가 되고 `consumer` 에 점유자 이름이 적혔다. 거기서 끝이었다.
만료가 없었다.

워커가 `kill -9` 로 죽으면(OOM, 노드 축출, KEDA 축소, 파드 재배치) 그 행은 STARTED 로
**영구히** 남는다. 집는 조건은 `draft_status IS NULL` 또는 `FB_REQUESTED` 이므로
STARTED 행은 다시 걸리지 않는다. 아무도 집지 않고, 사용자에게는 영원히 끝나지 않는
작업으로 보인다. 워커를 늘리거나 줄일 때마다 그만큼 작업이 조용히 사라진다.

기준선 측정(이 저장소의 lease 도입 직전 커밋, `./run_bench.sh baseline`):

| | 결과 |
|---|---|
| 작업을 집은 워커를 kill -9 | 컨테이너 재시작 0→1 로 사망 확인 |
| 이후 35초 동안 재클레임 | **0회** |
| 35초 뒤 행의 상태 | `STARTED`, consumer = 죽은 워커 |

## 무엇을 했나

`todolist` 에 두 컬럼을 두고, 점유 판정 전체를 RPC 안으로 넣었다.

- `lease_until timestamptz` — 점유의 만료 시각. 살아 있는 워커가 주기적으로 연장한다.
- `claim_count integer` — 이 행이 점유된 횟수(최초 + 회수). 무한 재클레임의 상한 근거.

| 함수 | 하는 일 |
|---|---|
| `fetch_pending_task(..., p_lease_seconds, p_max_claims)` | 집을 때 lease 를 걸고, **만료된 STARTED 행을 다시 집고**, 상한에 닿은 행을 FAILED 로 종결한다 |
| `renew_task_lease(todo_id, consumer, lease_seconds)` | 연장(heartbeat). 거절 이유를 jsonb 로 돌려준다 |
| `release_task_lease(todo_id, consumer)` | 정상 종료 시 점유 즉시 해제 |

SDK 쪽은 `processgpt_agent_sdk/lease.py` 의 `LeaseKeeper` 가 작업 수행 내내 연장을
맡고, 연장이 `not_owner` 로 거절되면 진행 중인 실행을 취소한다.

### 판정을 워커에게 묻지 않는다

죽은 워커는 아무것도 보고하지 못한다. 그래서 "이 점유가 아직 살아 있는가" 는
워커의 자기 보고가 아니라 **DB 의 시계와 행의 상태만으로** 결정된다. 집는 순간은
기존대로 `FOR UPDATE SKIP LOCKED` 로 직렬화되므로, 회수 역시 둘이 동시에 집을 수 없다.

### 왜 heartbeat 을 별도 OS 스레드에서 도는가

연장을 asyncio 태스크로 두면, 익스큐터가 동기 호출로 이벤트 루프를 붙잡는 동안
heartbeat 도 함께 멈춘다. 그 사이 lease 가 만료되면 **살아서 일하는 중인 작업이**
회수되어 두 번 수행된다. 에이전트 코드가 이벤트 루프를 막지 않는다는 보장이 없으므로
(LLM SDK, 서브프로세스, 파일 IO 가 섞여 들어온다) heartbeat 은 자기 스레드에서 돈다.
`tests/test_lease.py::test_renews_from_its_own_thread_so_a_blocked_event_loop_cannot_stall_it`
가 이 성질을 고정한다.

### 연장이 거절되면 — 펜싱

`renew_task_lease` 는 거절 이유를 구분해서 돌려준다. 이유마다 워커가 할 일이 다르다.

| reason | 뜻 | 워커의 행동 |
|---|---|---|
| `not_owner` | 다른 워커가 이미 회수했다 | **하던 일을 버린다.** 계속하면 같은 작업이 두 곳에서 끝까지 수행되고 늦게 끝난 쪽이 앞을 덮는다 |
| `not_started` | COMPLETED/HUMAN_ASKED/CANCELLED 로 넘어갔다 | 연장할 점유가 없을 뿐이다. 버리지 않고 heartbeat 만 멈춘다 |
| `missing` | 행이 사라졌다 | 같음 |

## 값을 왜 그렇게 골랐나

| 값 | 운영 기본 | 근거 |
|---|---|---|
| lease 길이 | **120초** | 워커 사망 후 회수까지의 상한은 `남은 lease + 폴링 주기(10초)`. 2분은 파드가 죽고 새 파드가 뜨는 시간과 같은 자릿수여서, 회수가 복구보다 앞질러 일어나 쓸데없는 중복 클레임을 만들지 않는다 |
| heartbeat 주기 | **30초 (lease의 1/4)** | 연속 세 번 실패해도(일시적 DB 오류, 네트워크 재시도) lease 가 남아 있다. 1/2 로 두면 한 번 놓치는 것만으로 만료에 닿아, 멀쩡한 작업이 회수된다 |
| 재클레임 상한 | **3회** (최초 + 회수 2회) | 같은 지점에서 매번 죽는 작업이 영원히 재집행되며 자원을 태우는 것을 막는다. 두 번의 재시도는 "일시적 사고"(노드 축출, OOM 한 번)를 넘기기에 충분하고, 세 번째까지 같은 결과면 일시적인 문제가 아니다 |
| 상한 초과 시 상태 | **FAILED** | STARTED 로 남기면 회수 대상에 계속 걸리고, NULL 로 되돌리면 신규 작업으로 다시 집힌다 — 둘 다 무한 재집행이다. FAILED 는 기존 실패 경로와 같은 상태여서 운영에서 이미 식별된다 |

환경변수로 덮는다: `TASK_LEASE_SECONDS`, `TASK_LEASE_HEARTBEAT_SECONDS`(기본은 lease/4),
`TASK_MAX_CLAIMS`.

**벤치에서는 lease 20초 / heartbeat 5초**를 쓴다. 비율(1/4)은 운영과 같게 두고 길이만
줄였다 — 재클레임을 분 단위로 기다리지 않기 위한 것이고, "연속 세 번 놓쳐도 버틴다" 는
성질은 그대로다.

## 운영 중 적용

`migration.sql` 의 두 `ADD COLUMN IF NOT EXISTS` 는 nullable 이거나 상수 기본값이라
테이블 재작성 없이 메타데이터만 바꾼다(PG 11+).

핵심은 **`lease_until IS NULL` 의 의미**다 — "만료 개념 없이 점유된 행".

- 마이그레이션 이전에 이미 STARTED 로 남아 있던 기존 행
- lease 를 모르는 구버전 SDK 워커가 집은 행 (`p_lease_seconds` 를 넘기지 않는다)

이 행들은 **회수 대상이 아니다.** 연장할 주체가 없는 점유를 회수하면, 그 워커가 아직
살아서 일하는 중일 때 같은 작업이 두 번 수행된다. NULL 은 예전 동작 그대로 둔다 —
유실이 늘지는 않고, 중복 수행은 생기지 않는다. 구버전 워커의 4-인자 호출은
`p_lease_seconds`/`p_max_claims` 의 DEFAULT 로 그대로 동작한다(기존 4-인자 시그니처는
DROP 한다 — 남겨 두면 4-인자 호출이 모호해져 실패한다).

lease 를 쓰지 않는 다른 점유 RPC(`openai_deep_fetch_pending_task`,
`deep_research_fetch_pending_task`)는 집을 때 `lease_until` 을 NULL 로 비운다.
지난 점유가 남긴 과거 시각이 그대로 있으면 `fetch_pending_task` 가 "만료된 점유" 로
보고 회수해, 그 워커가 일하는 중인 작업을 다른 워커가 같이 수행한다.

## 실측 (로컬 kind 클러스터 `bench-pgpt`)

`./run_bench.sh up && ./run_bench.sh all` — Postgres + PostgREST + 폴링 워커를
띄우고, 워커는 **실제 SDK**(`ProcessGPTAgentServer`)로 돈다. 호출 경로도 운영과 같다
(supabase-py → HTTP → PostgREST → RPC). 스키마는 `extract_schema.py` 가 이 저장소의
`volumes/db/init.sql` 에서 **텍스트 그대로** 뽑아 세운다 — 검증한 것과 배포되는 것이
같은 문장임을 보장한다.

모두 한 번의 `./run_bench.sh all` 에서 나온 결과다(2026-10-02, 워커 lease 20초 /
heartbeat 5초 / 폴링 10초 / 상한 3회).

같은 날 스택을 새로 세워(`./run_bench.sh up && ./run_bench.sh all`) **두 번째로 통째로
돌려 8개 전부 다시 통과**했다. 아래 표의 수치는 1차 실행의 것이고, 2차에서 달라진
값은 괄호로 함께 적었다. 둘 사이의 차이는 폴링 위상(워커가 폴링 주기 중 어디에서
죽었는가)에서 오는 것이고, 전부 이론 상한(30초) 안이다.

| # | 확인한 것 | 결과 |
|---|---|---|
| 1 | 작업을 집은 워커를 `kill -9` | 컨테이너 재시작 0→1 로 사망 확인 → 다른 워커가 **20.3초 뒤 재클레임**(2차 19.7초, `claim_count` 1→2) → 수행 완료 |
| 2 | 살아 있는 워커의 작업 | lease 길이의 3배(60초) 동안 점유자 불변, 같은 작업의 실행 로그 **1건**(동시 수행 0건) |
| 3 | 워커 6개 · 작업 12개 동시 폴링 | 12초에 전부 완료(2차도 12초), 실행 로그 12건 / 12작업 → **중복 클레임 0건**, `claim_count` 최댓값 1 |
| 4 | 상한(3회)에 닿은 만료 점유 | **FAILED 로 종결**, 이후 폴링에서 다시 집히지 않음(실행 로그 0건) |
| 5 | 사람 답변 대기(`HUMAN_ASKED`), lease 1시간 전 만료 | 40초 지켜봐도 `HUMAN_ASKED` 그대로, 점유자도 그대로 → **회수되지 않음** |
| 7 | 워커를 `kill -STOP` 으로 멈춤 → 회수 → `kill -CONT` 로 깨움 | 멈춘 뒤 **20.2초에 회수**(2차 20.0초), 깨어난 워커는 **즉시 중단**(점유 상실 로그 1건), 끝낸 워커는 **1건뿐** |
| 6 | 구버전(lease 모르는) 워커와 혼재 | 구버전이 집은 행은 `lease_until=(null)` → 신버전 워커 2개가 40초 돌아도 **가져가지 않음**. 마이그레이션 이전의 고아 행도 그대로. 새 작업은 정상 처리 |
| 8 | 워커가 도는 중에 마이그레이션 적용 | 적용 **0.16초**(한 트랜잭션). 적용 전/중/후에 2초 간격으로 넣은 **15개 전부 처리(유실 0건)**. 적용 전부터 점유 중이던 행은 점유자·lease 불변. 적용 후 새 점유에는 lease 가 걸림 |

### 실제 스키마로 다시 돌렸다 — 벤치 DB 가 숨기던 것

위 표는 네임스페이스 안에 띄운 **최소 Postgres**(테이블이 `todolist` 와 `tenants`
둘뿐)로 잰 것이다. 그 환경은 점유 수명만 분리해서 보기에는 좋지만, 네 가지를
덮지 못한다.

| 덮지 못한 것 | 왜 문제인가 |
|---|---|
| 익스큐터가 **이벤트 루프를 막는** 경우 | heartbeat 을 별도 OS 스레드에 둔 **유일한 이유**다. 벤치의 익스큐터는 `await asyncio.sleep` 만 해서 루프를 놓아 준다 — 설계의 핵심 가정이 작동하는 조건이 아예 없었다 |
| 작업이 **오류로 끝나는** 경로 | 시나리오 어디에도 예외가 없었다 |
| **긴 작업**(연장 수십~수백 회) | 시나리오 2 는 lease 의 3배(연장 12회)까지만 봤다 |
| **컨텍스트 조립과 events 쓰기** | `prepare_context` 를 빈 함수로 덮어썼고, events 테이블 자체가 없었다 |

그래서 **호스트에서 돌고 있는 로컬 Supabase**(`process-gpt-vue3`)를 대상으로
다시 돌렸다. 실제 스키마 66 테이블, 실제 트리거 9 개, Kong → PostgREST 경로를
그대로 탄다. 워커는 `STUB_CONTEXT=0` 으로 **진짜 컨텍스트 조립**을 돌리고
이벤트도 실제 `events` 테이블에 쓴다(`record_events_bulk ok` 로 확인).

```bash
TARGET=supabase ./run_bench.sh all
```

| # | 확인한 것 | 결과 (로컬 Supabase) |
|---|---|---|
| 1 | `kill -9` | **20.1초 뒤 재클레임**, `claim_count` 1→2, 수행 완료 |
| 2 | 살아 있는 워커 | 60초 동안 점유자 불변, 동시 수행 0건 |
| **9** | **익스큐터가 이벤트 루프를 60초(lease 의 3배) 붙잡음** | **점유 유지 · `claim_count=1` · 실행 1건** — 연장이 루프 위에 있었다면 20초에 회수됐을 구간이다 |
| **10** | **작업이 예외로 끝남** | **FAILED · `lease_until` 비워짐 · 이후 재집행 0건** |
| 3 | 워커 6개 · 작업 12개 | 14초에 전부 완료, 중복 클레임 0건, `claim_count` 최댓값 1 |
| 4 | 상한(3회) 도달 | FAILED 로 종결, 재집행 0건 |
| 5 | 사람 답변 대기 | `HUMAN_ASKED` 유지, 점유자 유지 |
| 7 | `kill -STOP` → 회수 → `kill -CONT` | 멈춘 뒤 **19.4초에 회수**, 깨어난 쪽은 즉시 중단, 끝낸 것은 1건 |
| 6 | 구버전 워커 혼재 | 구버전 점유 행·기존 고아 행 모두 회수되지 않음, 새 작업은 정상 처리 |
| **11** | **긴 작업 — 600초 수행(연장 약 120회)** | **점유자 불변 · `claim_count=1` · 실행 1건.** 시작 07:30:37 → 종료 07:40:37(600.22초), 그사이 회수 0회 |

시나리오 11 은 10 분이 걸려 `all` 에 넣지 않았다. 따로 돈다
(`TARGET=supabase ./run_bench.sh long`, 길이는 `LONG_WORK_SECONDS` 로 바꾼다).

`sqltest` 와 `migrate` 는 supabase 타깃에서 건너뛴다. 둘 다 스키마를 lease 이전으로
되돌렸다가 다시 세우는 시나리오라, 개발 데이터가 든 DB 에서 할 일이 아니다.
그 둘은 벤치 DB 에서 돌린 결과가 위에 있다.

#### 실제 스키마라서 드러난 것

- **최소 INSERT 가 거절됐다.** 트리거 `sync_task_execution_on_insert` 가
  `task_execution_properties` 에 행을 넣는데 거기 `proc_inst_id` 가 NOT NULL 이다.
  벤치 DB 에는 그 트리거도 그 테이블도 없었다. 행을 만들 때 `proc_inst_id`·
  `proc_def_id`·`activity_id` 를 채우도록 고쳤다.
- **정상 완료를 회수로 오독했다.** `save_task_result` 가 `consumer` 를 비우는데,
  판정이 "점유자가 사라졌다 = 회수" 였다. 통과한 시나리오가 실패로 보였다.
  회수의 증거는 빈 점유자가 아니라 **다른** 점유자다.

#### 개발 DB 를 쓸 때의 안전장치

`todolist` 에는 내 개발 데이터가 들어 있다(784 행). 그래서 supabase 타깃에서는

- 벤치가 만드는 행에 `agent_orch='lease-bench'` 와 `proc_inst_id='lease-bench-…'`
  를 박고, 삭제는 **그 범위로만** 한다. 조건 없는 `DELETE FROM todolist` 를 도는
  경로가 supabase 타깃에 없어야 한다.
- 집계 질의(`count(*)`, `max(claim_count)`)에도 같은 범위를 건다. 빼먹으면
  "전부 완료" 판정이 남의 행까지 세어 영원히 끝나지 않는다.
- 트리거가 파생시킨 행(`task_execution_properties`, `notifications`)도 같이 치운다.
- 적용 전 `pg_dump` 로 받아 둔다. 함수 소유자가 `supabase_admin` 이므로
  마이그레이션도 그 역할로 적용한다(`postgres` 로는 `must be owner` 로 거절된다).

### 재클레임 시간을 어떻게 읽어야 하나

| | 값 |
|---|---|
| 기준선(lease 이전 RPC) | 35초 동안 **0회** |
| 실측(lease 20초) | 1차 **20.3초**(kill) / **20.2초**(STOP), 2차 **19.7초** / **20.0초** — 여러 차례 돌려 19.5–20.3초 |
| 이론 상한 | 남은 lease + 폴링 주기 = 20 + 10 = **30초** |

워커가 죽는 순간 lease 는 평균 lease/2 만큼 남아 있고, 그 뒤 다음 폴링을 기다린다.
실측이 lease 길이와 거의 같게 나온 것은 벤치의 워커 수(3개)가 폴링 간격(10초)을
촘촘히 메우기 때문이다.

**운영 기본값(lease 120초)으로 환산하면 재클레임은 약 60~130초**다. 작업 자체가
분 단위인 에이전트 작업에서 이 지연은 "영원히 멈춤" 과 비교할 것이 아니다. 더 빠르게
하려면 lease 를 줄이면 되지만, 그만큼 "잠깐 느려진 워커" 를 죽었다고 오판할 여지가
늘어난다.

## 실제 서비스로 — 회귀 테스트

벤치는 범용 워커다. deepagents · cli-agent · codex 를 **자기 진입점으로** 띄워 같은
계약(SVC-LEASE-01~06)을 판정하는 pytest 회귀 테스트는 스펙과 함께
`process-gpt/openspec/specs/agent-sdk_workitem-claim-lease/e2e/` 에 있다.

## 다시 돌리는 법

```bash
cd tests/lease
./run_bench.sh up         # 클러스터 + 스택 (SDK_DIR 로 SDK 경로 지정 가능)
./run_bench.sh all        # 전체 시나리오
./run_bench.sh baseline   # lease 도입 전 RPC 로 고아 STARTED 재현
./run_bench.sh kill       # 개별 시나리오: kill, alive, race, cap, human, fence, mixed, migrate
./run_bench.sh rows       # 현재 todolist 상태
./run_bench.sh logs       # 워커의 BENCH 로그
./run_bench.sh down       # 클러스터 삭제
```

맥에서 kind 를 처음 띄우면 Docker VM 의 inotify 한도 때문에 kube-proxy 가
`too many open files` 로 죽고 CoreDNS 가 Ready 가 되지 않을 수 있다. 그러면 파드가
서비스 이름을 못 찾고, 그 증상이 폴링 실패로 보여 lease 문제와 헷갈린다.

```bash
docker run --rm --privileged alpine sysctl -w \
  fs.inotify.max_user_watches=1048576 fs.inotify.max_user_instances=1024
kubectl -n kube-system delete pod -l k8s-app=kube-proxy -l k8s-app=kube-dns
```

## 남는 위험과 한계

정직하게 적어 둔다. lease 가 덮지 않는 구간이 있다.

**1. 결과 쓰기(`save_task_result`)는 점유자로 펜싱되지 않는다.**
멈춰 섰던 워커가 깨어나면 heartbeat 이 최대 한 주기(기본 30초) 안에 회수를
알아채고 작업을 버린다. 그러나 깨어난 지점이 "일은 끝났고 결과만 쓰는 순간"
이라면, 알아채기 전에 결과를 쓸 수 있다. **익스큐터가 이벤트 루프를 막는 구간이
특히 그렇다** — 시나리오 9 에서 보듯 블로킹 중에는 회수를 알아챌 수 없고,
루프가 풀린 직후가 바로 결과를 쓰는 지점이다. 그러면 회수한 워커의 결과를 덮는다.
막으려면 `save_task_result` 에 `p_consumer text DEFAULT NULL` 을 더해
`consumer` 가 맞거나 비어 있을 때만 쓰게 하면 된다. 이번 범위에 넣지 않았다 —
잘못 넣으면 결과가 조용히 사라지는 쪽으로 틀리고, 그건 지금 막으려는 문제보다
나쁘다. 별도로 다룬다.

**2. heartbeat 이 todolist 의 트리거를 깨운다.**
연장은 `UPDATE todolist` 이므로 `set_updated_at` 과
`trigger_update_bpm_proc_inst_updated_at` 이 함께 돈다. 즉 **작업당 30초마다
`bpm_proc_inst.updated_at` 이 갱신된다.** 쓰기 비용은 작지만(행 두 개) 의미가
달라진다 — 예전에는 집은 뒤 끝낼 때까지 그 프로세스 인스턴스의 updated_at 이
움직이지 않았다. "최근 변경" 으로 정렬하는 화면이 있으면 진행 중인 작업이 계속
위로 올라온다. 피하려면 lease 를 별도 테이블로 빼야 하는데, 그러면 점유와 상태가
두 곳에 나뉜다. 지금은 같은 행에 두는 쪽을 택했다.

**3. 마이그레이션 이전에 쌓인 고아 행은 그대로 남는다.**
`lease_until IS NULL` 은 회수하지 않기 때문이다(그게 중복 수행을 막는 규칙이다).
과거의 고아는 운영자가 한 번 정리해야 한다. 아래 쿼리는 **그 워커들이 정말
죽었는지 확인한 뒤에** 돌린다.

```sql
-- 한 시간 넘게 아무 변화가 없는 STARTED 행 = 연장할 주체가 없는 점유.
SELECT id, consumer, updated_at FROM todolist
 WHERE status = 'IN_PROGRESS' AND draft_status = 'STARTED'
   AND lease_until IS NULL AND updated_at < now() - interval '1 hour';

UPDATE todolist SET draft_status = 'FAILED', lease_until = NULL
 WHERE status = 'IN_PROGRESS' AND draft_status = 'STARTED'
   AND lease_until IS NULL AND updated_at < now() - interval '1 hour';
```

**4. 다른 점유 RPC 는 여전히 lease 가 없다.**
`openai_deep_fetch_pending_task`, `deep_research_fetch_pending_task` 로 집은
작업은 그 워커가 죽으면 예전처럼 고아가 된다. 이번에 한 일은 그 행들이 **잘못
회수되지 않게** 막은 것뿐이다(집을 때 `lease_until` 을 비운다). 그 두 경로에도
lease 를 주려면 각 워커에 heartbeat 이 있어야 한다.

## 되돌리면 깨지는 테스트

"깨질 것이다" 로 두지 않고, 실제로 되돌려서 돌려 봤다. lease 를 지우는 방식마다
어디서 처음 깨지는지가 다르다(테스트는 한 트랜잭션이라 첫 실패에서 멈춘다).

| 되돌리는 방식 | 처음 깨지는 곳 |
|---|---|
| RPC 를 lease 이전 커밋으로 (4-인자 시그니처) | `1 claim_sets_lease` — 함수 시그니처가 없다 |
| 회수 분기(`OR (draft_status='STARTED' AND lease_until < now() ...)`)만 지움 | `3 expired_started_is_reclaimed` — 만료된 점유를 아무도 집지 않는다 |
| `renew_task_lease` 를 지움 | `10 renew_by_owner_extends` |
| SDK 의 폴링에서 `p_lease_seconds`/`p_max_claims` 를 빼면 | `test_claim_requests_a_lease`, `test_claim_lease_follows_the_env` |
| heartbeat 을 별도 스레드가 아니라 asyncio 태스크로 되돌리면 | 단위: `test_renews_from_its_own_thread_so_a_blocked_event_loop_cannot_stall_it`<br>클러스터: `TARGET=supabase ./run_bench.sh blocking` — 60초 블로킹 중 20초에 회수된다 |

| 어디 | 개수 |
|---|---|
| RPC | `tests/lease/test_lease_rpc.sql` — 16개 |
| SDK | `process-gpt-agent-sdk/tests/test_lease.py` — 20개 |

### 테스트가 조용히 통과하던 문제 (고쳤다)

처음 쓴 판정 함수는 `IF NOT p_ok THEN RAISE` 였다. 그런데 plpgsql 의
`SELECT * INTO r FROM fetch_pending_task(...)` 는 **아무 행도 돌아오지 않아도
오류를 내지 않고** `r` 의 필드를 전부 NULL 로 둔다. 그러면 `r.id = '...'` 이 NULL,
AND 로 엮인 조건도 NULL, `NOT NULL` 도 NULL 이라 IF 가 거짓으로 보고 지나간다 —
**작업이 집히지 않았는데 "ok" 가 찍힌다.**

회수 분기를 지우고 돌렸을 때 3번이 통과하는 것을 보고 알았다. 판정을
`IF p_ok IS NOT TRUE` 로 바꿨다. 위 표의 "처음 깨지는 곳" 은 그 수정 뒤에
측정한 것이다.

## 이번 범위가 아닌 것

KEDA 쿼리와 ScaledJob 표준화는 다음 할일이다. lease 가 들어가면 KEDA 가 보는
"대기 중인 작업 수" 에 만료된 STARTED 를 포함시킬 수 있게 되는데, 그 쿼리와
스케일 정책은 별도로 다룬다.
