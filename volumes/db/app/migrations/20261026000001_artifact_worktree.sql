-- ============================================================================
-- 인계 산출물 워크트리
--
-- 인계 스레드(시작 방, origin_room_id)마다 산출물 저장소 하나를 둔다. 방은 자기 브랜치에서
-- 일하고, 인계는 넘기는 방의 커밋에서 받는 방 브랜치를 만드는 분기다. 받는 방에 파일을
-- 복사하지 않는다.
--
--   내용   : Storage `files` 버킷 artifacts/{tenant}/objects/{sha256} 에 한 번만 둔다.
--   커밋   : 스냅샷 전체(tree: 경로 → {sha256, size, content_type}). 바뀌지 않는다.
--   브랜치 : 방 → 최신 커밋(head). 한 방에 하나.
--
-- 쓰기는 commit_branch / create_branch 함수로만 한다. 브랜치 이동은 head 가 기대값일 때만
-- 하므로(낙관적 잠금) 동시에 끝나는 커밋이 서로를 덮지 않는다. 어긋나면 SQLSTATE 40001 을
-- 내고 호출 쪽이 최신 head 를 다시 읽어 재시도한다.
-- ============================================================================

create table if not exists public.artifact_repos (
    id             uuid        not null default gen_random_uuid(),
    tenant_id      text        not null default public.tenant_id(),
    origin_room_id text        not null,
    created_at     timestamptz not null default now(),
    constraint artifact_repos_pkey primary key (id),
    constraint artifact_repos_origin_room_key unique (origin_room_id),
    constraint artifact_repos_tenant_id_fkey foreign key (tenant_id)
        references public.tenants (id) on update cascade on delete cascade
);

create table if not exists public.artifact_commits (
    id         uuid        not null default gen_random_uuid(),
    repo_id    uuid        not null,
    parents    uuid[]      not null default '{}',
    room_id    text        not null,
    author_id  text        null,
    reason     text        not null,
    tree       jsonb       not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    constraint artifact_commits_pkey primary key (id),
    constraint artifact_commits_repo_fkey foreign key (repo_id)
        references public.artifact_repos (id) on delete cascade,
    constraint artifact_commits_reason_check check (
        reason in ('handover', 'task_done', 'agent_turn', 'merge', 'edit')
    )
);

create index if not exists artifact_commits_repo_idx
    on public.artifact_commits (repo_id, created_at);
create index if not exists artifact_commits_room_idx
    on public.artifact_commits (room_id, created_at);

create table if not exists public.artifact_branches (
    room_id        text        not null,
    repo_id        uuid        not null,
    head_commit_id uuid        not null,
    base_commit_id uuid        null,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),
    constraint artifact_branches_pkey primary key (room_id),
    constraint artifact_branches_repo_fkey foreign key (repo_id)
        references public.artifact_repos (id) on delete cascade,
    constraint artifact_branches_head_fkey foreign key (head_commit_id)
        references public.artifact_commits (id),
    constraint artifact_branches_base_fkey foreign key (base_commit_id)
        references public.artifact_commits (id)
);

create index if not exists artifact_branches_repo_idx
    on public.artifact_branches (repo_id);

alter table public.handover_events
    add column if not exists base_commit_id uuid;

comment on column public.handover_events.base_commit_id is
    '받는 방 브랜치가 시작한 커밋(넘기는 방의 인계 시점 스냅샷). 복사 방식으로 넘긴 예전 인계는 null.';

-- 커밋은 불변이다. 고치면 새 커밋을 만든다.
create or replace function public.artifact_commits_immutable()
returns trigger
language plpgsql
as $$
begin
    raise exception 'artifact_commits 는 바뀌지 않습니다';
end;
$$;

drop trigger if exists artifact_commits_no_update on public.artifact_commits;
create trigger artifact_commits_no_update
    before update on public.artifact_commits
    for each row execute function public.artifact_commits_immutable();

-- ----------------------------------------------------------------------------
-- 호출자 확인. service_role(에이전트)은 테넌트를 코드에서 고정하므로 건너뛴다.
-- 로그인 사용자는 자기 테넌트의, 자기가 참여한 방에만 쓴다.
-- ----------------------------------------------------------------------------
create or replace function public.artifact_is_room_participant(p_room_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
          from public.chat_rooms r, jsonb_array_elements(coalesce(r.participants, '[]'::jsonb)) p
         where r.id = p_room_id
           and (p ->> 'id' = auth.uid()::text
                or (p ->> 'email') = (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email'))
    );
$$;

create or replace function public.artifact_is_service_caller()
returns boolean
language sql
stable
as $$
    select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', 'service_role') = 'service_role';
$$;

create or replace function public.artifact_assert_room_writer(p_tenant_id text, p_room_id text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if public.artifact_is_service_caller() then
        return;
    end if;
    if p_tenant_id is distinct from public.tenant_id() then
        raise exception 'artifact: 다른 테넌트의 저장소입니다' using errcode = '42501';
    end if;
    if not public.artifact_is_room_participant(p_room_id) then
        raise exception 'artifact: 참여하지 않은 방의 브랜치에는 쓸 수 없습니다' using errcode = '42501';
    end if;
end;
$$;

-- ----------------------------------------------------------------------------
-- 스레드 저장소를 찾거나 만든다.
-- ----------------------------------------------------------------------------
create or replace function public.ensure_artifact_repo(p_origin_room_id text, p_tenant_id text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_tenant text := coalesce(public.tenant_id(), p_tenant_id);
    v_id     uuid;
begin
    if v_tenant is null then
        raise exception 'artifact: tenant_id 가 없습니다';
    end if;
    insert into public.artifact_repos (tenant_id, origin_room_id)
    values (v_tenant, p_origin_room_id)
    on conflict (origin_room_id) do nothing;
    select id into v_id from public.artifact_repos
     where origin_room_id = p_origin_room_id and tenant_id = v_tenant;
    if v_id is null then
        raise exception 'artifact: 다른 테넌트의 저장소입니다' using errcode = '42501';
    end if;
    return v_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- 방 브랜치를 만든다.
--   base 가 있으면(인계) tree 가 base 와 같을 때 base 를 그대로 head 로 쓰고, 다르면(고른
--   것만 넘김) base 를 부모로 한 커밋을 받는 방에 만든다. 넘기는 사람은 base 를 head 로 둔
--   방(넘기는 방)에 참여해 있어야 한다. base 가 앞 방에서 넘겨받은 그대로의 커밋이면 그 커밋은
--   앞 방 소속이라, 커밋의 방이 아니라 head 로 둔 방을 본다(받는 방에는 아직 참여자가 아닐 수 있다).
--   base 가 없으면(스레드 시작 방·예전 방) tree 를 첫 커밋으로 한다.
-- 이미 브랜치가 있으면 그대로 돌려준다.
-- ----------------------------------------------------------------------------
create or replace function public.create_branch(
    p_repo_id        uuid,
    p_room_id        text,
    p_base_commit_id uuid,
    p_tree           jsonb,
    p_author_id      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_tenant text;
    v_base   public.artifact_commits;
    v_head   uuid;
    v_branch public.artifact_branches;
begin
    select tenant_id into v_tenant from public.artifact_repos where id = p_repo_id;
    if v_tenant is null then
        raise exception 'artifact: 저장소가 없습니다';
    end if;

    select * into v_branch from public.artifact_branches where room_id = p_room_id;
    if found then
        return jsonb_build_object('room_id', v_branch.room_id, 'head_commit_id', v_branch.head_commit_id,
                                  'base_commit_id', v_branch.base_commit_id, 'created', false);
    end if;

    if p_base_commit_id is not null then
        select * into v_base from public.artifact_commits where id = p_base_commit_id and repo_id = p_repo_id;
        if not found then
            raise exception 'artifact: 기준 커밋이 이 저장소에 없습니다';
        end if;
        if not public.artifact_is_service_caller() then
            if v_tenant is distinct from public.tenant_id() then
                raise exception 'artifact: 다른 테넌트의 저장소입니다' using errcode = '42501';
            end if;
            if not exists (
                select 1 from public.artifact_branches b
                 where b.head_commit_id = p_base_commit_id and public.artifact_is_room_participant(b.room_id)
            ) then
                raise exception 'artifact: 기준 커밋을 가진 방에 참여하지 않았습니다' using errcode = '42501';
            end if;
        end if;
        if v_base.tree = coalesce(p_tree, v_base.tree) then
            v_head := v_base.id;
        else
            insert into public.artifact_commits (repo_id, parents, room_id, author_id, reason, tree)
            values (p_repo_id, array[v_base.id], p_room_id, p_author_id, 'handover', p_tree)
            returning id into v_head;
        end if;
    else
        perform public.artifact_assert_room_writer(v_tenant, p_room_id);
        insert into public.artifact_commits (repo_id, parents, room_id, author_id, reason, tree)
        values (p_repo_id, '{}', p_room_id, p_author_id, 'handover', coalesce(p_tree, '{}'::jsonb))
        returning id into v_head;
    end if;

    insert into public.artifact_branches (room_id, repo_id, head_commit_id, base_commit_id)
    values (p_room_id, p_repo_id, v_head, p_base_commit_id);
    return jsonb_build_object('room_id', p_room_id, 'head_commit_id', v_head,
                              'base_commit_id', p_base_commit_id, 'created', true);
end;
$$;

-- ----------------------------------------------------------------------------
-- 방 브랜치에 커밋한다. head 가 p_expected_head 일 때만 옮긴다(아니면 40001).
-- tree 가 head 와 같고 따로 부모를 주지 않았으면 커밋하지 않고 head 를 돌려준다.
-- p_parents 를 주면(병합) 그 목록을 부모로 쓴다. 첫째는 반드시 지금 head 다.
-- ----------------------------------------------------------------------------
create or replace function public.commit_branch(
    p_room_id       text,
    p_expected_head uuid,
    p_tree          jsonb,
    p_reason        text,
    p_parents       uuid[] default null,
    p_author_id     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_branch public.artifact_branches;
    v_tenant text;
    v_head   public.artifact_commits;
    v_id     uuid;
begin
    select * into v_branch from public.artifact_branches where room_id = p_room_id for update;
    if not found then
        raise exception 'artifact: 방 브랜치가 없습니다(%)', p_room_id using errcode = 'P0002';
    end if;
    select tenant_id into v_tenant from public.artifact_repos where id = v_branch.repo_id;
    perform public.artifact_assert_room_writer(v_tenant, p_room_id);

    if v_branch.head_commit_id is distinct from p_expected_head then
        raise exception 'artifact: head 가 바뀌었습니다(기대 %, 지금 %)', p_expected_head, v_branch.head_commit_id
            using errcode = '40001';
    end if;
    if p_parents is not null and (cardinality(p_parents) = 0 or p_parents[1] is distinct from v_branch.head_commit_id) then
        raise exception 'artifact: 병합 커밋의 첫 부모는 지금 head 여야 합니다';
    end if;

    select * into v_head from public.artifact_commits where id = v_branch.head_commit_id;
    if p_parents is null and v_head.tree = p_tree then
        return jsonb_build_object('commit_id', v_head.id, 'created', false);
    end if;

    insert into public.artifact_commits (repo_id, parents, room_id, author_id, reason, tree)
    values (v_branch.repo_id, coalesce(p_parents, array[v_head.id]), p_room_id, p_author_id, p_reason, p_tree)
    returning id into v_id;
    update public.artifact_branches
       set head_commit_id = v_id, updated_at = now()
     where room_id = p_room_id;
    return jsonb_build_object('commit_id', v_id, 'created', true);
end;
$$;

-- RLS: 같은 테넌트는 읽는다. 쓰기 정책은 두지 않는다(함수로만 쓴다).
alter table public.artifact_repos enable row level security;
alter table public.artifact_commits enable row level security;
alter table public.artifact_branches enable row level security;

drop policy if exists artifact_repos_select_policy on public.artifact_repos;
create policy artifact_repos_select_policy on public.artifact_repos
    for select to authenticated using (tenant_id = public.tenant_id());
drop policy if exists artifact_commits_select_policy on public.artifact_commits;
create policy artifact_commits_select_policy on public.artifact_commits
    for select to authenticated using (
        exists (select 1 from public.artifact_repos r where r.id = repo_id and r.tenant_id = public.tenant_id())
    );
drop policy if exists artifact_branches_select_policy on public.artifact_branches;
create policy artifact_branches_select_policy on public.artifact_branches
    for select to authenticated using (
        exists (select 1 from public.artifact_repos r where r.id = repo_id and r.tenant_id = public.tenant_id())
    );

revoke all on function public.artifact_assert_room_writer(text, text) from public, anon;
revoke all on function public.artifact_is_room_participant(text) from public, anon;
revoke all on function public.ensure_artifact_repo(text, text) from public, anon;
revoke all on function public.create_branch(uuid, text, uuid, jsonb, text) from public, anon;
revoke all on function public.commit_branch(text, uuid, jsonb, text, uuid[], text) from public, anon;
grant execute on function public.ensure_artifact_repo(text, text) to authenticated, service_role;
grant execute on function public.create_branch(uuid, text, uuid, jsonb, text) to authenticated, service_role;
grant execute on function public.commit_branch(text, uuid, jsonb, text, uuid[], text) to authenticated, service_role;
