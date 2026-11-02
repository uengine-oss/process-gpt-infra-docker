-- 프로세스 컴포넌트(zip) 기반 마켓플레이스 재설계
-- - proc_def_marketplace 를 버전·패키지 인지형으로 확장
-- - 최신 버전 리스팅 뷰 + 테넌트 설치 추적 테이블 + Storage 버킷
-- 라이브 DB 대상 idempotent 스크립트(여러 번 실행해도 안전).

-- 1) proc_def_marketplace 컬럼 확장
alter table public.proc_def_marketplace
    add column if not exists version        text,
    add column if not exists package_path   text,
    add column if not exists source_arcv_id text,
    add column if not exists manifest       jsonb,
    add column if not exists created_at      timestamptz default now();

-- 같은 컴포넌트 id 에 대해 버전 중복 등록 방지(무버전 레거시 행은 제외).
create unique index if not exists proc_def_marketplace_id_version_uq
    on public.proc_def_marketplace (id, version)
    where version is not null;

-- 2) 컴포넌트 id 별 최신 버전만 노출하는 리스팅 뷰.
create or replace view public.proc_def_marketplace_latest as
    select distinct on (id) *
    from public.proc_def_marketplace
    order by id, created_at desc nulls last;

-- 3) 테넌트별 설치 추적 테이블.
create table if not exists public.installed_components (
    tenant_id text not null,
    component_id text not null,
    marketplace_uuid uuid,
    installed_version text not null,
    local_proc_def_id text not null,
    installed_at timestamptz default now(),
    updated_at timestamptz default now(),
    constraint installed_components_pkey primary key (tenant_id, local_proc_def_id)
);

alter table public.installed_components enable row level security;

do $$
begin
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'installed_components' and policyname = 'installed_components_select_policy') then
        create policy installed_components_select_policy on public.installed_components for select to authenticated using (tenant_id = public.tenant_id());
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'installed_components' and policyname = 'installed_components_insert_policy') then
        create policy installed_components_insert_policy on public.installed_components for insert to authenticated with check (tenant_id = public.tenant_id());
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'installed_components' and policyname = 'installed_components_update_policy') then
        create policy installed_components_update_policy on public.installed_components for update to authenticated using (tenant_id = public.tenant_id());
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'installed_components' and policyname = 'installed_components_delete_policy') then
        create policy installed_components_delete_policy on public.installed_components for delete to authenticated using (tenant_id = public.tenant_id());
    end if;
end $$;

-- 4) Storage 버킷 + 정책.
insert into storage.buckets (id, name, public)
    values ('process-components', 'process-components', false)
    on conflict (id) do nothing;

do $$
begin
    if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'process-components read') then
        create policy "process-components read" on storage.objects for select to authenticated using (bucket_id = 'process-components');
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'process-components write') then
        create policy "process-components write" on storage.objects for insert to authenticated with check (bucket_id = 'process-components');
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'process-components update') then
        create policy "process-components update" on storage.objects for update to authenticated using (bucket_id = 'process-components');
    end if;
    if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'process-components delete') then
        create policy "process-components delete" on storage.objects for delete to authenticated using (bucket_id = 'process-components');
    end if;
end $$;

-- 5) 레거시 마켓플레이스 복사 RPC 제거(표준 패키지 import 로 대체됨).
--    프로세스 정의 + 폼만 복사하고 에이전트/스킬은 복사하지 못했다.
drop function if exists public.duplicate_definition_from_marketplace(text, text, text, text);
