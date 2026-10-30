-- Migration: AI Copilot 답변 누적 테이블
-- Date: 2026-05-29
-- Description: 사용자별 BPMN Copilot Q&A 영구 누적 보관 (재진입 시 LLM 재호출 없이 이전 답변 회상)

-- =====================================================
-- 1. AI Copilot 답변 누적 테이블
-- =====================================================

CREATE TABLE IF NOT EXISTS proc_def_copilot_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    proc_def_id TEXT NOT NULL,          -- 대상 프로세스 정의 ID
    question TEXT NOT NULL,             -- 사용자가 입력한 질문
    answer TEXT,                        -- LLM 응답 본문
    created_by TEXT NOT NULL,           -- 작성자 ID (개인별 누적의 기준키)
    tenant_id TEXT DEFAULT 'default',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 인덱스: 입장 시 (proc_def_id, created_by) 조건으로 본인 Q&A 만 조회
CREATE INDEX IF NOT EXISTS idx_proc_def_copilot_log_def_user
    ON proc_def_copilot_log(proc_def_id, created_by);
CREATE INDEX IF NOT EXISTS idx_proc_def_copilot_log_tenant
    ON proc_def_copilot_log(tenant_id);

-- =====================================================
-- 2. RLS 정책 (Row Level Security)
-- =====================================================

ALTER TABLE proc_def_copilot_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "proc_def_copilot_log_select_policy" ON proc_def_copilot_log
    FOR SELECT USING (true);

CREATE POLICY "proc_def_copilot_log_insert_policy" ON proc_def_copilot_log
    FOR INSERT WITH CHECK (true);

CREATE POLICY "proc_def_copilot_log_delete_policy" ON proc_def_copilot_log
    FOR DELETE USING (true);
