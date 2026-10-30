-- 1단계(검토) 승인 완료 후에도 2단계(공람)로 넘어가지 못한 리뷰 건 백필.
--
-- 배경:
--   본사(HQ) + 현업(Field) 병렬 승인 시절의 전이 조건이 남아 있어
--   approve_field 는 hq_status = 'approved' 일 때만 public_feedback 으로 넘어갔다.
--   본사 단계가 UI 에서 제거된 뒤 hq_status 는 영구 'pending' 으로 남았고,
--   1단계 승인이 끝난 건들이 state = 'in_review' 에 그대로 멈춰 있었다.
--   애플리케이션 쪽 게이트는 제거했고(ProcessGPTBackend._changeApprovalState),
--   이 마이그레이션은 이미 멈춰 있던 기존 건을 2단계로 이동시킨다.
--
-- 공람 기간:
--   실제 공람 노출이 지금까지 이뤄지지 않았으므로 시작일을 NOW() 로 잡아
--   백필 시점부터 30일 공람을 보장한다. (원래 승인 시각은 이력 코멘트에 기록)

DO $$
DECLARE
    rec RECORD;
    moved_count INTEGER := 0;
BEGIN
    FOR rec IN
        SELECT id, proc_def_id, tenant_id, state, field_reviewed_at, field_reviewer_name
        FROM public.proc_def_approval_state
        WHERE state IN ('in_review', 'review')
          AND field_status = 'approved'
        FOR UPDATE
    LOOP
        UPDATE public.proc_def_approval_state
        SET state = 'public_feedback',
            public_feedback_started_at = NOW(),
            public_feedback_ends_at = NOW() + INTERVAL '30 days',
            public_feedback_auto_transitioned = FALSE,
            updated_at = NOW()
        WHERE id = rec.id;

        INSERT INTO public.proc_def_approval_history
            (proc_def_id, review_id, action, from_state, to_state, actor_id, actor_name, comment, tenant_id)
        VALUES
            (rec.proc_def_id, rec.id, 'approve_field', rec.state, 'public_feedback',
             'system', 'System',
             '1단계 승인 완료 건 2단계 전환 백필 (원 승인 시각: '
                 || COALESCE(to_char(rec.field_reviewed_at, 'YYYY-MM-DD HH24:MI'), '미기록')
                 || COALESCE(', 승인자: ' || rec.field_reviewer_name, '') || ')',
             rec.tenant_id);

        -- 공람 진입 스냅샷 (앱의 자동 공람 진입과 동일하게 현재 BPMN 기록). 중복 방지.
        INSERT INTO public.proc_def_snapshots
            (review_id, proc_def_id, stage, major_version, minor_version, bpmn_xml, tenant_id)
        SELECT rec.id, rec.proc_def_id, 'public_feedback', pas.major_version, pas.minor_version, pd.bpmn, rec.tenant_id
        FROM public.proc_def pd
        JOIN public.proc_def_approval_state pas ON pas.id = rec.id
        WHERE pd.id = rec.proc_def_id
          AND pd.tenant_id = rec.tenant_id
          AND pd.bpmn IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM public.proc_def_snapshots s
              WHERE s.review_id = rec.id AND s.stage = 'public_feedback'
          );

        moved_count := moved_count + 1;
    END LOOP;

    RAISE NOTICE '[backfill] 1단계 승인 완료 → 2단계 전환: % 건', moved_count;
END $$;
