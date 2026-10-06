# 벤치 워커 이미지. 실제 SDK 를 그대로 설치한다 — 점유/연장/회수 코드가
# 운영에 들어가는 것과 같은 코드여야 측정에 의미가 있다.
FROM python:3.12-slim

WORKDIR /app
COPY sdk /app/sdk
RUN pip install --no-cache-dir /app/sdk
COPY worker.py /app/worker.py

ENV PYTHONUNBUFFERED=1

# 워커를 PID 1 로 두지 않는다. 리눅스는 PID 네임스페이스의 1번 프로세스에게
# 같은 네임스페이스 안에서 보낸 SIGKILL 을 전달하지 않는다 — 그러면 컨테이너
# 안에서 `kill -9` 로 워커를 죽이는 시나리오 자체가 불가능해진다.
# sh 가 1번을 맡고, 워커는 그 자식이 된다(워커가 죽으면 sh 도 끝나고 컨테이너는
# 재시작한다 — 파드가 죽고 새 워커가 올라오는 운영의 모습과 같다).
CMD ["sh", "-c", "python /app/worker.py"]
