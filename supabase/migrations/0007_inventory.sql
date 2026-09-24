-- DhanaOS 0007 — inventory
-- inventory_management shipped NO JavaScript at all: search, filter and "Assign" did nothing,
-- and both stock bars were hardcoded widths. Two distinct stock models coexisted in that one
-- screen and are modelled separately here.

create table inventory_items (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  kind            stock_kind not null,
  code            text not null,                       -- 'AU-750', 'PT-950', 'DIA-9982-A'
  label           text not null,                       -- '18K Gold', 'Round Brilliant Diamond'

  -- metal_bulk: quantity is a running balance in grams
  -- stone_serialized: quantity is always 1 and the item is unique
  uom             uom not null default 'gram',
  qty_on_hand     numeric(12,3) not null default 0,
  qty_allocated   numeric(12,3) not null default 0,
  reorder_level   numeric(12,3),                       -- the progress bars implied a threshold
                                                       -- that no field stored

  -- bulk metal attributes
  base_metal      base_metal,
  purity          metal_purity,

  -- serialized stone attributes. The mockup proved these must be SPECIES-TYPED, not a fixed
  -- 4C table: the diamond row showed CARAT/COLOR/CLARITY while the ruby row showed
  -- CARAT/CUT/ORIGIN. Common columns below, species extras in attrs.
  stone_type      stone_type,
  stone_origin    stone_origin,
  shape           stone_shape,
  carat           numeric(6,2),
  attrs           jsonb not null default '{}'::jsonb,  -- {"color":"F","clarity":"VVS2"}
                                                       -- {"cut":"EX","treatment":"Unheated"}
  cert_lab        cert_lab,
  cert_number     text,
  cert_pdf_id     uuid references attachments(id) on delete set null,

  -- costing, absent entirely from the mockup
  unit_cost       bigint,                              -- minor units per uom
  currency        char(3) not null default 'INR',
  supplier_id     uuid references partners(id) on delete set null,
  lot_ref         text,

  location        text,                                -- 'Vault A, Tray 4'
  photo_id        uuid references attachments(id) on delete set null,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),

  unique (org_id, code),
  constraint inv_serialized_qty check (kind <> 'stone_serialized' or qty_on_hand <= 1),
  constraint inv_alloc_sane     check (qty_allocated >= 0 and qty_allocated <= qty_on_hand)
);

create index inventory_kind_idx     on inventory_items (org_id, kind) where is_active;
create index inventory_metal_idx    on inventory_items (org_id, base_metal, purity)
  where kind = 'metal_bulk';
create index inventory_stone_idx    on inventory_items (org_id, stone_type, carat)
  where kind = 'stone_serialized';

comment on column inventory_items.attrs is
  'Species-typed gem attributes. The mockup showed diamond = CARAT/COLOR/CLARITY and '
  'ruby = CARAT/CUT/ORIGIN, so a fixed 4C table would be wrong.';

-- ---------------------------------------------------------------- allocation

-- The single "Assign" button in the mockup implied a job picker that did not exist.
create table stock_allocations (
  id              uuid primary key default gen_random_uuid(),
  item_id         uuid not null references inventory_items(id) on delete cascade,
  job_id          uuid not null references jobs(id) on delete cascade,
  stone_id        uuid references stones(id) on delete set null,
  qty             numeric(12,3) not null,
  allocated_by    uuid references app_users(id) on delete set null,
  allocated_at    timestamptz not null default now(),
  released_at     timestamptz,
  issued_at       timestamptz                          -- physically pulled from the vault
);

create index alloc_job_idx  on stock_allocations (job_id) where released_at is null;
create index alloc_item_idx on stock_allocations (item_id) where released_at is null;

-- Deferred FK: stones.inventory_item_id could not be declared in 0004 because this table
-- did not exist yet.
alter table stones
  add constraint stones_inventory_fk
  foreign key (inventory_item_id) references inventory_items(id) on delete set null;

-- ---------------------------------------------------------------- transactions (append-only)

-- Jewelry manufacturing loses measurable metal to filings, polishing and casting sprues, and
-- the mockup's own dashboard alerted "Stones missing for DH-1061 — Melee diamonds count
-- mismatch at receiving". Reconciliation is a live business problem the designs never solved.
create table stock_transactions (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  item_id         uuid not null references inventory_items(id) on delete restrict,
  kind            stock_txn_kind not null,
  qty             numeric(12,3) not null,              -- signed: receive +, issue -, scrap -
  job_id          uuid references jobs(id) on delete set null,
  stage           lifecycle_stage,
  unit_cost       bigint,
  currency        char(3) not null default 'INR',
  supplier_id     uuid references partners(id) on delete set null,
  lot_ref         text,
  reference       text,                                -- invoice / GRN number
  note            text,
  created_by      uuid references app_users(id) on delete set null,
  created_at      timestamptz not null default now()
);

create index stock_txn_item_idx on stock_transactions (item_id, created_at desc);
create index stock_txn_job_idx  on stock_transactions (job_id) where job_id is not null;

revoke update, delete on stock_transactions from public;

-- ---------------------------------------------------------------- goods-in custody

-- Critical gap in the mockups: "Verified & Logged in Inventory" was a status chip with no
-- declared value, no verifier identity, no timestamp, no receipt id and no risk acknowledgement
-- behind it. The shop took custody of a client's diamond with no record of what it accepted.
create table goods_in_receipts (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  job_id          uuid not null references jobs(id) on delete cascade,
  customer_id     uuid references customers(id) on delete set null,
  receipt_code    text not null,                       -- 'GRN-2026-00184'
  description     text not null,
  declared_value  bigint not null,
  currency        char(3) not null default 'INR',
  received_by     uuid not null references app_users(id) on delete restrict,
  received_at     timestamptz not null default now(),
  customer_sig_id uuid references attachments(id) on delete set null,
  photo_ids       uuid[] not null default '{}',
  cert_id         uuid references attachments(id) on delete set null,
  risk_ack        boolean not null default false,
  insurance_ref   text,
  returned_at     timestamptz,
  note            text,
  unique (org_id, receipt_code)
);

create index grn_job_idx on goods_in_receipts (job_id);
