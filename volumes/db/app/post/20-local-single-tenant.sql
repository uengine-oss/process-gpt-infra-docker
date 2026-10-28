-- 로컬 설치(한 회사, 테넌트 localhost)용 가입 처리.
--
-- 기본 스키마는 SaaS(process-gpt.io) 기준이라, 새 가입자를 테넌트 'process-gpt' 의 일반 사용자로 넣고
-- (handle_new_auth_user) 가입 승인 대기(viewer · pending)로 묶는다(guard_membership_access).
-- 로컬 설치는 브라우저가 localhost 로 접속해 테넌트가 'localhost' 이므로, 그대로 두면 가입한 사람이
-- 「이 조직에 가입되지 않은 계정입니다」로 로그인하지 못하고, 기본 모드에는 가입 승인 화면도 없다.
--
-- 여기서는 가입자를 'localhost' 테넌트에 넣고, 그 테넌트의 첫 가입자를 관리자(superAdmin)로,
-- 이후 가입자를 승인된 일반 사용자로 둔다. 여러 회사를 받는 운영 설치에는 쓰지 않는다.
-- (멱등 — 몇 번 실행해도 같다)

INSERT INTO public.tenants (id) VALUES ('localhost') ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  first_member boolean;
BEGIN
  SELECT NOT EXISTS (
    SELECT 1 FROM public.users
    WHERE tenant_id = 'localhost' AND NOT COALESCE(is_agent, false)
  ) INTO first_member;

  INSERT INTO public.users (id, username, email, tenant_id, is_admin, role)
  VALUES (new.id, COALESCE(new.raw_user_meta_data ->> 'name', new.email), new.email, 'localhost', false, 'user')
  ON CONFLICT (id, tenant_id) DO NOTHING;

  -- guard_membership_access 가 INSERT 때 pending · viewer 로 바꾸므로 여기서 승인한다
  -- (가입은 auth 역할로 실행되어 UPDATE 가드를 통과한다).
  UPDATE public.users
  SET membership_status = 'approved',
      role = CASE WHEN first_member THEN 'superAdmin' ELSE 'user' END,
      is_admin = first_member
  WHERE id = new.id AND tenant_id = 'localhost';

  DELETE FROM public.signup_requests WHERE user_id = new.id AND tenant_id = 'localhost';

  IF first_member THEN
    UPDATE public.tenants SET owner = new.id WHERE id = 'localhost' AND owner IS NULL;
  END IF;

  RETURN new;
END;
$function$;
