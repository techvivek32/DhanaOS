-- DhanaOS 0003 — the job spine: jobs, append-only stage log, audit, thread, attachments
-- D-005: a job has NO mutable status column. Stage is derived from job_stages.
--        jobs.current_stage is a trigger-maintained cache for query speed only.

-- ---------------------------------------------------------------- jobs

create table jobs (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references orgs(id) on delete cascade,

  -- D-001 — draft_code before commit, code after. Exactly one is set at any time.
  draft_code          text,                            -- 'DRAFT-992A'
  code                text,                            -- 'DH-2026-01842'

  customer_id         uuid references customers(id) on delete restrict,
  job_type            job_type,
  category            product_category,
  sub_style           product_sub_style,
  title               text,                            -- "Solitaire Crown v2.FINAL"
  quantity            int not null default 1,

  status              job_status not null default 'draft',
  priority            priority_level not null default 'standard',

  -- D-005 — denormalised cache, maintained by trg_job_stage_cache. Never written by hand.
  current_stage       lifecycle_stage,
  stage_entered_at    timestamptz,

  -- cross-cutting flags, orthogonal to stage
  is_at_risk          boolean not null default false,
  hold_reason         text,
  cancel_reason       text,

  requested_delivery  date,
  promised_delivery   date,
  hard_deadline       boolean not null default false,
  partial_allowed     boolean not null default true,

  currency            char(3) not null default 'INR',  -- D-004
  wizard_step         int not null default 1,          -- resumable intake (Phase 3)

  created_by          uuid references app_users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  committed_at        timestamptz,                     -- when draft_code became code
  closed_at           timestamptz,

  constraint jobs_code_shape   check (code is null or code ~ '^DH-[0-9]{4}-[0-9]{5}$'),
  constraint jobs_draft_shape  check (draft_code is null or draft_code ~ '^DRAFT-[0-9A-Z]{4}$'),
  constraint jobs_one_identity check (num_nonnulls(code, draft_code) >= 1),
  constraint jobs_qty_positive check (quantity > 0)
);

create unique index jobs_code_uq       on jobs (org_id, code)       where code is not null;
create unique index jobs_draft_code_uq on jobs (org_id, draft_code) where draft_code is not null;
create index jobs_customer_idx  on jobs (customer_id);
create index jobs_stage_idx     on jobs (org_id, current_stage) where status = 'in_production';
create index jobs_status_idx    on jobs (org_id, status);
create index jobs_due_idx       on jobs (org_id, requested_delivery);

comment on column jobs.current_stage is
  'D-005 cache only. Source of truth is the newest job_stages row with state = active.';

-- ---------------------------------------------------------------- stage log (append-only)

create table job_stages (
  id                uuid primary key default gen_random_uuid(),
  job_id            uuid not null references jobs(id) on delete cascade,
  stage             lifecycle_stage not null,
  state             stage_state not null default 'pending',
  seq               int not null,                      -- 1..14, position in the rail

  entered_at        timestamptz,
  expected_at       timestamptz,                       -- "Expected Aug 12 05:00 PM"
  completed_at      timestamptz,

  -- who or what closed it: "Completed by JD", "Completed by PR-02", "Completed by Forge-A"
  completed_by      uuid references app_users(id) on delete set null,
  resource_id       uuid references resources(id) on delete set null,
  assigned_to       uuid references app_users(id) on delete set null,
  assigned_partner  uuid references partners(id) on delete set null,

  blocked_reason    text,                              -- "Caster delayed"
  notes             text,
  created_at        timestamptz not null default now(),

  unique (job_id, stage)
);

create index job_stages_job_idx     on job_stages (job_id, seq);
create index job_stages_active_idx  on job_stages (stage, state) where state = 'active';
create index job_stages_partner_idx on job_stages (assigned_partner) where assigned_partner is not null;

comment on table job_stages is
  'D-005. Append-only in spirit: rows are inserted for all 14 stages at job commit, then '
  'transition by state change. Dwell time = completed_at - entered_at. The dashboard''s 8 '
  'operational counters are a view over this table (D-002), never a second enum.';

-- ---------------------------------------------------------------- audit trail

-- certification_dh_1048 titled its feed "Immutable Audit Trail"; job_detail wrote
-- "Stage Changed: Casting — System updated status automatically." Both become rows here.
create table activity_events (
  id            uuid primary key default gen_random_uuid(),
  job_id        uuid not null references jobs(id) on delete cascade,
  kind          activity_kind not null,
  actor_id      uuid references app_users(id) on delete set null,
  actor_label   text,                                  -- 'System', 'IGI Antwerp', 'Logistics'
  stage         lifecycle_stage,
  summary       text not null,                         -- 'Stage Changed: Casting'
  detail        text,
  payload       jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

create index activity_job_idx on activity_events (job_id, created_at desc);

-- Append-only enforced at the database, not by convention.
revoke update, delete on activity_events from public;

-- ---------------------------------------------------------------- digital thread

-- job_detail's core mechanic: human posts interleave chronologically with system events.
create table thread_posts (
  id            uuid primary key default gen_random_uuid(),
  job_id        uuid not null references jobs(id) on delete cascade,
  author_id     uuid references app_users(id) on delete set null,
  author_label  text,                                  -- for external actors without an account
  stage         lifecycle_stage,
  body          text not null,
  is_internal   boolean not null default false,        -- hidden from the customer portal
  created_at    timestamptz not null default now(),
  edited_at     timestamptz
);

create index thread_job_idx on thread_posts (job_id, created_at desc);

-- ---------------------------------------------------------------- attachments

-- The mockups referenced 12 project files per job plus STL downloads, casting photos,
-- certificate PDFs and voice notes — all pointing at remote Google URLs that will rot.
create table attachments (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  job_id        uuid references jobs(id) on delete cascade,
  kind          attachment_kind not null,
  bucket        text not null default 'job-files',
  path          text not null,                         -- storage object path
  filename      text not null,                         -- 'cad_mesh_v2.png'
  mime_type     text,
  size_bytes    bigint,
  duration_ms   int,                                   -- voice notes: 'Client_Instructions.wav 01:20'
  caption       text,
  thread_id     uuid references thread_posts(id) on delete set null,
  uploaded_by   uuid references app_users(id) on delete set null,
  created_at    timestamptz not null default now()
);

create index attachments_job_idx on attachments (job_id, kind);

-- ---------------------------------------------------------------- dashboard queue

-- manufacturer_dashboard's Action Queue: "Caster delayed on DH-1048" -> Follow Up.
-- In the mockup this was a hardcoded list; here it is generated from real job state.
create table action_items (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  job_id        uuid references jobs(id) on delete cascade,
  severity      action_severity not null default 'info',
  label         text not null,                         -- 'Caster delayed on DH-2026-01048'
  cta_label     text,                                  -- 'Follow Up'
  cta_route     text,
  assigned_to   uuid references app_users(id) on delete set null,
  resolved_at   timestamptz,
  created_at    timestamptz not null default now()
);

create index action_open_idx on action_items (org_id, severity) where resolved_at is null;
