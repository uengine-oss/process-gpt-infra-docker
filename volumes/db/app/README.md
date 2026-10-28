# 앱 스키마 (db-migrate)

`init.sql` 은 Supabase 기본 스키마와 실행 엔진 표를 만든다. 지금의 화면(프론트)이 쓰는 표·함수 — 권한(`permissions`,
`menu_role_overrides`), 가입 승인(`signup_requests`), 로그인 사전 확인(`login_precheck`), 결재·KPI·BPMN 모델 표 등 — 는
프론트 저장소 `process-gpt-vue3` 의 `supabase/migrations/` 에만 있다. 그래서 새로 설치하면 화면마다 400/404 가 났다.

`db-migrate` 서비스가 DB 와 인증(GoTrue)이 뜬 뒤 한 번 `apply.sh` 를 돌린다. 게이트웨이(nginx)는 이게 끝난 뒤에 열린다.

| 폴더 | 내용 | 적용 |
|---|---|---|
| `migrations/` | 프론트 `supabase/migrations/` 의 날짜 이름 파일 97개 — compose 가 고정한 프론트 이미지(`process-gpt:4345a16`)와 같은 커밋 | 이름 순서대로 한 번씩, `public._app_migrations` 에 기록 |
| `services/` | 서비스가 따로 가진 스키마 — memento `sql/` 8개(`process-gpt-memento:d9295f3` 와 같은 커밋, 의존 순서대로 번호). 없으면 지식 베이스 화면이 「column knowledge_files.has_text does not exist」 | 한 번씩, 기록 |
| `post/` | 보정(멱등) | 매번 |

넣지 않은 파일:

- `20260831000001_fix_tym_tenant_signup.sql`, `20260901000001_sync_tym_auth_users.sql` — 특정 고객사 테넌트(`tym`) 전용.
  적용하면 모든 사용자의 테넌트가 그쪽으로 바뀌고 가입 트리거도 그렇게 바뀌어 로그인이 깨진다.
- 날짜 이름이 아닌 `auth_audit_log.sql`, `consolidated_schema.sql`, `schema_merge.sql` — 날짜 이름 파일에 이미 들어 있는 내용의 묶음.

`post/`:

- `10-fetch-pending-task-lease.sql` — 마이그레이션 두 개가 작업 폴링 함수 `fetch_pending_task` 를 옛 인자 형태로 다시 만들어,
  deepagents 폴링이 「Could not find the function … p_lease_seconds, p_max_claims」, bpmn-extractor 가 「Could not choose the best
  candidate function」(PGRST203)로 실패한다. `init.sql` 의 임대(lease) 버전으로 되돌리고 옛 형태를 지운다.
- `20-local-single-tenant.sql` — 로컬 설치(한 회사, 테넌트 `localhost`)용 가입 처리. 가입자를 `localhost` 에 넣고 첫 가입자를
  관리자로, 이후 가입자를 승인된 사용자로 둔다(기본 스키마는 SaaS 기준이라 `process-gpt` 테넌트의 승인 대기로 넣는다).
- `30-event-type-enum.sql` — `init.sql` 의 `event_type_enum` 에 없는 값 11개(`waiting_for_user` 등)를 더한다. 없으면 bpmn-extractor 가
  사람에게 확인을 물을 때 이벤트를 못 남겨(「invalid input value for enum event_type_enum」) 질문이 화면에 오지 않고 작업이 멈춘다.

프론트 이미지 고정을 바꾸면 `migrations/` 도 같은 커밋에서 다시 가져온다:

```bash
FE=<process-gpt-vue3 checkout>; SHA=<프론트 이미지 태그>
rm volumes/db/app/migrations/*.sql
for f in $(git -C $FE ls-tree --name-only $SHA supabase/migrations/ | grep -E '/[0-9]{8}[^/]*\.sql$' | grep -v tym); do
  git -C $FE show $SHA:$f > volumes/db/app/migrations/$(basename $f)
done
```
