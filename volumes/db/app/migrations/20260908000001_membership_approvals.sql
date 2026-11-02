-- Existing memberships keep access; new human memberships require approval.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS membership_status text NOT NULL DEFAULT 'approved';
ALTER TABLE public.users ALTER COLUMN membership_status SET DEFAULT 'pending';
ALTER TABLE public.users ADD CONSTRAINT users_membership_status_check
    CHECK (membership_status IN ('pending', 'approved', 'rejected'));

CREATE TABLE public.signup_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    tenant_id text NOT NULL,
    username text,
    email text NOT NULL,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
    reject_reason text,
    reviewed_by text,
    reviewed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (user_id, tenant_id) REFERENCES public.users(id, tenant_id) ON DELETE CASCADE,
    UNIQUE (user_id, tenant_id)
);
CREATE TABLE public.admin_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    tenant_id text NOT NULL,
    username text,
    email text NOT NULL,
    reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 2000),
    requested_role text NOT NULL CHECK (requested_role IN ('viewer','reviewer','editor','owner','admin')),
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
    reject_reason text,
    reviewed_by text,
    reviewed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (user_id, tenant_id) REFERENCES public.users(id, tenant_id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX admin_requests_one_pending ON public.admin_requests(tenant_id, user_id) WHERE status = 'pending';
CREATE INDEX signup_requests_pending ON public.signup_requests(tenant_id, status);

CREATE FUNCTION public.membership_approved() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid()
        AND tenant_id = public.tenant_id() AND membership_status = 'approved');
$$;
CREATE FUNCTION public.membership_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid()
        AND tenant_id = public.tenant_id() AND membership_status = 'approved'
        AND (is_admin OR lower(role) IN ('admin','superadmin')));
$$;

CREATE FUNCTION public.guard_membership_access() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- An upsert of an existing account must not reset its granted role.
        IF EXISTS (SELECT 1 FROM public.users WHERE id = NEW.id AND tenant_id = NEW.tenant_id) THEN
            RETURN NEW;
        END IF;
        IF COALESCE(NEW.is_agent, false) THEN
            NEW.membership_status := 'approved';
        ELSE
            NEW.membership_status := 'pending';
            NEW.role := 'viewer';
            NEW.is_admin := false;
        END IF;
    ELSE
        IF auth.role() IN ('authenticated','anon') AND NOT public.membership_admin()
            AND (NEW.role IS DISTINCT FROM OLD.role OR NEW.is_admin IS DISTINCT FROM OLD.is_admin
                OR NEW.membership_status IS DISTINCT FROM OLD.membership_status
                OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR NEW.id IS DISTINCT FROM OLD.id
                OR NEW.permission_ids IS DISTINCT FROM OLD.permission_ids
                OR NEW.is_agent IS DISTINCT FROM OLD.is_agent) THEN
            RAISE EXCEPTION '관리자만 권한과 가입 상태를 변경할 수 있습니다.' USING ERRCODE = '42501';
        END IF;
        -- Pre-registration hooks may assign roles after the auth insert. Approval still comes first.
        IF NEW.membership_status <> 'approved' THEN
            NEW.role := 'viewer';
            NEW.is_admin := false;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER guard_membership_access BEFORE INSERT OR UPDATE ON public.users
FOR EACH ROW EXECUTE FUNCTION public.guard_membership_access();

CREATE FUNCTION public.queue_membership_signup() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NEW.membership_status = 'pending' AND NOT COALESCE(NEW.is_agent, false) THEN
        INSERT INTO public.signup_requests(user_id, tenant_id, username, email)
        VALUES (NEW.id, NEW.tenant_id, NEW.username, COALESCE(NEW.email, ''))
        ON CONFLICT (user_id, tenant_id) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER queue_membership_signup AFTER INSERT ON public.users
FOR EACH ROW EXECUTE FUNCTION public.queue_membership_signup();

-- Database roles must not fall back to stale JWT privileges while membership is pending.
CREATE OR REPLACE FUNCTION public.current_user_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT COALESCE((SELECT CASE
        WHEN membership_status <> 'approved' THEN ''
        WHEN lower(role) = 'superadmin' THEN 'admin'
        WHEN public.get_role_level(role) > 0 THEN lower(role)
        WHEN is_admin THEN 'admin' ELSE 'viewer' END
        FROM public.users WHERE id = auth.uid() AND tenant_id = public.tenant_id()), '');
$$;

ALTER TABLE public.signup_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY signup_requests_read ON public.signup_requests FOR SELECT TO authenticated
    USING (tenant_id = public.tenant_id() AND (user_id = auth.uid() OR public.membership_admin()));
CREATE POLICY admin_requests_read ON public.admin_requests FOR SELECT TO authenticated
    USING (tenant_id = public.tenant_id() AND (user_id = auth.uid() OR public.membership_admin()));
GRANT SELECT ON public.signup_requests, public.admin_requests TO authenticated;
GRANT ALL ON public.signup_requests, public.admin_requests TO service_role;
REVOKE INSERT, UPDATE, DELETE ON public.signup_requests, public.admin_requests FROM authenticated, anon;

-- Restrictive policies complement existing tenant/role policies; they never grant new access.
DO $$ DECLARE t record; BEGIN
    FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND c.relrowsecurity
        AND c.relname NOT IN ('users','signup_requests','admin_requests')
        AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped)
    LOOP
        EXECUTE format('CREATE POLICY membership_access_gate ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING (public.membership_approved()) WITH CHECK (public.membership_approved())', t.relname);
    END LOOP;
END $$;
CREATE POLICY users_membership_read_gate ON public.users AS RESTRICTIVE FOR SELECT TO authenticated
    USING (tenant_id = public.tenant_id() AND (public.membership_approved() OR id = auth.uid()));

CREATE FUNCTION public.my_membership() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT COALESCE((SELECT jsonb_build_object('status', u.membership_status, 'role', u.role, 'is_admin', u.is_admin,
        'tenant_id', u.tenant_id, 'reject_reason', s.reject_reason)
        FROM public.users u LEFT JOIN public.signup_requests s ON s.user_id = u.id AND s.tenant_id = u.tenant_id
        WHERE u.id = auth.uid() AND u.tenant_id = public.tenant_id()), jsonb_build_object('status','missing'));
$$;

CREATE FUNCTION public.request_membership_role(requested_role text, reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u public.users%ROWTYPE; r public.admin_requests%ROWTYPE;
BEGIN
    SELECT * INTO u FROM public.users WHERE id = auth.uid() AND tenant_id = public.tenant_id() FOR UPDATE;
    IF NOT FOUND OR u.membership_status <> 'approved' THEN
        RAISE EXCEPTION '가입 승인 후 권한 변경을 신청할 수 있습니다.' USING ERRCODE = '42501';
    END IF;
    IF requested_role IS NULL OR requested_role NOT IN ('viewer','reviewer','editor','owner','admin') THEN
        RAISE EXCEPTION '유효한 신청 권한을 선택해 주세요.' USING ERRCODE = '22023';
    END IF;
    IF requested_role = u.role THEN RAISE EXCEPTION '현재와 다른 권한을 선택해 주세요.' USING ERRCODE = '22023'; END IF;
    IF reason IS NULL OR length(btrim(reason)) NOT BETWEEN 1 AND 2000 THEN
        RAISE EXCEPTION '신청 사유는 1~2000자로 입력해 주세요.' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.admin_requests WHERE user_id = u.id AND tenant_id = u.tenant_id AND status = 'pending') THEN
        RAISE EXCEPTION '이미 승인 대기 중인 권한 신청이 있습니다.' USING ERRCODE = '23505';
    END IF;
    INSERT INTO public.admin_requests(user_id, tenant_id, username, email, requested_role, reason)
    VALUES (u.id, u.tenant_id, u.username, u.email, requested_role, btrim(reason)) RETURNING * INTO r;
    RETURN to_jsonb(r);
END;
$$;

CREATE FUNCTION public.membership_request_counts() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE signups int; roles int;
BEGIN
    IF NOT public.membership_admin() THEN RAISE EXCEPTION '관리자 권한이 필요합니다.' USING ERRCODE = '42501'; END IF;
    SELECT count(*) INTO signups FROM public.signup_requests WHERE tenant_id = public.tenant_id() AND status = 'pending';
    SELECT count(*) INTO roles FROM public.admin_requests WHERE tenant_id = public.tenant_id() AND status = 'pending';
    RETURN jsonb_build_object('signup', signups, 'role', roles, 'total', signups + roles);
END;
$$;

CREATE FUNCTION public.review_membership_request(request_kind text, request_id uuid, decision text,
    review_reason text DEFAULT '', signup_role text DEFAULT 'viewer') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r record; table_name text; target_role text; target_status text;
BEGIN
    IF NOT public.membership_admin() THEN RAISE EXCEPTION '관리자 권한이 필요합니다.' USING ERRCODE = '42501'; END IF;
    IF request_kind NOT IN ('signup','role') OR decision NOT IN ('approved','rejected') THEN
        RAISE EXCEPTION '잘못된 승인 요청입니다.' USING ERRCODE = '22023';
    END IF;
    IF decision = 'rejected' AND length(btrim(COALESCE(review_reason,''))) NOT BETWEEN 1 AND 2000 THEN
        RAISE EXCEPTION '반려 사유를 입력해 주세요.' USING ERRCODE = '22023';
    END IF;
    table_name := CASE WHEN request_kind = 'signup' THEN 'signup_requests' ELSE 'admin_requests' END;
    EXECUTE format('SELECT * FROM public.%I WHERE id = $1 AND tenant_id = $2 FOR UPDATE', table_name)
        INTO r USING request_id, public.tenant_id();
    IF r.id IS NULL THEN RAISE EXCEPTION '신청을 찾을 수 없습니다.' USING ERRCODE = 'P0002'; END IF;
    IF r.status <> 'pending' THEN RAISE EXCEPTION '이미 처리된 신청입니다.' USING ERRCODE = '23505'; END IF;
    IF r.user_id = auth.uid() THEN RAISE EXCEPTION '본인의 신청은 다른 관리자가 처리해야 합니다.' USING ERRCODE = '42501'; END IF;
    IF decision = 'approved' THEN
        IF request_kind = 'role' THEN target_role := r.requested_role; ELSE target_role := signup_role; END IF;
        IF target_role IS NULL OR target_role NOT IN ('viewer','reviewer','editor','owner','admin') THEN
            RAISE EXCEPTION '유효한 권한을 선택해 주세요.' USING ERRCODE = '22023';
        END IF;
        SELECT membership_status INTO target_status FROM public.users
            WHERE id = r.user_id AND tenant_id = r.tenant_id FOR UPDATE;
        IF request_kind = 'role' AND target_status <> 'approved' THEN
            RAISE EXCEPTION '가입이 승인된 사용자가 아닙니다.' USING ERRCODE = '42501';
        END IF;
        UPDATE public.users SET membership_status = 'approved', role = target_role, is_admin = target_role = 'admin'
            WHERE id = r.user_id AND tenant_id = r.tenant_id;
    ELSIF request_kind = 'signup' THEN
        UPDATE public.users SET membership_status = 'rejected', role = 'viewer', is_admin = false
            WHERE id = r.user_id AND tenant_id = r.tenant_id;
    END IF;
    EXECUTE format('UPDATE public.%I SET status = $1, reject_reason = $2, reviewed_by = $3, reviewed_at = now(), updated_at = now() WHERE id = $4', table_name)
        USING decision, CASE WHEN decision = 'rejected' THEN btrim(review_reason) ELSE NULL END,
            auth.uid()::text, request_id;
    RETURN jsonb_build_object('id', request_id, 'status', decision);
END;
$$;

REVOKE ALL ON FUNCTION public.my_membership(), public.request_membership_role(text,text),
    public.membership_request_counts(), public.review_membership_request(text,uuid,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_membership(), public.request_membership_role(text,text),
    public.membership_request_counts(), public.review_membership_request(text,uuid,text,text,text) TO authenticated;
NOTIFY pgrst, 'reload schema';
