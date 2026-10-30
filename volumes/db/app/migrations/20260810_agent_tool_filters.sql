-- ============================================
-- Agent MCP tool filters
-- - add tool_filters to users: per-MCP-server allow-list of individual
--   tool names for an agent (null/missing server key = all tools allowed)
-- ============================================

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS tool_filters jsonb NULL;

COMMENT ON COLUMN public.users.tool_filters IS
  'Agent MCP tool allow-list: {"<mcp_server_name>": ["<tool_name>", ...]}. Missing key or empty array = all tools from that server allowed.';
