-- DhanaOS 0004 — specifications captured by the intake wizard
-- Fields here are the UNION of competing mockup variants (D-012). Several fields exist in
-- exactly one of the 46 screens and were dropped by every later redesign; those are flagged.

-- ---------------------------------------------------------------- requirement codes (D-009)

-- The mockups carried exactly five REQ codes, all on one screen. D-009 extends the scheme to
-- every spec field so shop floor, QC and customer share a citation for any line.
create table requirements (
  id            uuid primary key default gen_random_uuid(),
  job_id        uuid not null references jobs(id) on delete cascade,
  code          text not null,                         -- 'REQ-MAT-01'
  domain        text not null,                         -- 'MAT' | 'PUR' | 'GEM' | 'FIN' | 'TML' | ...
  label         text not null,                         -- 'Base Metal'
  value_text    text,
  is_critical   boolean not null default false,
  source_field  text,                                  -- 'metal_specs.base_metal'
  created_at    timestamptz not null default now(),
  unique (job_id, code),
  constraint req_code_shape check (code ~ '^REQ-[A-Z]{3}-[0-9]{2}$')
);

create index requirements_job_idx on requirements (job_id);

-- ---------------------------------------------------------------- media capture (step 2)

-- The only step with a real gate in the mockups — but camera-only. D-011 extends it so a
-- voice note or an uploaded sketch also satisfies "capture before continue".
create table job_references (
  id            uuid primary key default gen_random_uuid(),
  job_id        uuid not null references jobs(id) on delete cascade,
  ref_code      text,                                  -- D-001: 'RF-9921'
  attachment_id uuid references attachments(id) on delete cascade,
  is_primary    boolean not null default false,
  note          text,
  created_at    timestamptz not null default now(),
  constraint ref_code_shape check (ref_code is null or ref_code ~ '^RF-[0-9]{4}$')
);

-- ---------------------------------------------------------------- design spec (steps 3-4)

create table product_specs (
  job_id            uuid primary key references jobs(id) on delete cascade,

  -- engagement_ring_specs_expanded is canonical (D-012): it is visual_design_specs plus
  -- metal_finish, band_profile and side_stone_setting.
  setting_style     setting_style,
  setting_detail    text,                              -- '6-Prong Cathedral', 'Micro-pave'
  metal_finish      metal_finish,
  band_profile      band_profile,
  fit               fit_profile,
  side_stones       side_stone_setting,
  design_intent     design_intent,
  design_intent_note text,                             -- the free text behind 'Other Idea',
                                                       -- which the mockup preselected and never asked for

  -- Ring sizing. D-012: engagement_ring_specs_expanded used "(India)" while its sibling used
  -- "(US)". India is primary for this market; the others are stored for conversion display.
  ring_size_in      numeric(4,1),                      -- India scale, e.g. 14.0
  ring_size_us      numeric(4,2),                      -- e.g. 6.50
  ring_size_uk      text,                              -- e.g. 'N'
  band_width_mm     numeric(5,2),

  -- Non-ring dimensions. The mockups hardcoded ring-only fields with no conditional swap
  -- for earrings / necklace / bangle; D-012 requires the swap.
  length_mm         numeric(6,2),
  inner_dia_mm      numeric(6,2),
  drop_mm           numeric(6,2),

  notes             text,
  updated_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------- metal (step 5)

-- D-012: a UNION of metal_materials and quick_specs. They were never iterations of each other —
-- they are two different screens for one step with disjoint field sets.
create table metal_specs (
  job_id            uuid primary key references jobs(id) on delete cascade,

  base_metal        base_metal,                        -- both screens
  purity            metal_purity,                      -- both; dependency on base_metal is
                                                       -- validated in app (22K rose gold is not a product)
  color             metal_color,                       -- metal_materials only
  target_weight_g   numeric(8,3),                      -- metal_materials only: '8.5 g'
  weight_tol_g      numeric(8,3),                      -- metal_materials only: '± 0.5 g'
  customer_supplied boolean not null default false,    -- 'Client providing scrap or raw material'
  hallmark          text,                              -- "18K, Maker's Mark, PT950"
  alloy_notes       text,

  gemstone_inset    boolean,                           -- quick_specs only, REQ-GEM-03.
                                                       -- false must SKIP the stone step — the
                                                       -- mockup's CTA said PROCEED TO STONES regardless.
  target_budget_min bigint,                            -- quick_specs only, REQ-FIN-04, minor units
  target_budget_max bigint,
  updated_at        timestamptz not null default now()
);

comment on column metal_specs.gemstone_inset is
  'REQ-GEM-03. When false the wizard skips the stone step. The mockup declared this gate and '
  'never wired it — its CTA read PROCEED TO STONES even when the answer was No.';

-- ---------------------------------------------------------------- stones (step 6)

-- The worst version drift in the project: 7 variants, none complete, each redesign making a
-- different subset editable. This table is the union of all of them (D-012).
create table stones (
  id                uuid primary key default gen_random_uuid(),
  job_id            uuid not null references jobs(id) on delete cascade,
  role              stone_role not null default 'center',
  position          int not null default 0,

  sourcing          stone_sourcing not null default 'needs_sourcing',

  stone_type        stone_type,
  -- D-012: recovered from B/stone_requirements, the ONLY file of 46 that had it. Natural vs
  -- lab-grown changes valuation, disclosure obligations and certification.
  origin            stone_origin,
  shape             stone_shape,

  carat             numeric(6,2),                      -- typed input, lost in later variants
  -- refined_inputs split the vague 'Dimensions (L x W x D mm)' string into discrete rows.
  length_mm         numeric(6,2),
  width_mm          numeric(6,2),
  depth_mm          numeric(6,2),

  color             diamond_color,                     -- grade ladders exist only in interactive_inputs
  color_range       text,                              -- 'F-G' where a range was given
  clarity           diamond_clarity,
  clarity_range     text,                              -- 'VS1-VS2'
  cut               diamond_cut,
  treatment         text,                              -- 'Unheated'
  provenance        text,                              -- 'MMR' (Myanmar)

  cert_required     boolean not null default false,    -- the user's own reference crop specified
                                                       -- this as a boolean toggle, not a lab dropdown
  cert_lab          cert_lab,
  cert_number       text,
  cert_attachment   uuid references attachments(id) on delete set null,
  photo_attachment  uuid references attachments(id) on delete set null,

  -- goods-in custody, from customer_supplied — the only variant that had it
  declared_value    bigint,                            -- minor units. D-006/critical gap:
                                                       -- the mockups captured NOTHING here.
  verified_by       uuid references app_users(id) on delete set null,
  verified_at       timestamptz,
  receipt_code      text,
  risk_ack          boolean not null default false,

  inventory_item_id uuid,                              -- FK added in 0007 after inventory exists
  notes             text,
  created_at        timestamptz not null default now()
);

create index stones_job_idx on stones (job_id, role, position);

comment on column stones.origin is
  'D-012. Survived in exactly one file out of 46 mockups. Do not make this nullable-by-habit: '
  'it is a first-class commercial field.';
comment on column stones.declared_value is
  'Critical gap in the mockups: the shop accepted custody of a client stone with no declared '
  'value, no verifier, no timestamp and no receipt. All four are required when '
  'sourcing = customer_supplied.';

-- ---------------------------------------------------------------- melee

create table melee_parcels (
  id              uuid primary key default gen_random_uuid(),
  job_id          uuid not null references jobs(id) on delete cascade,
  -- The mockups' segmented control meant two different things across variants: timing
  -- ("Include Now / Include Later") vs sourcing. D-012 resolves it to sourcing.
  sourcing        stone_sourcing not null default 'needs_sourcing',
  stone_type      stone_type not null default 'diamond',
  origin          stone_origin,
  shape           stone_shape not null default 'round_brilliant',
  size_min_mm     numeric(5,2),                        -- '1.2mm'
  size_max_mm     numeric(5,2),                        -- '1.5mm'
  total_ctw       numeric(7,3),
  piece_count     int,
  color_range     text,
  clarity_range   text,
  notes           text,
  created_at      timestamptz not null default now()
);

create index melee_job_idx on melee_parcels (job_id);

-- ---------------------------------------------------------------- delivery (step 8)

create table delivery_schedules (
  job_id              uuid primary key references jobs(id) on delete cascade,
  requested_date      date,
  hard_deadline       boolean not null default false,
  partial_allowed     boolean not null default true,
  priority            priority_level not null default 'standard',
  -- The mockup hardcoded these as constants that never varied with priority; its own source
  -- carried the comment "Could adjust buffers here based on priority".
  dispatch_buffer_d   int not null default 2,
  cert_buffer_d       int not null default 3,
  recommended_done    date,
  updated_at          timestamptz not null default now()
);

comment on column delivery_schedules.cert_buffer_d is
  'Must be zeroed when acceptance_criteria.cert_lab = none. The mockups hardcoded 3 days '
  'regardless — a declared cross-screen dependency nobody wired.';

-- ---------------------------------------------------------------- quality acceptance (step 9)

create table acceptance_criteria (
  job_id              uuid primary key references jobs(id) on delete cascade,
  match_cad           boolean not null default true,
  high_polish         boolean not null default true,
  size_weight_conform boolean not null default true,
  strict_tolerance    boolean not null default false,  -- opt-in in the mockup
  tolerance_mm        numeric(5,3) default 0.05,       -- was baked into a label, now a real value
  stones_secure       boolean not null default true,
  symmetry            boolean not null default true,
  cert_lab            cert_lab not null default 'igi',
  cert_lab_other      text,                            -- 'Other' had no name field in the mockup
  authority           quality_authority not null default 'jeweler',
  customer_notes      text,
  updated_at          timestamptz not null default now()
);

comment on column acceptance_criteria.authority is
  'Selecting customer must insert a customer-portal approval gate before QC sign-off. '
  'The mockups offered the option and had no such transition or screen.';
