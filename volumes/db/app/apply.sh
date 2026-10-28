#!/bin/bash
# 앱 스키마 적용 — db-migrate 서비스가 DB·인증(GoTrue)이 뜬 뒤 한 번 돌린다.
#
#   migrations/*.sql  프론트(process-gpt-vue3) supabase/migrations 를, compose 가 고정한 프론트 이미지와 같은 커밋에서
#                     가져온 것. 이름 순서대로 한 번씩만 적용하고 public._app_migrations 에 기록한다.
#                     (특정 고객사 전용 파일은 넣지 않는다 — README 참고)
#   post/*.sql        매번 적용하는 보정(멱등). 마이그레이션이 덮어쓴 함수 되돌리기, 로컬 단일 회사 가입 처리.
set -euo pipefail
cd "$(dirname "$0")"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q -h "${PGHOST:-db}" -p "${PGPORT:-5432}" -U "${PGUSER:-supabase_admin}" -d "${PGDATABASE:-postgres}")

"${PSQL[@]}" -c "create table if not exists public._app_migrations (name text primary key, applied_at timestamptz not null default now());"

applied=0
for f in migrations/*.sql; do
  name=$(basename "$f")
  done_already=$("${PSQL[@]}" -tA -c "select 1 from public._app_migrations where name = '$name';")
  [ -n "$done_already" ] && continue
  echo "apply $name"
  "${PSQL[@]}" -f "$f"
  "${PSQL[@]}" -c "insert into public._app_migrations(name) values ('$name');"
  applied=$((applied + 1))
done

for f in post/*.sql; do
  echo "post  $(basename "$f")"
  "${PSQL[@]}" -f "$f"
done

# PostgREST 가 새 표·함수를 바로 보게
"${PSQL[@]}" -c "notify pgrst, 'reload schema';"
echo "app schema: $applied new migration(s), $(ls post/*.sql | wc -l | tr -d ' ') post script(s)"
