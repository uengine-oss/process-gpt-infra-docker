-- PAL 휴지통 공통 컬럼 및 삭제자 자동 기록.
-- 원본 마이그레이션을 기존 OSS 스키마에도 안전하게 적용할 수 있도록 멱등화했다.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'task_property_schema' AND column_name = 'deprecated_at'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'task_property_schema' AND column_name = 'deleted_at'
    ) THEN
        ALTER TABLE public.task_property_schema RENAME COLUMN deprecated_at TO deleted_at;
    END IF;
END $$;

ALTER TABLE IF EXISTS public.task_property_schema
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS deleted_by TEXT;

CREATE OR REPLACE FUNCTION public.set_deleted_by_from_jwt()
RETURNS TRIGGER AS $$
DECLARE
    jwt_claims JSONB;
    jwt_name TEXT;
    jwt_org TEXT;
BEGIN
    IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
        jwt_claims := auth.jwt();
        jwt_name := jwt_claims -> 'user_metadata' ->> 'name';
        jwt_org := jwt_claims -> 'app_metadata' ->> 'org_name';
        NEW.deleted_by := CASE
            WHEN jwt_name IS NOT NULL AND jwt_org IS NOT NULL THEN jwt_name || E'\n(' || jwt_org || ')'
            WHEN jwt_name IS NOT NULL THEN jwt_name
            ELSE 'Unknown'
        END;
    ELSIF NEW.deleted_at IS NULL AND OLD.deleted_at IS NOT NULL THEN
        NEW.deleted_by := NULL;
    ELSIF OLD.deleted_at IS NOT NULL THEN
        NEW.deleted_by := OLD.deleted_by;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    IF to_regclass('public.proc_def') IS NOT NULL THEN
        DROP TRIGGER IF EXISTS trg_set_deleted_by_proc_def ON public.proc_def;
        CREATE TRIGGER trg_set_deleted_by_proc_def
            BEFORE UPDATE ON public.proc_def
            FOR EACH ROW EXECUTE FUNCTION public.set_deleted_by_from_jwt();
    END IF;
    IF to_regclass('public.tb_bpmn_model') IS NOT NULL THEN
        DROP TRIGGER IF EXISTS trg_set_deleted_by_tb_bpmn_model ON public.tb_bpmn_model;
        CREATE TRIGGER trg_set_deleted_by_tb_bpmn_model
            BEFORE UPDATE ON public.tb_bpmn_model
            FOR EACH ROW EXECUTE FUNCTION public.set_deleted_by_from_jwt();
    END IF;
    IF to_regclass('public.task_property_schema') IS NOT NULL THEN
        DROP TRIGGER IF EXISTS trg_set_deleted_by_task_property_schema ON public.task_property_schema;
        CREATE TRIGGER trg_set_deleted_by_task_property_schema
            BEFORE UPDATE ON public.task_property_schema
            FOR EACH ROW EXECUTE FUNCTION public.set_deleted_by_from_jwt();
    END IF;
END $$;
