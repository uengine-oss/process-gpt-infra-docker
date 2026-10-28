-- proc_def_approval_state: 'cancelled' 상태 추가
ALTER TABLE proc_def_approval_state
  DROP CONSTRAINT IF EXISTS proc_def_approval_state_state_check;

ALTER TABLE proc_def_approval_state
  ADD CONSTRAINT proc_def_approval_state_state_check
  CHECK (state IN ('draft', 'review', 'approved_level1', 'approved_level2', 'confirmed', 'rejected', 'cancelled'));
