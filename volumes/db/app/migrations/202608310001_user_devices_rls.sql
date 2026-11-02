-- =============================================================================
-- 기기 토큰을 본인만 다루게 한다
--
-- 지금 상태
--   user_devices 는 행 수준 보안이 꺼져 있고, anon 과 authenticated 에게
--   SELECT · INSERT · UPDATE · DELETE 가 모두 열려 있다.
--
-- 그래서 생기는 일
--   이 테이블은 "어느 사용자에게 푸시를 보낼 때 어느 기기로 보낼지" 를 담는다.
--   남의 행을 고칠 수 있으면, 자기 기기 토큰을 남의 이메일로 적어 넣어
--   **그 사람의 알림을 자기 폰으로 받을 수 있다.** 결재 요청이나 업무 내용이
--   그대로 넘어간다. 읽기도 열려 있어 전체 기기 토큰 목록을 가져갈 수 있다.
--
--   지금까지 드러나지 않은 것은 이 테이블에 토큰을 넣는 코드가 아직 없어서일
--   뿐이다. 모바일 앱이 등록을 시작하는 순간 실제 문제가 된다.
--
-- 조치
--   본인 행만 다루게 한다. 판단 근거는 로그인 세션의 이메일이고, 이것은 서버가
--   서명한 값이라 사용자가 고칠 수 없다.
--
-- 보내는 쪽은 그대로다
--   fcm_service 는 service_role 로 접근하며, 이 역할은 행 수준 보안을 지나간다.
--   따라서 발송 경로는 아무것도 바뀌지 않는다.
--
-- 남은 제약
--   기본키가 user_email 이라 사용자당 기기가 하나다. 휴대폰과 태블릿을 함께
--   쓰면 나중에 로그인한 쪽만 알림을 받는다. 여러 대를 받으려면 기본키를 바꾸고
--   읽는 쪽(fcm_service)도 함께 고쳐야 하므로 여기서는 다루지 않는다.
-- =============================================================================

ALTER TABLE public.user_devices ENABLE ROW LEVEL SECURITY;

-- 익명 사용자가 기기 토큰을 만질 이유는 없다.
REVOKE ALL ON public.user_devices FROM anon;

DROP POLICY IF EXISTS user_devices_select_own ON public.user_devices;
CREATE POLICY user_devices_select_own ON public.user_devices
    FOR SELECT TO authenticated
    USING (user_email = auth.jwt() ->> 'email');

DROP POLICY IF EXISTS user_devices_insert_own ON public.user_devices;
CREATE POLICY user_devices_insert_own ON public.user_devices
    FOR INSERT TO authenticated
    WITH CHECK (user_email = auth.jwt() ->> 'email');

-- USING 과 WITH CHECK 을 모두 둔다. USING 만 있으면 자기 행을 남의 이메일로
-- 바꿔치기하는 UPDATE 가 통과한다.
DROP POLICY IF EXISTS user_devices_update_own ON public.user_devices;
CREATE POLICY user_devices_update_own ON public.user_devices
    FOR UPDATE TO authenticated
    USING (user_email = auth.jwt() ->> 'email')
    WITH CHECK (user_email = auth.jwt() ->> 'email');

DROP POLICY IF EXISTS user_devices_delete_own ON public.user_devices;
CREATE POLICY user_devices_delete_own ON public.user_devices
    FOR DELETE TO authenticated
    USING (user_email = auth.jwt() ->> 'email');

COMMENT ON TABLE public.user_devices IS
  '푸시 알림을 보낼 기기. 본인 행만 읽고 쓸 수 있다(RLS). 발송은 service_role 이 한다.';
