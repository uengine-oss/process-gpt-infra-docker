# process-gpt-infra-docker

[process-gpt](https://github.com/uengine-oss/process-gpt) 서비스를 로컬 개발용으로 설치할 수 있도록 정리한 Docker Compose 모음입니다. Supabase(Postgres/Kong/Auth/Realtime/Storage/Studio), Neo4j, LiteLLM 프록시, nginx 게이트웨이, process-gpt 마이크로서비스들을 이 레포 하나로 기동합니다.

설치 "방법" 자체는 [process-gpt README](https://github.com/uengine-oss/process-gpt#readme)에서 안내합니다. 이 레포는 설치에 필요한 compose 파일과 설정만 담습니다.

## 사전 준비

- Docker / Docker Compose
- (private 이미지를 pull해야 하는 경우) GHCR 로그인:
  ```bash
  echo $GITHUB_PAT | docker login ghcr.io -u <user> --password-stdin
  ```

## 설치

```bash
cp .env.example .env
# .env를 열어 LLM API 키 등 필요한 값을 채운다

docker compose up -d
# 또는 특정 서비스만: docker compose up -d frontend memento
```

기동 후 확인:
- 게이트웨이(앱 진입점): http://localhost:8088
- Supabase API(Kong): http://localhost:54321 · Studio: http://localhost:3001

## 디렉터리 구성

```
docker-compose.yml     # 전체 서비스 정의(infra + 마이크로서비스 + 게이트웨이)
nginx/nginx.conf       # nginx 게이트웨이 라우팅
litellm_config.yaml    # LiteLLM 프록시 설정
.env.example           # 환경변수 예시
volumes/
  api/kong.yml          # Kong 라우팅 설정
  db/*.sql, db/init/     # Postgres 초기화 스키마/시드
  email-templates/       # Supabase Auth 메일 템플릿
  functions/              # Supabase Edge Functions
  pooler/                 # Supavisor pooler 설정
```

`volumes/db/data/`(Postgres 런타임 데이터)와 `volumes/logs/`는 이 레포에 포함되지 않습니다(로컬 기동 시 자동 생성되며 커밋 대상이 아닙니다).

## 알려진 제약

- `nginx/nginx.conf`의 `/instance-classifier/`, `/strategy-service/` 라우트는 process-gpt 쪽에 있는 최신 게이트웨이 설정을 그대로 가져온 것으로, 해당 서비스가 아직 이 `docker-compose.yml`에는 정의되어 있지 않습니다. 두 서비스가 필요하면 별도로 compose 정의를 추가해야 하며, 그 전까지는 두 경로만 502를 반환합니다(nginx 자체 기동에는 영향 없음).
