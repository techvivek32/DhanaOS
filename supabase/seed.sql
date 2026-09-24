-- DhanaOS seed — reference data using the real sample records from the mockups, so every
-- screen has believable content from the first run (D-007, Phase 0).
--
-- Users are NOT seeded here: they come from Supabase Auth signup, after which a row is
-- inserted into app_users. See the bottom of this file for the linking snippet.

-- ---------------------------------------------------------------- org

insert into orgs (id, name, legal_name, gstin, base_currency, address)
values (
  '00000000-0000-0000-0000-000000000001',
  'AuraForge India',
  'AuraForge Jewellery Manufacturing Pvt Ltd',
  '24AAACA1234A1Z5',
  'INR',
  '{"line1":"Plot 42, SEZ Phase II","city":"Surat","state":"Gujarat","pin":"395007","country":"IN"}'
) on conflict (id) do nothing;

-- ---------------------------------------------------------------- customers (retailers)

insert into customers (org_id, name, code, contact_name, email, payment_terms, currency, address)
values
  ('00000000-0000-0000-0000-000000000001', 'Scottsdale Diamond Co.', 'SDC',
   'Marcus Webb', 'orders@scottsdalediamond.example', 'Net 30', 'USD',
   '{"city":"Scottsdale","state":"AZ","country":"US"}'),
  ('00000000-0000-0000-0000-000000000001', 'ABC Jewelers', 'ABC',
   'Priya Shah', 'purchase@abcjewelers.example', 'Net 30', 'INR',
   '{"city":"Mumbai","state":"Maharashtra","country":"IN"}')
on conflict (org_id, code) do nothing;

-- ---------------------------------------------------------------- partners

insert into partners (org_id, kind, name, contact_name, address)
values
  ('00000000-0000-0000-0000-000000000001', 'casting', 'Patel Casting Works',
   'Nilesh Patel', '{"city":"Surat","state":"Gujarat","country":"IN"}'),
  ('00000000-0000-0000-0000-000000000001', 'hub', 'Central Hub',
   null, '{"city":"Surat","country":"IN"}'),
  ('00000000-0000-0000-0000-000000000001', 'casting', 'Forge-A',
   null, '{"city":"Surat","country":"IN"}'),
  ('00000000-0000-0000-0000-000000000001', 'lab', 'IGI Antwerp',
   null, '{"city":"Antwerp","country":"BE"}'),
  ('00000000-0000-0000-0000-000000000001', 'lab', 'GIA India',
   null, '{"city":"Mumbai","country":"IN"}'),
  ('00000000-0000-0000-0000-000000000001', 'stone_supplier', 'GemSource',
   null, '{"city":"Surat","country":"IN"}'),
  ('00000000-0000-0000-0000-000000000001', 'courier', 'Brinks Secure Logistics',
   null, '{"country":"IN"}'),
  ('00000000-0000-0000-0000-000000000001', 'courier', 'Malca-Amit',
   null, '{"country":"IN"}')
on conflict do nothing;

-- ---------------------------------------------------------------- resources

-- The mockups credited stage completions to these: "Completed by PR-02", "Bench 4", "Forge-A".
insert into resources (org_id, code, label, stage)
values
  ('00000000-0000-0000-0000-000000000001', 'PR-02',  '3D Printer 02',  'wax'),
  ('00000000-0000-0000-0000-000000000001', 'BENCH-4','Bench 4',        'assembly'),
  ('00000000-0000-0000-0000-000000000001', 'SET-1',  'Setting Bench 1','setting'),
  ('00000000-0000-0000-0000-000000000001', 'POL-1',  'Polishing 1',    'polishing')
on conflict (org_id, code) do nothing;

-- ---------------------------------------------------------------- metal rates

-- Indicative opening rates so the pricing engine has something to lock against on day one.
insert into metal_rates (org_id, base_metal, purity, currency, rate_per_g, source)
values
  ('00000000-0000-0000-0000-000000000001', 'gold',     'k24',   'INR', 985000,  'manual'),
  ('00000000-0000-0000-0000-000000000001', 'gold',     'k22',   'INR', 903000,  'manual'),
  ('00000000-0000-0000-0000-000000000001', 'gold',     'k18',   'INR', 739000,  'manual'),
  ('00000000-0000-0000-0000-000000000001', 'gold',     'k14',   'INR', 575000,  'manual'),
  ('00000000-0000-0000-0000-000000000001', 'platinum', 'pt950', 'INR', 320000,  'manual'),
  ('00000000-0000-0000-0000-000000000001', 'silver',   's925',  'INR', 11500,   'manual');

-- ---------------------------------------------------------------- inventory

-- Two stock models in one table, exactly as inventory_management implied: metals bulk by
-- gram, stones serialised and unique with SPECIES-TYPED attributes.
insert into inventory_items
  (org_id, kind, code, label, uom, qty_on_hand, reorder_level, base_metal, purity,
   unit_cost, currency, location)
values
  ('00000000-0000-0000-0000-000000000001', 'metal_bulk', 'AU-750', '18K Gold',
   'gram', 1240.500, 400, 'gold', 'k18', 739000, 'INR', 'Vault A, Safe 1'),
  ('00000000-0000-0000-0000-000000000001', 'metal_bulk', 'PT-950', 'Platinum 950',
   'gram', 450.200, 200, 'platinum', 'pt950', 320000, 'INR', 'Vault A, Safe 2')
on conflict (org_id, code) do nothing;

insert into inventory_items
  (org_id, kind, code, label, uom, qty_on_hand, stone_type, stone_origin, shape, carat,
   attrs, cert_lab, cert_number, unit_cost, currency, location)
values
  ('00000000-0000-0000-0000-000000000001', 'stone_serialized', 'DIA-9982-A',
   'Round Brilliant Diamond', 'carat', 1, 'diamond', 'natural', 'round_brilliant', 1.24,
   '{"color":"f","clarity":"vvs2","cut":"excellent"}'::jsonb,
   'gia', '2141567890', 62000000, 'INR', 'Vault A, Tray 4'),
  -- The ruby row in the mockup showed CARAT/CUT/ORIGIN, not the 4Cs — proof that gem
  -- attributes must be typed per species rather than forced into one table.
  ('00000000-0000-0000-0000-000000000001', 'stone_serialized', 'RUB-4421-C',
   'Burmese Ruby', 'carat', 1, 'ruby', 'natural', 'oval', 2.10,
   '{"cut":"excellent","treatment":"Unheated","provenance":"MMR"}'::jsonb,
   'gia', '6294417723', 41000000, 'INR', 'Vault B, Tray 1')
on conflict (org_id, code) do nothing;

-- ---------------------------------------------------------------- linking a signed-up user
--
-- After a user signs up through Supabase Auth, link them:
--
--   insert into app_users (id, org_id, principal, full_name, title, initials, email)
--   values ('<auth.uid>', '00000000-0000-0000-0000-000000000001', 'internal',
--           'Ravi S.', 'Manufacturing Engineer', 'RS', 'ravi@auraforge.example');
--
--   insert into user_roles (user_id, role)
--   values ('<auth.uid>', 'admin'), ('<auth.uid>', 'engineer');
--
-- For an external caster, link them to the partner instead — this is what actually scopes
-- their queue, replacing the mockup's decorative "Assigned to Me" chip:
--
--   insert into app_users (id, org_id, principal, full_name, email)
--   values ('<auth.uid>', '00000000-0000-0000-0000-000000000001', 'partner',
--           'Nilesh Patel', 'nilesh@patelcasting.example');
--   insert into user_roles  (user_id, role)       values ('<auth.uid>', 'partner');
--   insert into partner_users (user_id, partner_id)
--   select '<auth.uid>', id from partners where name = 'Patel Casting Works';
