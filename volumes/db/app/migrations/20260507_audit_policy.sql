-- ============================================================================
-- 사내 정책문서 (Audit Policy)
-- 거버넌스 / BPMN 분석 Agent 가 활용할 컴플라이언스 PDF/CSV 또는 외부 문서
-- 링크의 메타데이터를 저장. 파일 본문은 Supabase Storage `files` 버킷의
-- uploads/ 경로에 업로드된다 (StorageBaseSupabase.uploadFile 와 동일한 컨벤션).
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.audit_policy (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id TEXT NOT NULL,

    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('file', 'link')),

    -- file 종류일 때 사용
    file_path TEXT,
    file_size_bytes BIGINT,

    -- link 종류일 때 사용
    link_url TEXT,

    author_id TEXT,
    author_name TEXT,
    author_team TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT audit_policy_kind_payload CHECK (
        (kind = 'file' AND file_path IS NOT NULL) OR
        (kind = 'link' AND link_url IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_audit_policy_tenant ON public.audit_policy (tenant_id);
CREATE INDEX IF NOT EXISTS idx_audit_policy_created ON public.audit_policy (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_policy_kind ON public.audit_policy (kind);

-- RLS
ALTER TABLE public.audit_policy ENABLE ROW LEVEL SECURITY;

CREATE POLICY "audit_policy_tenant_isolation" ON public.audit_policy
    FOR ALL TO authenticated
    USING (tenant_id = current_setting('app.tenant_id', true));

CREATE POLICY "audit_policy_authenticated_read" ON public.audit_policy
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "audit_policy_authenticated_write" ON public.audit_policy
    FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- updated_at 트리거 (update_updated_at_column 함수는 20260124_fte_config_tables.sql 에서 정의)
CREATE TRIGGER audit_policy_updated_at
    BEFORE UPDATE ON public.audit_policy
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

REVOKE ALL ON public.audit_policy FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.audit_policy TO authenticated;

COMMENT ON TABLE public.audit_policy IS '사내 정책문서 메타데이터 (BPMN 분석 Agent 참조용)';
COMMENT ON COLUMN public.audit_policy.kind IS 'file = Supabase Storage 업로드 / link = 외부 URL';
COMMENT ON COLUMN public.audit_policy.file_path IS 'kind=file 일 때, files 버킷 내 객체 경로 (예: uploads/<ts>_<filename>)';

-- ============================================================================
-- Storage 버킷: files (이미 다른 기능에서 사용 중이지만 로컬 환경에서 누락 가능)
-- ============================================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('files', 'files', true)
ON CONFLICT (id) DO NOTHING;

-- 'files' 버킷 RLS 정책 (재실행 시 기존 정책 제거 후 재생성)
DROP POLICY IF EXISTS "files_bucket_public_read"   ON storage.objects;
DROP POLICY IF EXISTS "files_bucket_public_insert" ON storage.objects;
DROP POLICY IF EXISTS "files_bucket_public_update" ON storage.objects;
DROP POLICY IF EXISTS "files_bucket_public_delete" ON storage.objects;

CREATE POLICY "files_bucket_public_read" ON storage.objects
    FOR SELECT USING (bucket_id = 'files');

CREATE POLICY "files_bucket_public_insert" ON storage.objects
    FOR INSERT WITH CHECK (bucket_id = 'files');

CREATE POLICY "files_bucket_public_update" ON storage.objects
    FOR UPDATE USING (bucket_id = 'files');

CREATE POLICY "files_bucket_public_delete" ON storage.objects
    FOR DELETE USING (bucket_id = 'files');
