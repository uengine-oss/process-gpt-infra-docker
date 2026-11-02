ALTER TABLE public.proc_def
    ADD COLUMN IF NOT EXISTS saved_at timestamptz NULL;
