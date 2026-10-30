-- 조직도 구성원 사전등록: 이메일이 일치하는 사용자가 가입하면 팀/권한을 즉시 적용한다.

CREATE TABLE IF NOT EXISTS public.pending_org_members (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id text NOT NULL REFERENCES public.tenants(id) ON UPDATE CASCADE ON DELETE CASCADE,
    email text NOT NULL,
    team_id text NOT NULL,
    role text NOT NULL DEFAULT 'viewer'
        CHECK (role IN ('admin', 'owner', 'editor', 'reviewer', 'viewer')),
    permission_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid DEFAULT auth.uid(),
    CONSTRAINT pending_org_members_tenant_email_key UNIQUE (tenant_id, email)
);

CREATE UNIQUE INDEX IF NOT EXISTS pending_org_members_tenant_email_ci_key
    ON public.pending_org_members (tenant_id, lower(btrim(email)));

ALTER TABLE public.pending_org_members ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pending_org_members_select ON public.pending_org_members;
DROP POLICY IF EXISTS pending_org_members_modify ON public.pending_org_members;
CREATE POLICY pending_org_members_select ON public.pending_org_members
    FOR SELECT USING (public.has_role_at_least('viewer'));
CREATE POLICY pending_org_members_modify ON public.pending_org_members
    FOR ALL USING (public.has_role_at_least('admin'))
    WITH CHECK (public.has_role_at_least('admin'));

COMMENT ON TABLE public.pending_org_members IS
    '가입 전 조직도 배치/권한 예약. 가입 이메일 매칭 후 실제 users 행에 적용되고 삭제된다.';

-- 조직도 JSON 안의 사전등록 노드를 실제 auth user id로 바꾼다.
CREATE OR REPLACE FUNCTION public.replace_pending_org_member(
    value jsonb,
    pending_id text,
    actual_id text,
    actual_name text,
    actual_email text,
    actual_role text
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    item jsonb;
    result jsonb := '[]'::jsonb;
BEGIN
    IF jsonb_typeof(value) = 'array' THEN
        FOR item IN SELECT jsonb_array_elements(value)
        LOOP
            result := result || jsonb_build_array(public.replace_pending_org_member(
                item, pending_id, actual_id, actual_name, actual_email, actual_role
            ));
        END LOOP;
        RETURN result;
    ELSIF jsonb_typeof(value) = 'object' THEN
        IF value->>'id' = pending_id AND COALESCE((value->'data'->>'isTeam')::boolean, false) = false THEN
            value := jsonb_set(value, '{id}', to_jsonb(actual_id));
            value := jsonb_set(value, '{name}', to_jsonb(actual_name));
            value := jsonb_set(value, '{data,id}', to_jsonb(actual_id), true);
            value := jsonb_set(value, '{data,name}', to_jsonb(actual_name), true);
            value := jsonb_set(value, '{data,username}', to_jsonb(actual_name), true);
            value := jsonb_set(value, '{data,email}', to_jsonb(actual_email), true);
            value := jsonb_set(value, '{data,role}', to_jsonb(actual_role), true);
            value := value #- '{data,pending}';
        END IF;

        SELECT COALESCE(jsonb_object_agg(key, public.replace_pending_org_member(
            val, pending_id, actual_id, actual_name, actual_email, actual_role
        )), '{}'::jsonb)
        INTO value
        FROM jsonb_each(value) AS entry(key, val);
    END IF;
    RETURN value;
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_pending_org_member_on_signup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    assignment public.pending_org_members%ROWTYPE;
    signup_tenant text;
    display_name text;
    assigned_team_name text;
BEGIN
    signup_tenant := COALESCE(
        NULLIF(NEW.raw_app_meta_data->>'tenant_id', ''),
        NULLIF(NEW.raw_user_meta_data->>'tenant_id', '')
    );
    IF signup_tenant IS NULL OR NEW.email IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT * INTO assignment
    FROM public.pending_org_members
    WHERE tenant_id = signup_tenant
      AND lower(btrim(email)) = lower(btrim(NEW.email))
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    display_name := COALESCE(NULLIF(NEW.raw_user_meta_data->>'name', ''), split_part(NEW.email, '@', 1));

    WITH RECURSIVE nodes(node) AS (
        SELECT value->'chart'
        FROM public.configuration
        WHERE tenant_id = assignment.tenant_id AND key = 'organization'
        UNION ALL
        SELECT child
        FROM nodes, LATERAL jsonb_array_elements(COALESCE(nodes.node->'children', '[]'::jsonb)) child
    )
    SELECT COALESCE(node->'data'->>'name', node->>'name') INTO assigned_team_name
    FROM nodes WHERE node->>'id' = assignment.team_id LIMIT 1;

    INSERT INTO public.users (
        id, username, email, is_admin, role, tenant_id,
        department_id, department_name, permission_ids
    )
    VALUES (
        NEW.id, display_name, NEW.email, assignment.role = 'admin', assignment.role,
        assignment.tenant_id, assignment.team_id, assigned_team_name, assignment.permission_ids
    )
    ON CONFLICT (id, tenant_id) DO UPDATE SET
        username = EXCLUDED.username,
        email = EXCLUDED.email,
        is_admin = EXCLUDED.is_admin,
        role = EXCLUDED.role,
        department_id = EXCLUDED.department_id,
        department_name = EXCLUDED.department_name,
        permission_ids = EXCLUDED.permission_ids;

    UPDATE public.configuration
    SET value = jsonb_set(
        value,
        '{chart}',
        public.replace_pending_org_member(
            value->'chart', assignment.id::text, NEW.id::text,
            display_name, NEW.email, assignment.role
        )
    )
    WHERE tenant_id = assignment.tenant_id AND key = 'organization';

    DELETE FROM public.pending_org_members WHERE id = assignment.id;
    RETURN NEW;
END;
$$;

-- 같은 이벤트의 기존 테넌트/users 동기화 trigger 뒤에 실행되도록 이름을 뒤쪽으로 둔다.
DROP TRIGGER IF EXISTS trg_zz_apply_pending_org_member ON auth.users;
CREATE TRIGGER trg_zz_apply_pending_org_member
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.apply_pending_org_member_on_signup();

NOTIFY pgrst, 'reload schema';
