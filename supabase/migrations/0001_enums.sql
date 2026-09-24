-- DhanaOS 0001 — extensions and enumerated types
-- Every enum below was recovered from the Stitch mockups. Where the mockups carried competing
-- vocabularies the winner is recorded in DECISIONS.md; rejected values are noted in comments so
-- the provenance is not lost.

create extension if not exists "pgcrypto";
create extension if not exists "uuid-ossp";

-- ---------------------------------------------------------------- identity

create type user_role as enum (
  'admin',              -- org owner
  'engineer',           -- "Ravi S. — Manufacturing Engineer", the command-centre role
  'cad_designer',       -- "Elena Rostova — Lead CAD Designer"
  'production_manager',
  'qc_inspector',
  'logistics',
  'inventory_keeper',
  'bench_operator',     -- setter / polisher / "Lead Tech"
  'partner',            -- external vendor principal  (D-008)
  'customer'            -- external retailer principal (D-008)
);

create type principal_class as enum ('internal', 'partner', 'customer');

create type partner_kind as enum (
  'casting',            -- "Patel Casting Works"
  'lab',                -- IGI / GIA / HRD
  'stone_supplier',     -- "GemSource"
  'courier',            -- Brinks / FedEx / Malca-Amit
  'hub',                -- "Central Hub"
  'other'
);

-- ---------------------------------------------------------------- job shape

-- B offered four; C dropped 'repair'. D-012 keeps B's superset.
create type job_type as enum (
  'new_custom_design',  -- "Start a fresh CAD from sketch"
  'recreate_existing',  -- "Duplicate or repair a piece"
  'reset_stone',        -- "Mounting customer materials"
  'repair'              -- "Restoration or sizing services"
);

create type product_category as enum (
  'ring', 'earrings', 'necklace', 'pendant',
  'bracelet', 'bangle', 'brooch', 'other'
);

-- product_selection showed a flat category list, but downstream screens displayed
-- "Engagement Ring" — which is a sub-style, not a category. D-012 splits them.
create type product_sub_style as enum (
  'engagement_ring', 'solitaire_ring', 'halo_ring', 'eternity_band',
  'wedding_band', 'signet_ring', 'cocktail_ring',
  'stud', 'hoop', 'drop',
  'chain', 'choker', 'tennis',
  'other'
);

create type priority_level as enum ('standard', 'rush', 'critical');

-- ---------------------------------------------------------------- lifecycle (D-002)

create type lifecycle_stage as enum (
  'inquiry', 'cad', 'approval', 'pricing', 'final_app', 'wax', 'casting',
  'assembly', 'setting', 'polishing', 'qc', 'cert', 'dispatch', 'delivered'
);

create type stage_state as enum (
  'pending',    -- not reached
  'active',     -- currently here
  'completed',
  'skipped',    -- e.g. cert when certification_required = false
  'blocked'     -- exception raised, e.g. "Caster delayed"
);

-- D-006 — the states the mockups omitted entirely.
create type job_status as enum (
  'draft',
  'pending_approval',   -- the three gates on review_job_order
  'approved_ready',
  'in_production',
  'on_hold',
  'rework',
  'cancelled',
  'completed',
  'archived'
);

-- ---------------------------------------------------------------- metal

-- Three competing vocabularies existed: Y.GOLD/W.METAL/R.GOLD, gold/platinum/silver/other,
-- and 18K Yellow/14K White/Platinum/Rose Gold. Normalised to base + colour + purity.
create type base_metal as enum ('gold', 'platinum', 'silver', 'palladium', 'other');

create type metal_color as enum ('yellow', 'white', 'rose', 'two_tone');

-- Flat list in the mockups mixed karat and millesimal with no dependency on base metal
-- (22K rose gold is not a product). Dependency is enforced in application validation.
create type metal_purity as enum ('k9', 'k14', 'k18', 'k22', 'k24', 'pt950', 'pt900', 's925');

create type metal_finish as enum ('high_polish', 'matte_satin', 'hammered', 'brushed');

create type band_profile as enum ('round', 'flat', 'knife_edge');

create type fit_profile as enum ('comfort_fit', 'standard', 'flat');

-- ---------------------------------------------------------------- setting / design

create type setting_style as enum ('prong', 'bezel', 'halo', 'tension', 'other');

create type side_stone_setting as enum ('none', 'pave', 'channel', 'shared_prong');

-- "What matters most?" — the customer-facing intent question
create type design_intent as enum ('match_exactly', 'show_off_stone', 'strong_and_safe', 'other');

-- ---------------------------------------------------------------- stones

create type stone_type as enum (
  'diamond', 'sapphire', 'ruby', 'emerald',
  'moissanite',         -- survived in exactly one file of 46
  'other'
);

-- D-012: survived in exactly ONE file across all 46 mockups and was dropped by every
-- later redesign. Natural vs lab-grown changes valuation, disclosure and certification.
create type stone_origin as enum ('natural', 'lab_grown');

create type stone_shape as enum (
  'round_brilliant', 'oval', 'pear', 'emerald_cut', 'radiant',
  'cushion', 'marquise', 'princess', 'asscher', 'heart', 'baguette', 'other'
);

create type stone_sourcing as enum (
  'needs_sourcing',     -- "Needs to be Sourced" / "Get New"  -> opens procurement
  'in_stock',           -- allocate from inventory
  'customer_supplied'   -- "Have It" -> goods-in custody flow
);

create type stone_role as enum ('center', 'accent', 'side');

create type diamond_color as enum ('d','e','f','g','h','i','j','k','l','m','other');

create type diamond_clarity as enum ('fl','if','vvs1','vvs2','vs1','vs2','si1','si2','i1','other');

create type diamond_cut as enum ('excellent','very_good','good','fair','poor');

-- ---------------------------------------------------------------- certification

-- Three disagreeing lists existed across the mockups; unioned here.
create type cert_lab as enum ('gia', 'igi', 'hrd', 'ags', 'other', 'none');

create type cert_status as enum (
  'waiting', 'sent', 'at_lab', 'in_progress', 'certified', 'returned',
  'rejected'            -- D-006: no lab-rejection path existed in the mockups
);

-- ---------------------------------------------------------------- commercial

create type pricing_basis as enum ('fixed', 'quote', 'cost_plus');

create type supplied_by as enum ('house', 'client');

-- D-003 — five customer-facing categories.
create type cost_category as enum ('metal', 'gemstones', 'labor', 'setting', 'certification');

create type quote_status as enum (
  'draft', 'sent', 'approved',
  'rejected',           -- D-006
  'counter_offered',    -- D-006
  'expired'
);

create type approval_gate_kind as enum ('design_review', 'cost_analysis', 'vendor_allocation');

create type approval_gate_state as enum ('pending', 'approved', 'rejected');

-- ---------------------------------------------------------------- quality

create type quality_authority as enum ('customer', 'jeweler', 'manufacturer', 'internal_qc');

create type qc_status as enum (
  'pending', 'in_progress', 'ready', 'approved',
  'failed'              -- D-006: designed in the mockup's CSS, unreachable in its JS
);

-- ---------------------------------------------------------------- logistics

create type dispatch_routing as enum ('jeweler', 'customer');

create type courier_kind as enum ('brinks', 'fedex', 'malca_amit', 'bluedart', 'other');

-- The mockups proved a job needs several legs, not one shipment.
create type shipment_leg as enum (
  'wax_inbound',        -- "Wax en route from Central Hub"
  'to_caster', 'from_caster',
  'to_lab', 'from_lab',
  'final_dispatch'
);

create type shipment_status as enum ('draft', 'dispatched', 'in_transit', 'delivered', 'exception');

-- ---------------------------------------------------------------- inventory

-- inventory_management showed two distinct stock models in one screen: metals bulk-by-gram,
-- stones serialised with species-dependent attribute keys.
create type stock_kind as enum ('metal_bulk', 'stone_serialized', 'consumable');

create type stock_txn_kind as enum (
  'receive', 'issue', 'return', 'adjust',
  'scrap',              -- filings, polishing loss, casting sprues
  'allocate', 'release'
);

create type uom as enum ('gram', 'carat', 'piece');

-- ---------------------------------------------------------------- collaboration

create type activity_kind as enum (
  'stage_changed', 'job_created', 'assigned', 'file_uploaded',
  'approved', 'rejected', 'comment', 'exception_raised', 'system'
);

create type attachment_kind as enum (
  'reference_image', 'sketch', 'cad_file', 'cad_render', 'stl',
  'stone_photo', 'certificate_pdf', 'casting_photo', 'qc_evidence',
  'voice_note', 'invoice', 'proof_of_delivery', 'other'
);

create type action_severity as enum ('info', 'warning', 'error', 'success');
