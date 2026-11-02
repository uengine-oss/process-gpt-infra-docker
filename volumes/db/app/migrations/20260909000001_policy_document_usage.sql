-- One library entry can be referenced by many saved process elements.
ALTER TABLE public.audit_policy ADD COLUMN IF NOT EXISTS file_bucket text NOT NULL DEFAULT 'files';
CREATE INDEX IF NOT EXISTS audit_policy_storage_identity
    ON public.audit_policy(tenant_id, file_bucket, file_path) WHERE kind = 'file';

CREATE TABLE public.policy_document_usage (
    tenant_id text NOT NULL,
    policy_id uuid NOT NULL REFERENCES public.audit_policy(id) ON DELETE RESTRICT,
    process_id text NOT NULL,
    element_id text NOT NULL,
    PRIMARY KEY (tenant_id, policy_id, process_id, element_id),
    FOREIGN KEY (tenant_id, process_id) REFERENCES public.proc_def(tenant_id, id) ON UPDATE CASCADE ON DELETE CASCADE
);
CREATE INDEX policy_document_usage_process ON public.policy_document_usage(tenant_id, process_id);
CREATE INDEX policy_document_usage_policy ON public.policy_document_usage(policy_id);
ALTER TABLE public.policy_document_usage ENABLE ROW LEVEL SECURITY;
CREATE POLICY policy_document_usage_read ON public.policy_document_usage FOR SELECT TO authenticated
    USING (tenant_id = public.tenant_id());
GRANT SELECT ON public.policy_document_usage TO authenticated;
REVOKE ALL ON public.policy_document_usage FROM anon;
DO $$ BEGIN
    IF to_regprocedure('public.membership_approved()') IS NOT NULL THEN
        EXECUTE 'CREATE POLICY membership_access_gate ON public.policy_document_usage AS RESTRICTIVE TO authenticated
            USING (public.membership_approved())';
    END IF;
END $$;
-- Existing audit_policy policies are permissive; a restrictive tenant guard applies to all of them.
CREATE POLICY audit_policy_tenant_guard ON public.audit_policy AS RESTRICTIVE TO authenticated
    USING (tenant_id = public.tenant_id()) WITH CHECK (tenant_id = public.tenant_id());

-- Namespace prefixes may vary between imported BPMN files. XMLTABLE decodes
-- XML entities and CDATA before the extension JSON is read.
CREATE OR REPLACE FUNCTION public.bpmn_policy_attachments(document text)
RETURNS TABLE(element_id text, attachment jsonb)
LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
DECLARE element record; payload jsonb; files jsonb;
BEGIN
    IF document IS NULL OR NOT xml_is_well_formed_document(document) THEN RETURN; END IF;
    FOR element IN
        SELECT x.* FROM XMLTABLE(
            '//*[local-name()="dataObjectReference" or local-name()="dataStoreReference"]'
            PASSING (document::xml) COLUMNS
                id text PATH '@id',
                props text PATH '*[local-name()="extensionElements"]/*[local-name()="properties"]/*[local-name()="json"]',
                props_attr text PATH '*[local-name()="extensionElements"]/*[local-name()="properties"]/@json'
        ) AS x
    LOOP
        IF element.id IS NULL OR COALESCE(element.props_attr, element.props) IS NULL THEN CONTINUE; END IF;
        BEGIN
            payload := COALESCE(element.props_attr, element.props)::jsonb;
        EXCEPTION WHEN invalid_text_representation THEN CONTINUE;
        END;
        files := payload->'dataAttachmentFile';
        IF jsonb_typeof(files) = 'object' THEN files := jsonb_build_array(files); END IF;
        IF jsonb_typeof(files) IS DISTINCT FROM 'array' THEN CONTINUE; END IF;
        RETURN QUERY SELECT element.id, f.value FROM jsonb_array_elements(files) f
            WHERE jsonb_typeof(f.value) = 'object'
              AND jsonb_typeof(f.value->'path') = 'string' AND length(f.value->>'path') > 0;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_process_policy_documents()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE item record; document_id uuid; bucket_name text; file_path_value text;
BEGIN
    DELETE FROM public.policy_document_usage WHERE tenant_id = NEW.tenant_id AND process_id = NEW.id;
    IF NEW.isdeleted OR NEW.deleted_at IS NOT NULL OR NEW.tenant_id IS NULL THEN RETURN NEW; END IF;
    FOR item IN SELECT * FROM (
        SELECT * FROM public.bpmn_policy_attachments(NEW.bpmn)
        UNION
        SELECT * FROM public.bpmn_policy_attachments(NEW.definition->>'tobe_bpmn')
    ) attachments
        ORDER BY COALESCE(NULLIF(attachment->>'bucket', ''), 'files'), attachment->>'path', element_id
    LOOP
        bucket_name := COALESCE(NULLIF(item.attachment->>'bucket', ''), 'files');
        file_path_value := item.attachment->>'path';
        -- Two processes saving the same legacy attachment must not create duplicates.
        PERFORM pg_advisory_xact_lock(hashtextextended(NEW.tenant_id || '/' || bucket_name || '/' || file_path_value, 0));
        SELECT id INTO document_id FROM public.audit_policy
            WHERE tenant_id = NEW.tenant_id AND kind = 'file' AND file_bucket = bucket_name
              AND file_path = file_path_value AND deleted_at IS NULL
            ORDER BY created_at, id LIMIT 1 FOR UPDATE;
        IF document_id IS NULL THEN
            -- A deleted library file cannot be silently resurrected by a stale editor.
            IF EXISTS (SELECT 1 FROM public.audit_policy WHERE tenant_id = NEW.tenant_id
                AND kind = 'file' AND file_bucket = bucket_name AND file_path = file_path_value AND deleted_at IS NOT NULL) THEN
                RAISE EXCEPTION '삭제된 정책문서입니다. 첨부를 해제하고 다시 선택해 주세요.';
            END IF;
            INSERT INTO public.audit_policy(tenant_id, name, kind, file_path, file_bucket, file_size_bytes, author_id, author_name)
            VALUES (NEW.tenant_id, COALESCE(NULLIF(item.attachment->>'fileName', ''), file_path_value),
                'file', file_path_value, bucket_name,
                CASE WHEN item.attachment->>'size' ~ '^[0-9]{1,15}$' THEN (item.attachment->>'size')::bigint END,
                NEW.owner, (SELECT username FROM public.users WHERE id::text = NEW.owner AND tenant_id = NEW.tenant_id LIMIT 1))
            RETURNING id INTO document_id;
        END IF;
        INSERT INTO public.policy_document_usage(tenant_id, policy_id, process_id, element_id)
            VALUES (NEW.tenant_id, document_id, NEW.id, item.element_id) ON CONFLICT DO NOTHING;
    END LOOP;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.sync_process_policy_documents() FROM PUBLIC;
CREATE TRIGGER proc_def_policy_documents AFTER INSERT OR UPDATE OF bpmn, definition, isdeleted, deleted_at ON public.proc_def
    FOR EACH ROW EXECUTE FUNCTION public.sync_process_policy_documents();

-- Keep shared attachments downloadable: detach them in all processes first.
CREATE FUNCTION public.protect_used_policy_document()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.deleted_at IS NOT DISTINCT FROM OLD.deleted_at AND NEW.file_path IS NOT DISTINCT FROM OLD.file_path
            AND NEW.file_bucket IS NOT DISTINCT FROM OLD.file_bucket AND NEW.tenant_id IS NOT DISTINCT FROM OLD.tenant_id
            AND NEW.kind IS NOT DISTINCT FROM OLD.kind THEN RETURN NEW; END IF;
    END IF;
    IF EXISTS (SELECT 1 FROM public.policy_document_usage WHERE policy_id = OLD.id) THEN
        RAISE EXCEPTION '사용 중인 정책문서는 삭제하거나 파일을 변경할 수 없습니다. 프로세스에서 첨부를 먼저 해제해 주세요.';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.protect_used_policy_document() FROM PUBLIC;
CREATE TRIGGER audit_policy_protect_usage BEFORE DELETE OR UPDATE ON public.audit_policy
    FOR EACH ROW EXECUTE FUNCTION public.protect_used_policy_document();

-- Backfill from saved XML; does not change the BPMN or its version history.
UPDATE public.proc_def SET bpmn = bpmn
    WHERE NOT isdeleted AND deleted_at IS NULL
      AND (bpmn LIKE '%dataAttachmentFile%' OR definition->>'tobe_bpmn' LIKE '%dataAttachmentFile%');
NOTIFY pgrst, 'reload schema';
