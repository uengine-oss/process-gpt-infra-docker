-- ============================================================================
-- audit_policy 도메인 컬럼 추가
-- domains: 도메인 ID 배열 (multi-select). 도메인 마스터는 configuration.metrics.domains
-- 에서 관리되므로 여기서는 ID 만 저장하고 표시 이름/색상은 렌더 시점에 매핑한다.
-- ============================================================================
ALTER TABLE public.audit_policy ADD COLUMN IF NOT EXISTS domains TEXT[] NOT NULL DEFAULT '{}';

CREATE INDEX IF NOT EXISTS idx_audit_policy_domains
    ON public.audit_policy USING GIN (domains);

COMMENT ON COLUMN public.audit_policy.domains IS '연결된 도메인 ID 배열 (configuration.metrics.domains 의 id)';
