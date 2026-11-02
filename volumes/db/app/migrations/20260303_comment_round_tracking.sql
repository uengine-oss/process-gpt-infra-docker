-- Add submission_round column to proc_def_comments
ALTER TABLE proc_def_comments
  ADD COLUMN IF NOT EXISTS submission_round INTEGER DEFAULT 1;

-- Index for efficient round filtering
CREATE INDEX IF NOT EXISTS idx_proc_def_comments_round
  ON proc_def_comments (proc_def_id, submission_round);
