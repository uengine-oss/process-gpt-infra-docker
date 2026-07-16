# process-gpt-infra-docker

[process-gpt](https://github.com/uengine-oss/process-gpt) 서비스를 로컬 개발용으로 설치할 수 있도록 정리한 Docker Compose 모음입니다. Supabase(Postgres/Kong/Auth/Realtime/Storage/Studio), Neo4j, LiteLLM 프록시, nginx 게이트웨이, process-gpt 마이크로서비스 전체를 이 레포 하나로 기동합니다.

이 레포는 [process-gpt](https://github.com/uengine-oss/process-gpt) 레포 루트에 `process-gpt-infra-docker/` 서브모듈로도 포함되어 있습니다. `process-gpt`를 이미 클론했다면 `git submodule update --init process-gpt-infra-docker`로 바로 이 레포를 받을 수 있고, 앱 소스는 필요 없이 설치만 할 목적이면 이 레포만 단독으로 클론해도 됩니다.

## 사전 준비

- Docker / Docker Compose
- Git
- (private 이미지를 pull해야 하는 경우) GHCR 로그인:
  ```bash
  echo $GITHUB_PAT | docker login ghcr.io -u <user> --password-stdin
  ```

## 설치

```bash
cp .env.example .env
# .env를 열어 LLM API 키 등 필요한 값을 채운다
```

이미지를 그대로 pull해서 쓰는 서비스가 대부분이라 위 설정만으로 대부분 기동할 수 있습니다. `build:`가 지정된 서비스(frontend, completion, memento, deepagents, instance-classifier, strategy 등)를 소스에서 빌드하려면 그 서비스의 서브모듈을 먼저 받아야 합니다 (`--recursive`는 중첩 worktree를 서브모듈로 오인할 수 있어 피합니다):

```bash
git submodule update --init   # 필요한 서비스만 경로를 지정해도 됨: git submodule update --init services/frontend
```

### 인터랙티브 launcher로 기동

```bash
./start-all-services.sh          # 대화형 (전체 / infra만 / 개별 서비스 체크박스 선택)
.\start-all-services.ps1         # Windows PowerShell
```

```text
./start-all-services.sh                       # 인터랙티브
./start-all-services.sh all                   # 전체 서비스
./start-all-services.sh frontend memento ...  # 서비스 이름 직접 지정
./start-all-services.sh --last                # 마지막 선택 재실행
./start-all-services.sh --preset dev          # 저장해둔 preset 불러오기
```

infra(Supabase/Neo4j/LiteLLM)를 `--wait`로 먼저 띄운 뒤 선택한 서비스, 마지막으로 nginx 게이트웨이 순서로 기동합니다. 마지막 선택과 이름 붙인 preset은 `.process-gpt-state/`(git-ignored)에 저장됩니다.

### 수동으로 기동

```bash
docker compose up -d --wait <infra 서비스...>
docker compose up -d <선택 서비스...> nginx

# GHCR 미로그인 + 로컬 이미지가 있으면 pull 회피:
docker compose up -d --pull never <서비스...>
```

기동 후 확인:
- 게이트웨이(앱 진입점): http://localhost:8088
- Supabase API(Kong): http://localhost:54321 · Studio: http://localhost:3001
- Neo4j Browser: http://localhost:7474 (neo4j / bpmn-extractor를 기동한 경우)

### 정지 / 정리

```bash
./stop-all-services.sh              # 전체 정지
./stop-all-services.sh frontend     # 선택 서비스만 정지
./stop-all-services.sh --volumes    # 정지 + 볼륨 삭제
./stop-all-services.sh --wipe       # --volumes + 바인드마운트(db/data, storage, logs)까지 초기화
                                     # (Postgres가 재시작 루프에 빠졌을 때 사용)
```

### DB 스키마 변경사항 재적용

Postgres 공식 이미지는 `volumes/db/init.sql`을 **최초 기동 시 한 번만** 실행합니다. 이미 초기화된 DB에 `init.sql` 수정분을 반영하려면 (`volumes/db/data`를 지우지 않고):

```bash
./scripts/migrate-db.sh
```

`init.sql`은 반복 실행해도 안전하도록(`CREATE OR REPLACE FUNCTION`, `CREATE TABLE/INDEX IF NOT EXISTS`, 트리거 앞 `DROP TRIGGER IF EXISTS`) 유지해야 이 스크립트가 정상 동작합니다.

## 디렉터리 구성

```
docker-compose.yml     # 전체 서비스 정의(infra + 마이크로서비스 + 게이트웨이)
nginx/nginx.conf       # nginx 게이트웨이 라우팅
litellm_config.yaml    # LiteLLM 프록시 설정
.env.example           # 환경변수 예시

start-all-services.sh / .ps1   # 인터랙티브 launcher (전체/개별 선택, --last, --preset)
stop-all-services.sh  / .ps1   # 정지/정리 (--volumes, --wipe)
scripts/migrate-db.sh          # 이미 초기화된 DB에 init.sql 변경분 재적용

services/               # build: 대상 서비스 소스 (서브모듈 — 각각 별도 레포)
  frontend/, completion/, memento/, deepagents/,
  base-agent-langchain-react/, instance-classifier/, strategy/ ...

volumes/
  api/kong.yml           # Kong 라우팅 설정
  db/*.sql, db/init/     # Postgres 초기화 스키마/시드
  email-templates/       # Supabase Auth 메일 템플릿
  functions/             # Supabase Edge Functions
  pooler/                # Supavisor pooler 설정
  storage/                # Supabase Storage 로컬 백엔드 (빈 stub)
```

`volumes/db/data/`(Postgres 런타임 데이터)와 `volumes/logs/`는 이 레포에 포함되지 않습니다(로컬 기동 시 자동 생성되며 커밋 대상이 아닙니다). `.process-gpt-state/`(launcher가 저장하는 마지막 선택/preset)도 git-ignored입니다.
