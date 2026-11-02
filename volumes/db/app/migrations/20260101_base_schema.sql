-- =============================================================================
-- Base schema required for local Supabase startup
-- - The rest of migrations assume these objects already exist.
-- - Extracted/minimized from docker-compose/volumes/db/init.sql
-- =============================================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enums (idempotent)
DO $$ BEGIN
  CREATE TYPE process_status AS ENUM ('NEW', 'RUNNING', 'COMPLETED');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE todo_status AS ENUM ('NEW', 'TODO', 'IN_PROGRESS', 'SUBMITTED', 'PENDING', 'DONE', 'CANCELLED');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE agent_mode AS ENUM ('DRAFT', 'COMPLETE');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE agent_orch AS ENUM ('crewai-action', 'openai-deep-research', 'crewai-deep-research', 'langchain-react', 'browser-automation-agent', 'a2a', 'visionparse');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE draft_status AS ENUM ('STARTED', 'CANCELLED', 'COMPLETED', 'FB_REQUESTED', 'HUMAN_ASKED', 'FAILED');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

-- Tenant id helper
CREATE OR REPLACE FUNCTION public.tenant_id()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(
    btrim(
      COALESCE(
        ((current_setting('request.jwt.claims', true)::jsonb ->> 'app_metadata')::jsonb ->> 'tenant_id'),
        (current_setting('request.jwt.claim.tenant_id', true))
      )
    ),
    ''
  );
$$;

-- Core tables
CREATE TABLE IF NOT EXISTS public.tenants (
  id text PRIMARY KEY,
  owner uuid NULL DEFAULT auth.uid(),
  is_deleted boolean NOT NULL DEFAULT false,
  deleted_at timestamptz NULL,
  mcp jsonb NULL
);

-- Keep a default tenant for local usage (safe if rerun)
INSERT INTO public.tenants (id, owner)
VALUES ('process-gpt', NULL)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.users (
  id uuid NOT NULL,
  username text NULL,
  profile text NULL DEFAULT '/images/defaultUser.png'::text,
  email text NULL,
  is_admin boolean NOT NULL DEFAULT false,
  role text NULL,
  tenant_id text NOT NULL DEFAULT 'process-gpt',
  device_token text NULL,
  goal text NULL,
  persona text NULL,
  endpoint text NULL,
  description text NULL,
  tools text NULL,
  skills text NULL,
  is_agent boolean NOT NULL DEFAULT false,
  agent_type text NULL,
  model text NULL,
  alias text NULL,
  last_used_at timestamptz NULL DEFAULT now(),
  tool_priority jsonb NULL,
  CONSTRAINT users_pkey PRIMARY KEY (id, tenant_id),
  CONSTRAINT users_tenant_id_fkey FOREIGN KEY (tenant_id)
    REFERENCES public.tenants (id) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_users_is_agent_true
  ON public.users (is_agent)
  WHERE is_agent = true;

CREATE TABLE IF NOT EXISTS public.proc_def (
  id text NOT NULL,
  name text NULL,
  definition jsonb NULL,
  bpmn text NULL,
  prod_version text NULL,
  uuid uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id text NULL DEFAULT public.tenant_id(),
  isdeleted boolean NOT NULL DEFAULT false,
  owner text NULL,
  type text NULL,
  CONSTRAINT proc_def_pkey PRIMARY KEY (uuid),
  CONSTRAINT proc_def_tenant_id_fkey FOREIGN KEY (tenant_id)
    REFERENCES public.tenants (id) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS public.bpm_proc_inst (
  proc_def_id text NULL,
  proc_inst_id text NOT NULL,
  proc_inst_name text NULL,
  root_proc_inst_id text NULL,
  parent_proc_inst_id text NULL,
  execution_scope text NULL,
  current_activity_ids text[] NULL,
  participants text[] NULL,
  role_bindings jsonb NULL,
  variables_data jsonb NULL,
  status process_status NULL,
  tenant_id text NULL DEFAULT public.tenant_id(),
  proc_def_version text NULL,
  version_tag text NULL,
  version text NULL,
  project_id uuid NULL,
  start_date timestamp without time zone NULL,
  end_date timestamp without time zone NULL,
  due_date timestamp without time zone NULL,
  updated_at timestamptz DEFAULT now(),
  is_deleted boolean NOT NULL DEFAULT false,
  deleted_at timestamptz NULL,
  is_clean_up boolean NOT NULL DEFAULT false,
  CONSTRAINT bpm_proc_inst_pkey PRIMARY KEY (proc_inst_id),
  CONSTRAINT bpm_proc_inst_tenant_id_fkey FOREIGN KEY (tenant_id)
    REFERENCES public.tenants (id) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS public.todolist (
  id uuid NOT NULL,
  user_id text NULL,
  username text NULL,
  proc_inst_id text NULL,
  root_proc_inst_id text NULL,
  execution_scope text NULL,
  proc_def_id text NULL,
  version_tag text NULL,
  version text NULL,
  activity_id text NULL,
  activity_name text NULL,
  start_date timestamp without time zone NULL,
  end_date timestamp without time zone NULL,
  status todo_status NULL,
  description text NULL,
  tool text NULL,
  due_date timestamp without time zone NULL,
  tenant_id text NULL DEFAULT public.tenant_id(),
  reference_ids text[] NULL,
  adhoc boolean NULL DEFAULT false,
  assignees jsonb NULL,
  duration integer NULL,
  output jsonb NULL,
  retry integer NULL DEFAULT 0,
  consumer text NULL,
  log text NULL,
  project_id uuid NULL,
  draft jsonb NULL,
  agent_mode agent_mode NULL,
  agent_orch agent_orch NULL,
  feedback jsonb NULL,
  draft_status draft_status NULL,
  updated_at timestamptz DEFAULT now(),
  temp_feedback text NULL,
  output_url text NULL,
  rework_count integer NULL DEFAULT 0,
  query text NULL,
  feedback_status text NULL,
  CONSTRAINT todolist_pkey PRIMARY KEY (id),
  CONSTRAINT todolist_tenant_id_fkey FOREIGN KEY (tenant_id)
    REFERENCES public.tenants (id) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS public.user_permissions (
  id text NOT NULL,
  user_id uuid NOT NULL,
  tenant_id text NOT NULL DEFAULT public.tenant_id(),
  proc_def_id text NOT NULL,
  proc_def_ids jsonb NOT NULL,
  readable boolean NOT NULL DEFAULT false,
  writable boolean NOT NULL DEFAULT false,
  deployable boolean NOT NULL DEFAULT false,
  CONSTRAINT user_permissions_pkey PRIMARY KEY (id)
);

-- =============================================================================
-- Objects below are also assumed by later migrations (empty-DB validation
-- 2026-08-21에서 확인된 누락분). DDL 출처:
-- - configuration/lock/proc_def_version/proc_def_marketplace/feedback_proposals/
--   resource_pull_requests: docker-compose/volumes/db/init.sql (정본)
-- - tb_bpmn_model: supabase/migrations/schema_merge.sql
-- - task_property_schema/has_role_at_least: 리포에 DDL이 없어 사용처
--   (마이그레이션·src/components/api/*, src/utils/roles.ts) 기준으로 복원.
--   기존 DB에는 이미 존재하므로 전부 멱등 가드로 선언한다.
-- =============================================================================

create table if not exists public.configuration (
    key text not null,
    value jsonb null,
    tenant_id text null default public.tenant_id(),
    uuid uuid not null default gen_random_uuid (),
    constraint configuration_pkey primary key (uuid),
    constraint configuration_tenant_id_fkey foreign key (tenant_id) references tenants (id) on update cascade on delete cascade
);

create table if not exists public.lock (
    id text not null,
    user_id text null,
    tenant_id text null default public.tenant_id(),
    uuid uuid not null default gen_random_uuid (),
    constraint lock_pkey primary key (uuid),
    constraint lock_tenant_id_fkey foreign key (tenant_id) references tenants (id) on update cascade on delete cascade,
    constraint lock_tenant_id_id_unique unique (tenant_id, id)
);

create table if not exists public.proc_def_version (
    arcv_id text not null,
    proc_def_id text not null,
    version text not null,
    version_tag text null,
    snapshot text null,
    definition jsonb null,
    "timeStamp" timestamp without time zone null default current_timestamp,
    diff text null,
    message text null,
    uuid uuid not null default gen_random_uuid (),
    tenant_id text null default public.tenant_id(),
    parent_version text null,
    source_todolist_id uuid null,
    is_draft boolean not null default false,
    constraint proc_def_version_pkey primary key (uuid),
    constraint proc_def_version_tenant_id_fkey foreign key (tenant_id) references tenants (id) on update cascade on delete cascade
);

create table if not exists public.proc_def_marketplace (
    uuid uuid not null default gen_random_uuid (),
    id text not null,
    name text null,
    definition jsonb null,
    bpmn text null,
    description text null,
    category text null,
    tags text null,
    author_name text null,
    author_uid text null,
    image text null,
    import_count integer not null default 0,
    constraint proc_def_marketplace_pkey primary key (uuid)
);

create table if not exists public.feedback_proposals (
  id uuid not null default gen_random_uuid (),
  tenant_id text not null,
  proc_def_id text not null,
  activity_id text not null,
  status text not null default 'COLLECTING'::text,
  collected_items jsonb not null default '[]'::jsonb,
  first_collected_at timestamp with time zone not null default now(),
  extracted_rule text null,
  proposed_at timestamp with time zone null,
  decided_by uuid null,
  decided_by_name text null,
  decided_by_email text null,
  decided_at timestamp with time zone null,
  decision_note text null,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  candidate_skill_names text[] not null default '{}'::text[],
  targets jsonb not null default '[]'::jsonb,
  constraint feedback_proposals_pkey primary key (id),
  constraint feedback_proposals_status_check check (
    status = any (array['COLLECTING'::text, 'PROPOSED'::text, 'APPROVED'::text, 'REJECTED'::text, 'DISCARDED'::text, 'RESOLVED'::text])
  )
);

DO $$ BEGIN
  CREATE TYPE resource_pr_status AS ENUM ('OPEN', 'CHANGES_REQUESTED', 'APPROVED', 'MERGED', 'CLOSED');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

create table if not exists public.resource_pull_requests (
  id             uuid                not null default gen_random_uuid(),
  tenant_id      text                not null,
  resource_type  text                not null,
  resource_id    text                not null,
  branch_name    text                not null,
  base_branch    text                not null default 'main',
  title          text                not null,
  description    text                null,
  status         resource_pr_status  not null default 'OPEN',
  requester_id   uuid[]              not null default '{}'::uuid[],
  reviewer_id    uuid                null,
  git_pr_number  integer             null,
  git_pr_url     text                null,
  git_repo_url   text                null,
  created_at     timestamptz         not null default now(),
  updated_at     timestamptz         not null default now(),
  merged_at      timestamptz         null,
  constraint resource_pull_requests_pkey primary key (id),
  constraint resource_pull_requests_resource_type_check check (
    resource_type in ('skill', 'bpmn', 'dmn')
  ),
  constraint resource_pull_requests_reviewer_fkey foreign key (reviewer_id, tenant_id)
    references public.users (id, tenant_id) on update cascade on delete cascade
);

CREATE TABLE IF NOT EXISTS public.tb_bpmn_model (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id TEXT NOT NULL DEFAULT 'default',
    proc_def_id TEXT NOT NULL,
    name VARCHAR(500),
    description TEXT,
    status VARCHAR(50) DEFAULT 'draft',
    parent_proc_def_id TEXT,
    domain_id TEXT,
    hierarchy_level VARCHAR(20),
    process_id VARCHAR(255),
    is_executable BOOLEAN DEFAULT false,
    xml_hash VARCHAR(64),
    node_count INTEGER DEFAULT 0,
    link_count INTEGER DEFAULT 0,
    lane_count INTEGER DEFAULT 0,
    parsed_at TIMESTAMPTZ,
    created_by TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT tb_bpmn_model_proc_def_unique UNIQUE (tenant_id, proc_def_id)
);

-- 원형(초기) 스키마. 이후 컬럼은 20260316_expand/20260423_rename/20260424 등이 추가한다.
CREATE TABLE IF NOT EXISTS public.task_property_schema (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  tenant_id text NULL DEFAULT public.tenant_id(),
  task_type text NULL,
  property_key text NOT NULL,
  property_label text NULL,
  property_type text NULL DEFAULT 'string',
  is_mandatory boolean NOT NULL DEFAULT false,
  CONSTRAINT task_property_schema_pkey PRIMARY KEY (id),
  CONSTRAINT task_property_schema_tenant_id_fkey FOREIGN KEY (tenant_id)
    REFERENCES public.tenants (id) ON UPDATE CASCADE ON DELETE CASCADE
);

-- RLS 정책에서 쓰는 역할 위계 검사. 위계는 src/utils/roles.ts 와 동일:
-- admin > owner > editor > reviewer > viewer.
-- 운영 DB에 이미 있는 정의를 덮어쓰지 않도록 없을 때만 생성한다.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'has_role_at_least'
  ) THEN
    CREATE FUNCTION public.has_role_at_least(required_role text)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    AS $fn$
      WITH levels(role, level) AS (
        VALUES ('admin', 5), ('owner', 4), ('editor', 3), ('reviewer', 2), ('viewer', 1)
      ), me AS (
        SELECT CASE WHEN u.is_admin THEN 'admin'
                    ELSE COALESCE(NULLIF(lower(btrim(u.role)), ''), 'viewer') END AS role
        FROM public.users u
        WHERE u.id = auth.uid()
          AND u.tenant_id = COALESCE(public.tenant_id(), u.tenant_id)
        LIMIT 1
      )
      SELECT COALESCE(
        (SELECT l.level FROM me JOIN levels l ON l.role = me.role) >=
        (SELECT l2.level FROM levels l2 WHERE l2.role = lower(btrim(required_role))),
        false
      );
    $fn$;
  END IF;
END $$;

