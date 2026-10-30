-- 에이전트 「지식 관리」 목록이 늘 비어 보이는 문제 보정.
-- 프론트는 학습한 메모리(mem0 → vecs.memories)를 rpc get_memories / delete_memory / delete_memories_by_agent 로 읽고 지우는데,
-- 그 함수(volumes/db/vecs.sql)는 vecs.memories 가 있어야 만들 수 있어 설치 때 어디서도 적용되지 않았다 → rpc 404 를 프론트가
-- 삼켜 「메모리가 없습니다」. mem0(vecs)가 처음 메모리를 쓸 때 만드는 표와 같은 모양으로 먼저 만들어 두고 함수를 만든다
-- (vecs 는 있는 표를 그대로 쓰고, 벡터 색인은 처음 쓸 때 스스로 만든다). 차원 1536 = memento·에이전트 임베딩(OpenAI).
CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS vecs;
CREATE TABLE IF NOT EXISTS vecs.memories (
    id       character varying PRIMARY KEY,
    vec      vector(1536) NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

create or replace function public.get_memories(agent text, lim int default 100)
returns setof vecs.memories
language sql stable
security definer
as $$
  select *
  from vecs.memories
  where (agent is null or metadata->>'agent_id' = agent)
  order by id
  limit lim;
$$;

create or replace function public.delete_memory(mem_id text)
returns void
language sql volatile
security definer
as $$
  delete from vecs.memories where id = mem_id;
$$;

create or replace function public.delete_memories_by_agent(agent text)
returns void
language sql volatile
security definer
as $$
  delete from vecs.memories where metadata->>'agent_id' = agent;
$$;

-- supabase_admin 이 만든 함수에는 기본 권한이 안 붙는다 — 화면(authenticated)이 rpc 로 부를 수 있게
GRANT USAGE ON SCHEMA vecs TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_memories(text, int), public.delete_memory(text), public.delete_memories_by_agent(text)
    TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
