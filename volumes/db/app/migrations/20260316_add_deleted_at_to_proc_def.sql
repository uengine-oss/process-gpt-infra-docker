-- Add soft delete support to proc_def and tb_bpmn_model tables
-- deleted_at: soft delete timestamp (NULL = active)
-- deleted_by: user who performed the deletion
-- deleted_from: original location in procMap (mega_id, major_id) for restoring

-- proc_def
ALTER TABLE public.proc_def ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ DEFAULT NULL;
ALTER TABLE public.proc_def ADD COLUMN IF NOT EXISTS deleted_by TEXT DEFAULT NULL;
ALTER TABLE public.proc_def ADD COLUMN IF NOT EXISTS deleted_from JSONB DEFAULT NULL;

CREATE INDEX IF NOT EXISTS idx_proc_def_deleted_at ON public.proc_def(deleted_at) WHERE deleted_at IS NOT NULL;

-- tb_bpmn_model (deleted_at already exists, add deleted_by)
ALTER TABLE public.tb_bpmn_model ADD COLUMN IF NOT EXISTS deleted_by TEXT DEFAULT NULL;
