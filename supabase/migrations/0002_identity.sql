-- DhanaOS 0002 — org, users, customers, partners
-- D-008: three principal classes. Scoping is enforced in Postgres (0009_rls.sql), never in the UI.

-- ---------------------------------------------------------------- org

create table orgs (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,                       -- "AuraForge India"
  legal_name      text,
  gstin           text,                                -- D-004, required to raise a tax invoice
  pan             text,
  address         jsonb not null default '{}'::jsonb,
  base_currency   char(3) not null default 'INR',      -- D-004
  job_seq         int not null default 0,              -- D-001, minting counter
  job_seq_year    int not null default extract(year from now()),
  logo_path       text,
  created_at      timestamptz not null default now()
);

comment on column orgs.job_seq is
  'D-001. Monotonic within job_seq_year; resets when the year rolls over. See fn_mint_job_code.';

-- ---------------------------------------------------------------- users

-- Mirrors auth.users. Never store credentials here.
create table app_users (
  id              uuid primary key references auth.users(id) on delete cascade,
  org_id          uuid not null references orgs(id) on delete cascade,
  principal       principal_class not null default 'internal',
  full_name       text not null,
  title           text,                                -- "Manufacturing Engineer"
  initials        text,                                -- "JD", "PR-02" — used in completion credits
  email           text,
  phone           text,
  avatar_path     text,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now()
);

create table user_roles (
  user_id         uuid not null references app_users(id) on delete cascade,
  role            user_role not null,
  primary key (user_id, role)
);

comment on table user_roles is
  'D-008. A user may hold several roles. Permission checks on the three irreversible actions '
  '(approve design, approve price, authorize QC) read from here, not from a UI flag.';

-- ---------------------------------------------------------------- customers (retailers)

create table customers (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  name            text not null,                       -- "Scottsdale Diamond Co.", "ABC Jewelers"
  code            text,
  contact_name    text,
  email           text,
  phone           text,
  gstin           text,                                -- D-004
  address         jsonb not null default '{}'::jsonb,
  payment_terms   text,                                -- "Net 30"
  currency        char(3) not null default 'INR',
  notes           text,
  created_at      timestamptz not null default now(),
  unique (org_id, code)
);

-- A retailer's staff who can sign in to the customer portal.
create table customer_users (
  user_id         uuid primary key references app_users(id) on delete cascade,
  customer_id     uuid not null references customers(id) on delete cascade
);

-- ---------------------------------------------------------------- partners (vendors, labs, couriers)

create table partners (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  kind            partner_kind not null,
  name            text not null,                       -- "Patel Casting Works", "IGI Antwerp"
  contact_name    text,
  email           text,
  phone           text,
  address         jsonb not null default '{}'::jsonb,
  gstin           text,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now()
);

-- A vendor's staff who can sign in to the partner portal.
-- This replaces caster_dashboard's decorative "Assigned to Me" chip, which had nothing behind it.
create table partner_users (
  user_id         uuid primary key references app_users(id) on delete cascade,
  partner_id      uuid not null references partners(id) on delete cascade
);

-- ---------------------------------------------------------------- resources (in-house)

-- The mockups credited stage completions to named resources: "PR-02" (a printer), "Bench 4",
-- "Forge-A", "Marco V.". Some are machines, some are people — both close a stage.
create table resources (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  code            text not null,                       -- "PR-02", "Bench 4", "Forge-A"
  label           text not null,
  stage           lifecycle_stage,                     -- which stage this resource serves
  user_id         uuid references app_users(id) on delete set null,
  is_active       boolean not null default true,
  unique (org_id, code)
);

create index on app_users (org_id);
create index on customers (org_id);
create index on partners (org_id, kind);
create index on resources (org_id, stage);
