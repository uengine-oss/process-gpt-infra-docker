-- =============================================================================
-- audit_policy 삭제자 컬럼 통일 + deleted_by 자동 채움 트리거 연결 (PAL)
--
-- pi-system-web 의 20260519_unify_deleted_by.sql / 20260519_deleted_by_auto_fill_trigger.sql
-- 중 audit_policy 부분만 발췌·멱등화한 적응 마이그레이션.
--   - task_property_schema 부분은 20260519_pal_recycle_deleted_by.sql 이 이미 커버한다.
--   - audit_policy: deleted_by_{id,name,team} 3컬럼 -> 단일 deleted_by (TEXT)
--     기존 데이터는 "이름\n(팀)" 포맷으로 합쳐 보존 후 옛 컬럼 drop.
--   - set_deleted_by_from_jwt() 트리거(20260519_pal_recycle_deleted_by.sql 정의)를
--     audit_policy 에도 연결한다.
-- =============================================================================

ALTER TABLE IF EXISTS public.audit_policy
    ADD COLUMN IF NOT EXISTS deleted_by TEXT DEFAULT NULL;

DO $$
BEGIN
    IF to_regclass('public.audit_policy') IS NULL THEN
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'audit_policy' AND column_name = 'deleted_by_name'
    ) THEN
        UPDATE public.audit_policy
        SET deleted_by = CASE
                WHEN deleted_by_name IS NOT NULL AND deleted_by_team IS NOT NULL
                    THEN deleted_by_name || E'\n(' || deleted_by_team || ')'
                WHEN deleted_by_name IS NOT NULL
                    THEN deleted_by_name
                ELSE NULL
            END
        WHERE deleted_by IS NULL
          AND (deleted_by_name IS NOT NULL OR deleted_by_team IS NOT NULL);
    END IF;

    ALTER TABLE public.audit_policy DROP COLUMN IF EXISTS deleted_by_id;
    ALTER TABLE public.audit_policy DROP COLUMN IF EXISTS deleted_by_name;
    ALTER TABLE public.audit_policy DROP COLUMN IF EXISTS deleted_by_team;

    COMMENT ON COLUMN public.audit_policy.deleted_by IS
    '삭제자 표시 문자열. 포맷: "이름\n(팀)". 익명/조회 실패 시 NULL.';

    IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public' AND p.proname = 'set_deleted_by_from_jwt'
    ) THEN
        DROP TRIGGER IF EXISTS trg_set_deleted_by_audit_policy ON public.audit_policy;
        CREATE TRIGGER trg_set_deleted_by_audit_policy
            BEFORE UPDATE ON public.audit_policy
            FOR EACH ROW EXECUTE FUNCTION public.set_deleted_by_from_jwt();
    END IF;
END $$;
