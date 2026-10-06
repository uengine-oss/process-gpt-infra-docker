"""벤치 워커. 실제 process-gpt-agent-sdk 로 todolist 를 폴링한다.

두 가지 모드가 있다.

- `WORKER_MODE=sdk` (기본): `ProcessGPTAgentServer` 를 그대로 띄운다. 폴링,
  점유, lease 연장, 펜싱이 전부 SDK 의 코드다.
- `WORKER_MODE=legacy`: lease 를 모르는 **구버전 SDK** 를 흉내낸다. RPC 를
  예전 4-인자로만 부르고 연장도 하지 않는다. 마이그레이션 중 구버전 워커가
  섞여 돌 때 작업이 유실되거나 중복 수행되지 않는지 보기 위한 것이다.

익스큐터는 `EXEC_MODE` 로 고른다. 작업의 내용이 아니라 **작업이 이벤트 루프를
어떻게 쓰는가**가 lease 의 관심사이기 때문이다.

- `sleep`(기본): `await asyncio.sleep` 으로 쉰다. 이벤트 루프를 놓아 준다.
- `blocking`: 동기 `time.sleep` 으로 이벤트 루프를 **붙잡는다**. heartbeat 을 별도 OS
  스레드에 둔 이유가 바로 이것이다 — 연장이 루프 위에 있었다면 여기서 함께
  멈추고, 살아서 일하는 중인 작업이 회수된다. 실제 에이전트의 동기 LLM 호출·
  서브프로세스 대기가 이 모양이다.
- `error`: 잠시 뒤 예외를 던진다. 실패로 기록되고 점유가 풀리는지 본다.

`prepare_context` 는 `STUB_CONTEXT=1` 이면 비워 둔다. 원래는 form_def·사용자·
MCP 설정 같은 여섯 테이블을 읽어 프롬프트 컨텍스트를 만든다. 테이블이 없는
벤치 DB 에서는 비워 두고, 실제 스키마를 가진 로컬 Supabase 를 볼 때는
`STUB_CONTEXT=0` 으로 **진짜 조립을 돌린다**(그 시간 동안의 점유도 검증 대상이다).
"""

import asyncio
import logging
import os
import socket
import sys
import time
import uuid

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("bench-worker")

AGENT_ORCH = os.getenv("AGENT_ORCH", "bench-agent")
WORK_SECONDS = float(os.getenv("WORK_SECONDS", "60"))
MODE = (os.getenv("WORKER_MODE") or "sdk").lower()
EXEC_MODE = (os.getenv("EXEC_MODE") or "sleep").lower()
ERROR_AFTER = float(os.getenv("ERROR_AFTER_SECONDS", "5"))
STUB_CONTEXT = (os.getenv("STUB_CONTEXT", "1").strip() not in ("0", "false", "no"))
CONSUMER = os.getenv("CONSUMER_ID") or f"{socket.gethostname()}:{os.getpid()}"


def _mark(event: str, todo_id: str, **extra) -> None:
    """측정이 긁어 갈 한 줄. 사람이 읽는 로그와 섞이지 않게 접두어를 붙인다."""
    fields = " ".join(f"{k}={v}" for k, v in extra.items())
    log.info("BENCH %s todo=%s consumer=%s ts=%.3f %s",
             event, todo_id, CONSUMER, time.time(), fields)


# ============================================================================
# sdk 모드
# ============================================================================
async def run_sdk() -> None:
    from a2a.server.agent_execution import AgentExecutor
    from processgpt_agent_sdk import ProcessGPTAgentServer, database
    from processgpt_agent_sdk import processgpt_agent_framework as fw

    if STUB_CONTEXT:
        # 테이블이 없는 벤치 DB 용. 실제 스키마를 볼 때는 끈다(모듈 docstring).
        async def _noop_prepare(self) -> None:
            return None

        fw.ProcessGPTRequestContext.prepare_context = _noop_prepare

    class BenchExecutor(AgentExecutor):
        """EXEC_MODE 가 정한 방식으로 WORK_SECONDS 동안 일하고 결과를 저장한다."""

        async def execute(self, context, event_queue) -> None:
            todo_id = context.task_id
            _mark("start", todo_id, work_seconds=WORK_SECONDS, exec_mode=EXEC_MODE)
            started = time.time()

            if EXEC_MODE == "error":
                # 실패 경로. 진짜 작업도 중간에 터진다 — 그때 점유가 풀리고
                # 실패로 남는지 본다.
                await asyncio.sleep(ERROR_AFTER)
                _mark("raising", todo_id, elapsed=round(time.time() - started, 3))
                raise RuntimeError("bench: 의도한 작업 오류")

            if EXEC_MODE == "blocking":
                # **이벤트 루프를 붙잡는다.** await 가 없으므로 이 코루틴이 도는
                # 동안 루프 위의 어떤 것도 깨어나지 못한다 — 취소 워처도, 연장이
                # 이벤트 루프 위에 있었다면 연장도. 연장이 별도 스레드이기 때문에만
                # 점유가 유지된다. 그것이 이 모드로 확인하려는 성질이다.
                #
                # 취소가 먹지 않는 것은 결함이 아니라 전제다. 블로킹 구간에서는
                # 회수당해도 즉시 멈출 수 없고, 이벤트 루프가 풀린 뒤에야 알아챈다.
                time.sleep(WORK_SECONDS)
                _mark("unblocked", todo_id, elapsed=round(time.time() - started, 3))
            else:
                try:
                    # 1초씩 쪼개서 잔다. 취소(점유 상실/사용자 취소)가 즉시 먹히고,
                    # 진행 상황이 로그로 보인다.
                    while time.time() - started < WORK_SECONDS:
                        await asyncio.sleep(1.0)
                except asyncio.CancelledError:
                    _mark("cancelled", todo_id, elapsed=round(time.time() - started, 3))
                    raise

            await database.save_task_result(
                todo_id,
                {"bench": True, "consumer": CONSUMER, "run_id": str(uuid.uuid4())},
                True,
            )
            _mark("finish", todo_id, elapsed=round(time.time() - started, 3))

        async def cancel(self, context, event_queue) -> None:
            _mark("cancel_called", context.task_id)

    server = ProcessGPTAgentServer(BenchExecutor(), AGENT_ORCH, tenant_auth=False)
    log.info(
        "벤치 워커 시작 mode=sdk exec=%s stub_context=%s consumer=%s "
        "lease=%ss heartbeat=%ss max_claims=%s work=%ss",
        EXEC_MODE,
        STUB_CONTEXT,
        CONSUMER,
        os.getenv("TASK_LEASE_SECONDS", "(기본)"),
        os.getenv("TASK_LEASE_HEARTBEAT_SECONDS", "(기본: lease/4)"),
        os.getenv("TASK_MAX_CLAIMS", "(기본)"),
        WORK_SECONDS,
    )
    await server.run()


# ============================================================================
# legacy 모드 — lease 를 모르는 구버전 SDK
# ============================================================================
async def run_legacy() -> None:
    from processgpt_agent_sdk import database

    database.initialize_db()
    client = database.get_db_client()
    log.info("벤치 워커 시작 mode=legacy consumer=%s work=%ss", CONSUMER, WORK_SECONDS)

    while True:
        # 구버전의 호출 그대로다: p_lease_seconds 를 넘기지 않는다.
        resp = client.rpc(
            "fetch_pending_task",
            {
                "p_agent_orch": AGENT_ORCH,
                "p_consumer": CONSUMER,
                "p_limit": 1,
                "p_env": "dev",
            },
        ).execute()
        rows = resp.data or []
        if not rows:
            await asyncio.sleep(10)
            continue

        todo_id = str(rows[0]["id"])
        _mark("start", todo_id, work_seconds=WORK_SECONDS, mode="legacy")
        # 연장하지 않는다. 구버전 워커에는 그런 코드가 없다.
        await asyncio.sleep(WORK_SECONDS)
        await database.save_task_result(todo_id, {"bench": True, "legacy": True}, True)
        _mark("finish", todo_id, mode="legacy")


def main() -> int:
    if MODE == "legacy":
        asyncio.run(run_legacy())
    elif MODE == "sdk":
        asyncio.run(run_sdk())
    else:
        log.error("알 수 없는 WORKER_MODE=%s", MODE)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
