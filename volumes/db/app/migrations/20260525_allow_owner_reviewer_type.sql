-- Allow review submitters to be marked distinctly on governance feedback.
ALTER TABLE public.proc_def_comments
  DROP CONSTRAINT IF EXISTS proc_def_comments_reviewer_type_check;

ALTER TABLE public.proc_def_comments
  ADD CONSTRAINT proc_def_comments_reviewer_type_check
  CHECK (reviewer_type IS NULL OR reviewer_type IN ('hq', 'field', 'owner', 'public'));
