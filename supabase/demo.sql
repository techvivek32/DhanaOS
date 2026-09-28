-- DhanaOS demo data — profiles for the demo sign-ins and a job parked at every interesting
-- point of the 14-stage rail, so each screen has something real to show on a fresh project.
--
-- 1. Run seed.sql first (org, customers, partners, resources, rates, inventory).
-- 2. Create these users in Supabase → Authentication → Users → Add user (any password,
--    tick "Auto Confirm User"). Any you skip are simply not provisioned:
--
--      ravi@auraforge.example            internal · admin + engineer
--      elena@auraforge.example           internal · CAD designer
--      meera@auraforge.example           internal · QC inspector
--      karan@auraforge.example           internal · logistics + inventory
--      nilesh@patelcasting.example       partner  · Patel Casting Works
--      ops@forge-a.example               partner  · Forge-A (a second caster)
--      marcus@scottsdalediamond.example  customer · Scottsdale Diamond Co.
--      priya@abcjewelers.example         customer · ABC Jewelers
--      superadmin@dhanaos.example        platform super admin (web admin panel)
--
-- 3. Run this file in the SQL editor. Re-running it is safe: profiles are upserted and the
--    jobs are only created while the org has none.
--
-- Runs as the SQL editor's role, where auth.uid() is null — which is what lets it walk the
-- stage rail directly past the 0011 guard. Never run it from the app.

-- ---------------------------------------------------------------- people

begin;

create temp table demo_people (
  email     text primary key,
  principal principal_class,
  full_name text,
  title     text,
  initials  text,
  roles     user_role[],
  partner   text,
  customer  text
) on commit drop;

insert into demo_people values
  ('ravi@auraforge.example',           'internal', 'Ravi S.',       'Manufacturing Engineer', 'RS',
   array['admin','engineer']::user_role[], null, null),
  ('elena@auraforge.example',          'internal', 'Elena Rostova', 'Lead CAD Designer',      'ER',
   array['cad_designer']::user_role[], null, null),
  ('meera@auraforge.example',          'internal', 'Meera Joshi',   'QC Inspector',           'MJ',
   array['qc_inspector']::user_role[], null, null),
  ('karan@auraforge.example',          'internal', 'Karan Mehta',   'Logistics & Vault',      'KM',
   array['logistics','inventory_keeper']::user_role[], null, null),
  ('nilesh@patelcasting.example',      'partner',  'Nilesh Patel',  'Owner',                  'NP',
   array['partner']::user_role[], 'Patel Casting Works', null),
  ('ops@forge-a.example',              'partner',  'Forge-A Desk',  'Operations',             'FA',
   array['partner']::user_role[], 'Forge-A', null),
  ('marcus@scottsdalediamond.example', 'customer', 'Marcus Webb',   'Buyer',                  'MW',
   array['customer']::user_role[], null, 'SDC'),
  ('priya@abcjewelers.example',        'customer', 'Priya Shah',    'Purchase',               'PS',
   array['customer']::user_role[], null, 'ABC');

insert into app_users (id, org_id, principal, full_name, title, initials, email)
select u.id, '00000000-0000-0000-0000-000000000001', p.principal, p.full_name, p.title,
       p.initials, p.email
  from demo_people p
  join auth.users u on lower(u.email) = p.email
on conflict (id) do update
   set principal = excluded.principal,
       full_name = excluded.full_name,
       title     = excluded.title,
       initials  = excluded.initials,
       email     = excluded.email;

insert into user_roles (user_id, role)
select u.id, r
  from demo_people p
  join auth.users u on lower(u.email) = p.email
  cross join lateral unnest(p.roles) r
on conflict do nothing;

insert into partner_users (user_id, partner_id)
select u.id, pa.id
  from demo_people p
  join auth.users u on lower(u.email) = p.email
  join partners pa on pa.name = p.partner
                  and pa.org_id = '00000000-0000-0000-0000-000000000001'
on conflict (user_id) do update set partner_id = excluded.partner_id;

insert into customer_users (user_id, customer_id)
select u.id, c.id
  from demo_people p
  join auth.users u on lower(u.email) = p.email
  join customers c on c.code = p.customer
                  and c.org_id = '00000000-0000-0000-0000-000000000001'
on conflict (user_id) do update set customer_id = excluded.customer_id;

-- The platform operator: no org, no app_users row — a platform_admins row (0014).
insert into platform_admins (user_id, full_name, email)
select u.id, 'DhanaOS Platform', u.email
  from auth.users u where lower(u.email) = 'superadmin@dhanaos.example'
on conflict (user_id) do nothing;

-- ---------------------------------------------------------------- jobs

-- Mints a real DH code, seeds the 14-row rail, and walks it to p_stage: every earlier stage
-- completed, p_stage active. The stage-cache trigger writes current_stage and the event.
create function pg_temp.demo_job(
  p_title    text,
  p_customer text,
  p_type     job_type,
  p_category product_category,
  p_style    product_sub_style,
  p_stage    lifecycle_stage,
  p_priority priority_level,
  p_due_days int,
  p_currency char(3)
) returns uuid
language plpgsql as $$
declare
  v_org    uuid := '00000000-0000-0000-0000-000000000001';
  v_id     uuid;
  v_target int;
begin
  insert into jobs (org_id, code, customer_id, job_type, category, sub_style, title, status,
                    priority, requested_delivery, promised_delivery, currency, wizard_step,
                    created_by, committed_at, created_at)
  values (v_org, fn_mint_job_code(v_org),
          (select id from customers where org_id = v_org and code = p_customer),
          p_type, p_category, p_style, p_title, 'approved_ready', p_priority,
          current_date + p_due_days, current_date + p_due_days, p_currency, 11,
          (select id from app_users where email = 'ravi@auraforge.example'),
          now() - interval '21 days', now() - interval '22 days')
  returning id into v_id;

  perform fn_seed_job_stages(v_id);
  select seq into v_target from job_stages where job_id = v_id and stage = p_stage;

  update job_stages
     set state        = 'completed',
         entered_at   = now() - ((v_target - seq + 1) * interval '36 hours'),
         completed_at = now() - ((v_target - seq) * interval '36 hours')
   where job_id = v_id and seq < v_target;

  if v_target > 1 then
    update job_stages
       set state = 'active', entered_at = now() - interval '20 hours'
     where job_id = v_id and seq = v_target;
    update jobs set status = 'in_production' where id = v_id;
  end if;

  insert into activity_events (job_id, kind, actor_label, summary, detail, created_at)
  values (v_id, 'job_created', 'Ravi S.',
          format('Job order %s created', (select code from jobs where id = v_id)),
          'Routing specs to CAD engineering and preliminary production queue.',
          now() - interval '21 days');
  return v_id;
end;
$$;

-- Five customer-facing cost categories (D-003) with the trade's GST rates (core/money.dart).
create function pg_temp.demo_quote(
  p_job uuid, p_status quote_status, p_currency char(3),
  p_metal bigint, p_gems bigint, p_labor bigint, p_setting bigint, p_cert bigint
) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  insert into quotes (job_id, version, status, basis, margin_pct, currency, sent_at,
                      decided_at, valid_until)
  values (p_job, 1, p_status, 'quote', 18, p_currency,
          case when p_status <> 'draft' then now() - interval '6 days' end,
          case when p_status = 'approved' then now() - interval '5 days' end,
          current_date + 14)
  returning id into v_id;

  insert into cost_lines (quote_id, category, label, supplied_by, qty, unit, unit_amount, amount,
                          hsn_code, tax_rate_pct, position)
  values
    (v_id, 'metal',         'Metal',               'house', 1, 'piece', p_metal,   p_metal,   '7113',   3,  1),
    (v_id, 'gemstones',     'Gemstones',           'house', 1, 'piece', p_gems,    p_gems,    '7113',   3,  2),
    (v_id, 'labor',         'CAD, finish & polish','house', 1, 'piece', p_labor,   p_labor,   '998892', 5,  3),
    (v_id, 'setting',       'Stone setting',       'house', 1, 'piece', p_setting, p_setting, '998892', 5,  4),
    (v_id, 'certification', 'Lab certification',  'house', 1, 'piece', p_cert,    p_cert,    '998346', 18, 5);
  return v_id;
end;
$$;

do $$
declare
  v_org     uuid := '00000000-0000-0000-0000-000000000001';
  v_ravi    uuid := (select id from app_users where email = 'ravi@auraforge.example');
  v_elena   uuid := (select id from app_users where email = 'elena@auraforge.example');
  v_meera   uuid := (select id from app_users where email = 'meera@auraforge.example');
  v_patel   uuid := (select id from partners where org_id = v_org and name = 'Patel Casting Works');
  v_forge   uuid := (select id from partners where org_id = v_org and name = 'Forge-A');
  v_igi     uuid := (select id from partners where org_id = v_org and name = 'IGI Antwerp');
  v_job     uuid;
  v_quote   uuid;
  v_qc      uuid;
  v_ship    uuid;
begin
  if exists (select 1 from jobs where org_id = v_org) then
    raise notice 'demo jobs skipped — org already has jobs';
    return;
  end if;

  -- Codes continue from the mockups' DH-2026-01842.
  update orgs set job_seq = 1841, job_seq_year = extract(year from now())::int where id = v_org;

  -- 1. At CAD, with the designer — the job the mockups followed.
  v_job := pg_temp.demo_job('Solitaire Crown v2.FINAL', 'SDC', 'new_custom_design', 'ring',
                            'engagement_ring', 'cad', 'rush', 18, 'USD');
  update job_stages set assigned_to = v_elena, expected_at = now() + interval '2 days'
   where job_id = v_job and stage = 'cad';
  insert into product_specs (job_id, setting_style, metal_finish, band_profile, fit, side_stones,
                             design_intent, ring_size_in, ring_size_us, band_width_mm, notes)
  values (v_job, 'prong', 'high_polish', 'round', 'comfort_fit', 'pave', 'show_off_stone',
          '14', '6.75', 2.1, 'Six-prong crown, cathedral shoulders.');
  insert into metal_specs (job_id, base_metal, purity, color, target_weight_g, weight_tol_g,
                           hallmark, gemstone_inset, target_budget_min, target_budget_max)
  values (v_job, 'platinum', 'pt950', 'white', 4.8, 0.2, true, true, 400000, 520000);
  insert into stones (job_id, role, position, sourcing, stone_type, origin, shape, carat,
                      color, clarity, cut, cert_required, cert_lab)
  values (v_job, 'center', 1, 'needs_sourcing', 'diamond', 'natural', 'round_brilliant', 1.50,
          'f', 'vs1', 'excellent', true, 'gia'),
         (v_job, 'accent', 2, 'in_stock', 'diamond', 'lab_grown', 'round_brilliant', 0.24,
          'g', 'vs2', 'very_good', false, 'none');
  insert into cad_revisions (job_id, version, seq, designer_id, designer_note, is_current)
  values (v_job, 'v1', 1, v_elena, 'First pass — prong height at 1.2 mm per REQ-GEM-03.', true);
  insert into thread_posts (job_id, author_id, author_label, stage, body, is_internal)
  values (v_job, v_ravi, 'Ravi S.', 'cad', 'Client wants the crown lower than the reference photo.', false),
         (v_job, v_elena, 'Elena Rostova', 'cad', 'Will drop the gallery 0.4 mm and resend v2.', true);

  -- 2. Waiting on the customer's price approval — the portal's approvals tab.
  v_job := pg_temp.demo_job('Halo Pendant — Lab Grown', 'ABC', 'new_custom_design', 'pendant',
                            'other', 'approval', 'standard', 30, 'INR');
  insert into stones (job_id, role, position, sourcing, stone_type, origin, shape, carat,
                      color, clarity, cut, cert_required, cert_lab)
  values (v_job, 'center', 1, 'needs_sourcing', 'diamond', 'lab_grown', 'oval', 2.00,
          'e', 'vvs2', 'excellent', true, 'igi');
  perform pg_temp.demo_quote(v_job, 'sent', 'INR', 3850000, 9200000, 650000, 280000, 350000);

  -- 3. At the caster, photo not yet uploaded — D-011 rule 1 holds the button shut.
  v_job := pg_temp.demo_job('Eternity Band 18K', 'ABC', 'new_custom_design', 'ring',
                            'eternity_band', 'casting', 'standard', 12, 'INR');
  update job_stages set assigned_partner = v_patel, expected_at = now() + interval '2 days'
   where job_id = v_job and stage = 'casting';
  insert into casting_params (job_id, partner_id, alloy, flask_temp_c, metal_temp_c,
                              tree_weight_g, received_at, expected_at)
  values (v_job, v_patel, '18K Yellow', 650, 1080, 38.5, now() - interval '20 hours',
          now() + interval '2 days');
  insert into metal_specs (job_id, base_metal, purity, color, target_weight_g, weight_tol_g, hallmark)
  values (v_job, 'gold', 'k18', 'yellow', 3.6, 0.15, true);
  v_quote := pg_temp.demo_quote(v_job, 'approved', 'INR', 2660000, 4100000, 420000, 380000, 0);

  -- 4. At a different caster, with a client's own ruby in custody.
  v_job := pg_temp.demo_job('Ruby Cocktail Ring', 'SDC', 'reset_stone', 'ring', 'cocktail_ring',
                            'casting', 'critical', 6, 'USD');
  update job_stages set assigned_partner = v_forge, expected_at = now() - interval '4 hours'
   where job_id = v_job and stage = 'casting';
  insert into casting_params (job_id, partner_id, alloy, received_at, expected_at)
  values (v_job, v_forge, '18K Rose', now() - interval '3 days', now() - interval '4 hours');
  insert into stones (job_id, role, position, sourcing, stone_type, origin, shape, carat, cut,
                      treatment, provenance, cert_required, cert_lab, cert_number,
                      declared_value, verified_by, verified_at, receipt_code, risk_ack)
  values (v_job, 'center', 1, 'customer_supplied', 'ruby', 'natural', 'oval', 2.10, 'excellent',
          'Unheated', 'MMR', true, 'gia', '6294417723', 4100000, v_ravi,
          now() - interval '9 days', 'RCPT-2026-0142', true);
  insert into job_exceptions (job_id, stage, raised_by, partner_id, title, detail, severity)
  values (v_job, 'casting', v_ravi, v_forge, 'Caster delayed',
          'Furnace maintenance — new ETA tomorrow noon.', 'warning');

  -- 5. In QC, three of five checks passed — authorisation stays shut until all five are.
  v_job := pg_temp.demo_job('Classic Studs 1ct', 'SDC', 'new_custom_design', 'earrings', 'stud',
                            'qc', 'standard', 9, 'USD');
  insert into qc_inspections (job_id, attempt, status, inspector_id, authority)
  values (v_job, 1, 'in_progress', v_meera, 'internal_qc')
  returning id into v_qc;
  insert into qc_checklist_items (inspection_id, position, label, helper, passed, checked_by, checked_at)
  values (v_qc, 1, 'Weight within tolerance', 'Target: 2.4g 18K. Allowable variance: ±0.1g.', true, v_meera, now()),
         (v_qc, 2, 'Stones secure',           'Tap test on every prong.',                      true, v_meera, now()),
         (v_qc, 3, 'Symmetry',                'Pair matched under 10x.',                       true, v_meera, now()),
         (v_qc, 4, 'High polish finish',      'No drag lines under loupe.',                    null, null, null),
         (v_qc, 5, 'Hallmark (BIS HUID)',     'HUID stamped and legible.',                     null, null, null);
  perform pg_temp.demo_quote(v_job, 'approved', 'USD', 98000, 310000, 22000, 18000, 15000);

  -- 6. Ready to dispatch, security protocol half done — fn_dispatch_shipment refuses.
  v_job := pg_temp.demo_job('Tennis Bracelet 5ct', 'ABC', 'new_custom_design', 'bracelet',
                            'tennis', 'dispatch', 'rush', 3, 'INR');
  insert into certificates (job_id, required, lab, lab_partner_id, status, sent_at, cert_number)
  values (v_job, true, 'igi', v_igi, 'certified', now() - interval '8 days', 'LG612345678');
  insert into shipments (job_id, leg, status, routing, courier, to_address, declared_value,
                         currency, insured, signature_req, white_glove)
  values (v_job, 'final_dispatch', 'draft', 'jeweler', 'brinks',
          '{"line1":"Kala Ghoda","city":"Mumbai","state":"Maharashtra","pin":"400001","country":"IN"}',
          45000000, 'INR', true, true, true)
  returning id into v_ship;
  insert into shipment_checks (shipment_id, position, label, passed, checked_by, checked_at)
  values (v_ship, 1, 'Tamper-evident seal applied', true,  v_ravi, now()),
         (v_ship, 2, 'Seal number photographed',    true,  v_ravi, now()),
         (v_ship, 3, 'Declared value matches invoice', false, null, null),
         (v_ship, 4, 'Two-person packing sign-off', false, null, null);
  perform pg_temp.demo_quote(v_job, 'approved', 'INR', 6200000, 24500000, 900000, 1500000, 450000);

  -- 7. A repair blocked at setting.
  v_job := pg_temp.demo_job('Wedding Band Repair', 'ABC', 'repair', 'ring', 'wedding_band',
                            'setting', 'standard', 5, 'INR');
  update job_stages set state = 'blocked', blocked_reason = 'Replacement accent stone on order'
   where job_id = v_job and stage = 'setting';

  -- 8. Delivered — history for the lists and the portal.
  v_job := pg_temp.demo_job('Signet Ring — Family Crest', 'SDC', 'new_custom_design', 'ring',
                            'signet_ring', 'delivered', 'standard', -10, 'USD');
  update job_stages set state = 'completed', completed_at = now() - interval '2 days'
   where job_id = v_job and stage = 'delivered';
  update jobs set status = 'completed', closed_at = now() - interval '2 days' where id = v_job;

  -- 9. A draft still in the intake wizard.
  insert into jobs (org_id, draft_code, customer_id, job_type, category, sub_style, title,
                    status, priority, currency, wizard_step, created_by)
  values (v_org, 'DRAFT-992A', (select id from customers where org_id = v_org and code = 'SDC'),
          'recreate_existing', 'necklace', 'choker', 'Emerald Choker (draft)', 'draft',
          'standard', 'USD', 5, v_ravi);
end $$;

commit;
