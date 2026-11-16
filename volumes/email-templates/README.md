# 이메일 템플릿 (Auth / GoTrue)

회원가입 인증, 비밀번호 재설정, 초대, 이메일 변경, 이메일 로그인 메일의 HTML 템플릿입니다.  
Auth가 메일을 보낼 때 nginx(`http://nginx:8088/email-templates/<파일>`)에서 이 HTML을 불러옵니다. 불러오지 못하면 Auth 의 기본 메일이 나갑니다.

`magic_link.html` 은 기본으로 연결되어 있습니다. 나머지 파일은 `.env` 의 `MAILER_TEMPLATES_<종류>` 에 위 주소를 넣고 auth 를 다시 만들어야 쓰입니다. 비어 있으면 Auth 의 기본 메일이 나갑니다.

## 파일별 용도

| 파일 | 발송 시점 |
|------|-----------|
| `confirmation.html` | 회원가입 후 이메일 인증 |
| `recovery.html` | 비밀번호 재설정 링크 요청 |
| `invite.html` | 이메일 초대 |
| `email_change.html` | 이메일 주소 변경 확인 |
| `magic_link.html` | 이메일 로그인 6자리 OTP 코드 (`signInWithOtp`) |

## 사용 가능한 템플릿 변수 (Go Template)

- `{{ .ConfirmationURL }}` – 인증/재설정/초대 링크 (필수로 포함해야 함)
- `{{ .Email }}` – 사용자 이메일
- `{{ .SiteURL }}` – 사이트 URL (예: SITE_URL)
- `{{ .Token }}` – 6자리 OTP (링크 대신 사용 가능)
- `{{ .TokenHash }}` – 토큰 해시 (직접 링크를 만들 때 사용)
- `{{ .RedirectTo }}` – 인증 후 리다이렉트 URL
- `{{ .NewEmail }}` – 이메일 변경 시 **새 이메일** (email_change.html에서만)
- `{{ .Data }}` – user_metadata (회원가입 시 전달한 데이터)

Auth 가 읽은 템플릿을 캐시하므로 저장해도 다음 메일에 바로 반영되지 않습니다. 바로 적용하려면 `docker compose restart auth` 를 실행합니다.

아직 이메일을 확인하지 않은 새 사용자가 `signInWithOtp` 를 호출하면 `magic_link.html` 이 아니라 `confirmation` 메일이 나갑니다.
