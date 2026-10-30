-- ============================================================
-- 시나리오 확보(backfill) 회차 트리거 추가
--
-- 병합 전 검증은 "저장된 시나리오를 base/head 두 벌로 돌려 비교" 하는 방식이라,
-- 시나리오가 없는 리소스에서는 아예 돌릴 수 없다. 생성 완료 게이트
-- (`complete_skill_creation`)가 생기기 전에 만들어진 스킬들이 그 상태다.
--
-- 그런 리소스에 시나리오를 뒤늦게 만들어 붙이는 회차가 trigger='backfill' 이다
-- (core/skills/eval_backfill.py). 현재(base) 버전으로 후보 시나리오를 실제 실행·채점해
-- **통과한 단계만** 스위트로 확정하므로, 결과물은 현재 동작의 기준선이 된다.
--
-- 이 회차는 특정 병합 요청의 판정이 아니므로 pr_id 를 비워 둔다 — 기존
-- resource_eval_runs_pr_required 제약은 trigger='pull_request' 일 때만 pr_id 를
-- 요구하므로 그대로 만족한다.
-- ============================================================

ALTER TABLE public.resource_eval_runs
    DROP CONSTRAINT IF EXISTS resource_eval_runs_trigger_check;

ALTER TABLE public.resource_eval_runs
    ADD CONSTRAINT resource_eval_runs_trigger_check
        CHECK (trigger IN ('creation', 'pull_request', 'manual', 'backfill'));

COMMENT ON COLUMN public.resource_eval_runs.trigger IS
    'creation=리소스 생성 시 시나리오 확보 / pull_request=병합 요청 검증(base vs head) / '
    'manual=임의 실행 / backfill=시나리오가 없던 리소스에 현재 동작 기준선을 뒤늦게 확보';
