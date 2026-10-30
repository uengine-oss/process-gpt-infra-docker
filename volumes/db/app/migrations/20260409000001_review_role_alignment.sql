-- Review board role alignment
-- - reviewer+: comment, request_reopen
-- - editor+: submit / approve / reject / end public feedback
-- - owner+: publish / approve_reopen / reject_reopen

BEGIN;

ALTER TABLE public.proc_def_approval_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "proc_def_approval_state_insert_editor" ON public.proc_def_approval_state;
DROP POLICY IF EXISTS "proc_def_approval_state_update_editor" ON public.proc_def_approval_state;
DROP POLICY IF EXISTS "proc_def_approval_state_insert_role_aligned" ON public.proc_def_approval_state;
DROP POLICY IF EXISTS "proc_def_approval_state_update_role_aligned" ON public.proc_def_approval_state;

CREATE POLICY "proc_def_approval_state_insert_role_aligned" ON public.proc_def_approval_state
  FOR INSERT
  WITH CHECK (
    CASE
      WHEN state IN ('published', 'archived') THEN public.has_role_at_least('owner')
      WHEN state = 'reopen_requested' THEN public.has_role_at_least('reviewer')
      ELSE public.has_role_at_least('editor')
    END
  );

CREATE POLICY "proc_def_approval_state_update_role_aligned" ON public.proc_def_approval_state
  FOR UPDATE
  USING (
    public.has_role_at_least('editor')
    OR (public.has_role_at_least('reviewer') AND state = 'published')
    OR (public.has_role_at_least('owner') AND state = 'reopen_requested')
  )
  WITH CHECK (
    CASE
      WHEN state IN ('published', 'archived') THEN public.has_role_at_least('owner')
      WHEN state = 'reopen_requested' THEN public.has_role_at_least('reviewer')
      ELSE public.has_role_at_least('editor')
    END
  );

ALTER TABLE public.proc_def_approval_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "proc_def_approval_history_insert_editor" ON public.proc_def_approval_history;
DROP POLICY IF EXISTS "proc_def_approval_history_insert_role_aligned" ON public.proc_def_approval_history;

CREATE POLICY "proc_def_approval_history_insert_role_aligned" ON public.proc_def_approval_history
  FOR INSERT
  WITH CHECK (
    CASE
      WHEN action IN ('comment', 'request_reopen') THEN public.has_role_at_least('reviewer')
      WHEN action IN ('publish', 'approve_reopen', 'reject_reopen') THEN public.has_role_at_least('owner')
      ELSE public.has_role_at_least('editor')
    END
  );

COMMIT;
