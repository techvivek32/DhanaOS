-- DhanaOS 0005 — pricing, quotes, approval gates, invoicing
-- D-003: five cost categories. D-004: integer minor units + currency, never floats.
-- The mockups had NO pricing engine: every money figure was hardcoded text, the commercial
-- screen had zero inputs, and its four cost lines summed to $970 with no subtotal displayed.

-- ---------------------------------------------------------------- metal rates

-- commercial_requirements showed a "Locked Rate" badge implying a rate snapshot that no field
-- stored a timestamp for. Rates are first-class here.
create table metal_rates (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  base_metal    base_metal not null,
  purity        metal_purity,
  currency      char(3) not null default 'INR',
  rate_per_g    bigint not null,                       -- minor units per gram
  source        text,                                  -- 'MCX', 'manual'
  effective_at  timestamptz not null default now(),
  created_by    uuid references app_users(id) on delete set null
);

create index metal_rates_lookup on metal_rates (org_id, base_metal, purity, effective_at desc);

-- ---------------------------------------------------------------- quotes

create table quotes (
  id                uuid primary key default gen_random_uuid(),
  job_id            uuid not null references jobs(id) on delete cascade,
  version           int not null default 1,
  status            quote_status not null default 'draft',

  basis             pricing_basis not null default 'fixed',
  margin_pct        numeric(5,2),                      -- revealed by cost_plus; the mockup's
                                                       -- three basis buttons had no JS at all
  currency          char(3) not null default 'INR',

  -- rate lock (the "Locked Rate" badge)
  metal_rate_id     uuid references metal_rates(id) on delete set null,
  rate_locked_at    timestamptz,

  -- envelope, from commercial_requirements' TARGET UNIT PRICE / MAX APPROVED
  target_unit_price bigint,
  max_approved      bigint,

  -- derived; maintained by fn_recalc_quote. The mockup's utilization bar was literally
  -- style="width: 85%" when the real figure was 90.8%.
  subtotal          bigint not null default 0,
  tax_total         bigint not null default 0,
  grand_total       bigint not null default 0,

  valid_until       date,
  sent_at           timestamptz,
  decided_at        timestamptz,
  decided_by        uuid references app_users(id) on delete set null,
  decision_note     text,                              -- D-006: reject / counter-offer reason
  counter_amount    bigint,                            -- D-006: no counter path existed
  created_at        timestamptz not null default now(),

  unique (job_id, version)
);

create index quotes_job_idx on quotes (job_id, version desc);

-- ---------------------------------------------------------------- cost lines

create table cost_lines (
  id            uuid primary key default gen_random_uuid(),
  quote_id      uuid not null references quotes(id) on delete cascade,
  category      cost_category not null,                -- D-003, five categories
  label         text not null,                         -- 'Master Crafter - Assembly & Polish'
  detail        text,                                  -- '18K White Gold (14.2g)'
  supplied_by   supplied_by not null default 'house',
  qty           numeric(10,3) not null default 1,
  unit          uom,
  unit_amount   bigint not null default 0,             -- minor units
  amount        bigint not null default 0,             -- qty * unit_amount, maintained in app
  hsn_code      text default '7113',                   -- D-004, jewellery
  tax_rate_pct  numeric(5,2) default 3.00,             -- GST on jewellery
  -- when the client owns the material, this is the declared value, not a cost
  is_client_owned boolean not null default false,
  declared_value  bigint,
  position      int not null default 0
);

create index cost_lines_quote_idx on cost_lines (quote_id, position);

-- ---------------------------------------------------------------- approval gates

-- review_job_order showed three gates, all "Pending", with no screen behind any of them.
create table approval_gates (
  id            uuid primary key default gen_random_uuid(),
  job_id        uuid not null references jobs(id) on delete cascade,
  kind          approval_gate_kind not null,
  state         approval_gate_state not null default 'pending',
  decided_by    uuid references app_users(id) on delete set null,
  decided_at    timestamptz,
  note          text,
  created_at    timestamptz not null default now(),
  unique (job_id, kind)
);

-- ---------------------------------------------------------------- invoicing (D-004)

-- Entirely absent from the mockups: "Confirm Dispatch" was the last wired action in all 46
-- screens. An Indian manufacturer cannot legally ship without a tax invoice.
create table invoices (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  job_id          uuid references jobs(id) on delete set null,
  customer_id     uuid not null references customers(id) on delete restrict,
  invoice_no      text not null,
  invoice_date    date not null default current_date,
  currency        char(3) not null default 'INR',

  place_of_supply text,
  is_interstate   boolean not null default false,      -- drives IGST vs CGST+SGST
  subtotal        bigint not null default 0,
  cgst            bigint not null default 0,
  sgst            bigint not null default 0,
  igst            bigint not null default 0,
  grand_total     bigint not null default 0,

  pdf_attachment  uuid references attachments(id) on delete set null,
  issued_at       timestamptz,
  created_at      timestamptz not null default now(),
  unique (org_id, invoice_no)
);

create table payments (
  id            uuid primary key default gen_random_uuid(),
  invoice_id    uuid not null references invoices(id) on delete cascade,
  amount        bigint not null,
  currency      char(3) not null default 'INR',
  method        text,                                  -- 'neft', 'upi', 'cheque'
  reference     text,
  received_at   timestamptz not null default now(),
  recorded_by   uuid references app_users(id) on delete set null
);

create index payments_invoice_idx on payments (invoice_id);
