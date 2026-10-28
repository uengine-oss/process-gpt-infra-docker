-- ============================================
-- Agent runtime: use public.users as source of truth
-- - add last_used_at to users for TTL tracking
-- - drop legacy agent_runtime_* tables (no longer used)
-- ============================================

-- 1) Add last_used_at for TTL
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS last_used_at timestamptz NULL;

CREATE INDEX IF NOT EXISTS idx_users_is_agent_last_used_at
  ON public.users (is_agent, last_used_at DESC);

COMMENT ON COLUMN public.users.last_used_at IS 'Agent runtime TTL tracking: last time this agent was used';

-- 2) Drop legacy tables (kept for backward compatibility previously)
DROP TABLE IF EXISTS public.agent_runtime_configs;
DROP TABLE IF EXISTS public.agent_activity;

