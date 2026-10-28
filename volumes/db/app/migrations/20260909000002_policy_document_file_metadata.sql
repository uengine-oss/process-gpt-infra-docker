-- Older BPMN attachments stored only a bucket/path/name. Recover their size
-- from the actual object without downloading it or requiring a BPMN resave.
CREATE OR REPLACE FUNCTION public.fill_policy_document_file_size()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NEW.kind = 'file' AND NEW.file_size_bytes IS NULL THEN
        SELECT COALESCE(
            CASE WHEN metadata->>'size' ~ '^[0-9]{1,15}$' THEN (metadata->>'size')::bigint END,
            CASE WHEN metadata->>'contentLength' ~ '^[0-9]{1,15}$' THEN (metadata->>'contentLength')::bigint END
        ) INTO NEW.file_size_bytes
        FROM storage.objects
        WHERE bucket_id = NEW.file_bucket AND name = NEW.file_path;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.fill_policy_document_file_size() FROM PUBLIC;
DROP TRIGGER IF EXISTS audit_policy_fill_file_size ON public.audit_policy;
CREATE TRIGGER audit_policy_fill_file_size
    BEFORE INSERT OR UPDATE OF file_path, file_bucket, file_size_bytes ON public.audit_policy
    FOR EACH ROW EXECUTE FUNCTION public.fill_policy_document_file_size();

UPDATE public.audit_policy SET file_size_bytes = NULL
    WHERE kind = 'file' AND file_size_bytes IS NULL;
