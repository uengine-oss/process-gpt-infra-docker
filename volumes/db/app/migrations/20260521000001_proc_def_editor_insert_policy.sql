-- Allow editor users to save process definitions through Supabase upsert.
--
-- PostgREST upsert executes INSERT ... ON CONFLICT DO UPDATE, so the INSERT
-- RLS policy is checked even when an existing proc_def row is updated.
-- Process definition creation/editing is an editor+ capability; publishing
-- remains controlled separately by the approval/version workflow.

ALTER TABLE public.proc_def ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "proc_def_insert_owner" ON public.proc_def;
DROP POLICY IF EXISTS "proc_def_insert_editor" ON public.proc_def;

CREATE POLICY "proc_def_insert_editor" ON public.proc_def
  FOR INSERT
  WITH CHECK (public.has_role_at_least('editor'));
