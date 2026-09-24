-- DhanaOS 0006 — CAD, casting, bench, QC, certification, shipping
-- D-011: the four business rules the mockups actually implemented are enforced here or in
-- application validation, and named in comments so they are not lost in a later refactor.

-- ---------------------------------------------------------------- CAD

create table cad_revisions (
  id              uuid primary key default gen_random_uuid(),
  job_id          uuid not null references jobs(id) on delete cascade,
  version         text not null,                       -- 'v1.2', 'v2.0'
  seq             int not null,
  designer_id     uuid references app_users(id) on delete set null,
  designer_note   text,                                -- 'Increased the halo melee stones from
                                                       --  1.2mm to 1.5mm for better presence.'
  render_ids      uuid[] not null default '{}',        -- attachments: cad_render
  model_id        uuid references attachments(id) on delete set null,  -- STL / STEP
  is_current      boolean not null default true,
  is_locked       boolean not null default false,      -- set on approval: 'Version 2.0 has been locked'
  -- structured diff against the previous revision, e.g. {"halo": "0.45ct tw (from 0.3ct)"}
  spec_diff       jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  unique (job_id, version)
);

create index cad_rev_job_idx on cad_revisions (job_id, seq desc);

-- positioned annotation pins on a render
create table cad_annotations (
  id            uuid primary key default gen_random_uuid(),
  revision_id   uuid not null references cad_revisions(id) on delete cascade,
  x_pct         numeric(5,2) not null,
  y_pct         numeric(5,2) not null,
  body          text not null,                         -- 'Halo stones were too small...'
  author_id     uuid references app_users(id) on delete set null,
  resolved_at   timestamptz,
  created_at    timestamptz not null default now()
);

create table cad_reviews (
  id            uuid primary key default gen_random_uuid(),
  revision_id   uuid not null references cad_revisions(id) on delete cascade,
  reviewer_id   uuid references app_users(id) on delete set null,
  approved      boolean not null,
  comment       text,
  created_at    timestamptz not null default now(),

  -- D-011 RULE 2 — asymmetric decision, ported verbatim from cad_review_dh_1048:
  -- "Request Revisions" is blocked on an empty comment; "Approve" is not.
  -- Rejection owes the designer a reason.
  constraint cad_reject_needs_comment
    check (approved or (comment is not null and length(btrim(comment)) > 0))
);

comment on constraint cad_reject_needs_comment on cad_reviews is
  'D-011. The mockup flashed an error ring and rewrote the placeholder for 2s. Enforced here so '
  'the rule survives any client rewrite.';

-- ---------------------------------------------------------------- casting

create table casting_params (
  job_id          uuid primary key references jobs(id) on delete cascade,
  partner_id      uuid references partners(id) on delete set null,
  alloy           text,                                -- '18K Yellow Gold'
  flask_temp_c    int,                                 -- 650
  metal_temp_c    int,                                 -- 1020 — rendered as the hazardous value
  tree_weight_g   numeric(8,3),
  received_at     timestamptz,                         -- 'Received Aug 11 09:30 AM'
  expected_at     timestamptz,                         -- 'Expected Aug 12 05:00 PM'
  completed_at    timestamptz,
  -- D-011 RULE 1 — a partner cannot complete casting without evidence.
  photo_id        uuid references attachments(id) on delete set null,
  notes           text
);

comment on column casting_params.photo_id is
  'D-011 RULE 1, the single best idea in the corpus: caster_dashboard shipped "Mark Complete" '
  'DISABLED behind a mandatory accept="image/*" upload, helper "Required before marking '
  'complete". Enforced in fn_complete_stage, not merely in the UI.';

-- caster_dashboard's "Report Issue" was a 50/50 peer of the happy path with no screen behind it.
create table job_exceptions (
  id            uuid primary key default gen_random_uuid(),
  job_id        uuid not null references jobs(id) on delete cascade,
  stage         lifecycle_stage not null,
  raised_by     uuid references app_users(id) on delete set null,
  partner_id    uuid references partners(id) on delete set null,
  title         text not null,                         -- 'Caster delayed'
  detail        text,
  severity      action_severity not null default 'warning',
  resolved_at   timestamptz,
  resolution    text,
  created_at    timestamptz not null default now()
);

create index exceptions_open_idx on job_exceptions (job_id) where resolved_at is null;

-- ---------------------------------------------------------------- bench measurements

-- NO screen in the mockups captured a production measurement. order_details showed the binding
-- spec ("Target Weight 4.2g ±0.1g", the only spec rendered in gold) as read-only, while a note
-- in the same thread said "Update spec sheet".
create table stage_measurements (
  id              uuid primary key default gen_random_uuid(),
  job_id          uuid not null references jobs(id) on delete cascade,
  stage           lifecycle_stage not null,
  measured_by     uuid references app_users(id) on delete set null,
  weight_g        numeric(8,3),
  target_g        numeric(8,3),
  tolerance_g     numeric(8,3),
  within_tol      boolean generated always as (
                    weight_g is null or target_g is null or tolerance_g is null
                    or abs(weight_g - target_g) <= tolerance_g
                  ) stored,
  scrap_g         numeric(8,3),                        -- filings, polishing loss, sprues
  notes           text,
  photo_id        uuid references attachments(id) on delete set null,
  created_at      timestamptz not null default now()
);

create index measurements_job_idx on stage_measurements (job_id, stage);

-- ---------------------------------------------------------------- QC

create table qc_inspections (
  id              uuid primary key default gen_random_uuid(),
  job_id          uuid not null references jobs(id) on delete cascade,
  attempt         int not null default 1,              -- D-006: reinspection after rework
  status          qc_status not null default 'pending',
  inspector_id    uuid references app_users(id) on delete set null,
  authority       quality_authority not null default 'internal_qc',
  cad_revision_id uuid references cad_revisions(id) on delete set null,
  -- D-006: the mockup had no fail path at all, yet its own JS removed a bg-error class,
  -- proving a FAILED state was designed and made unreachable.
  defect_reason   text,
  notes           text,
  authorized_at   timestamptz,
  created_at      timestamptz not null default now(),
  unique (job_id, attempt),
  constraint qc_fail_needs_reason
    check (status <> 'failed' or (defect_reason is not null and length(btrim(defect_reason)) > 0))
);

create table qc_checklist_items (
  id              uuid primary key default gen_random_uuid(),
  inspection_id   uuid not null references qc_inspections(id) on delete cascade,
  position        int not null,
  label           text not null,                       -- 'Metal weight verified'
  helper          text,                                -- 'Target: 4.8g Pt950. Allowable
                                                       --  variance: ±0.2g.'
  requirement_id  uuid references requirements(id) on delete set null,   -- D-009 citation
  passed          boolean,
  evidence_id     uuid references attachments(id) on delete set null,
  checked_by      uuid references app_users(id) on delete set null,
  checked_at      timestamptz
);

create index qc_items_idx on qc_checklist_items (inspection_id, position);

comment on table qc_checklist_items is
  'D-011 RULE 3: authorisation enables only when every item has passed = true. The mockup had '
  'no file input at all behind its "inspection evidence" dropzone; evidence_id fixes that.';

-- ---------------------------------------------------------------- certification

create table certificates (
  id              uuid primary key default gen_random_uuid(),
  job_id          uuid not null references jobs(id) on delete cascade,
  required        boolean not null default true,       -- false must SKIP the stage and zero
                                                       -- delivery_schedules.cert_buffer_d
  lab             cert_lab not null default 'igi',
  lab_partner_id  uuid references partners(id) on delete set null,
  status          cert_status not null default 'waiting',
  sent_at         date,
  expected_back   date,                                -- no SLA field existed in the mockup
  cert_number     text,                                -- 10-digit hint: 'e.g. 1234567890'
  pdf_id          uuid references attachments(id) on delete set null,
  -- D-006: no lab-rejection path existed
  rejection_note  text,
  created_at      timestamptz not null default now()
);

create index certificates_job_idx on certificates (job_id);

-- ---------------------------------------------------------------- shipping

-- The mockups proved a job needs SEVERAL legs, not one shipment: inbound wax from "Central Hub",
-- to-lab ("FEDEX: 9876543210"), from-lab, then final dispatch.
create table shipments (
  id              uuid primary key default gen_random_uuid(),
  job_id          uuid not null references jobs(id) on delete cascade,
  leg             shipment_leg not null,
  status          shipment_status not null default 'draft',

  routing         dispatch_routing,                    -- final_dispatch only
  courier         courier_kind,
  courier_other   text,
  waybill         text,                                -- uppercase-forced in the mockup
  from_partner    uuid references partners(id) on delete set null,
  to_partner      uuid references partners(id) on delete set null,
  to_address      jsonb not null default '{}'::jsonb,

  declared_value  bigint,                              -- '$45,000.00'
  currency        char(3) not null default 'INR',
  insured         boolean not null default true,

  -- international courier with NO customs fields existed in the mockup
  is_international boolean not null default false,
  customs_ref     text,
  commercial_inv  uuid references attachments(id) on delete set null,

  signature_req   boolean not null default true,
  white_glove     boolean not null default false,      -- 'Requires white-glove unboxing prep.'

  dispatched_at   timestamptz,
  delivered_at    timestamptz,
  pod_id          uuid references attachments(id) on delete set null,  -- proof of delivery
  received_by     text,
  created_at      timestamptz not null default now()
);

create index shipments_job_idx on shipments (job_id, leg);

-- The mockup's security gate was cosmetic: its JS toggled opacity classes and never set
-- .disabled, so dispatch fired with the tamper-seal protocol incomplete.
create table shipment_checks (
  id            uuid primary key default gen_random_uuid(),
  shipment_id   uuid not null references shipments(id) on delete cascade,
  position      int not null,
  label         text not null,                         -- 'Tamper-evident seal applied to inner box'
  reference     text,                                  -- 'Seal #TE-921'
  passed        boolean not null default false,
  checked_by    uuid references app_users(id) on delete set null,
  checked_at    timestamptz
);

create index shipment_checks_idx on shipment_checks (shipment_id, position);

comment on table shipment_checks is
  'Dispatch is blocked until every row has passed = true. Enforced in fn_dispatch_shipment. '
  'The mockup only dimmed the button.';
