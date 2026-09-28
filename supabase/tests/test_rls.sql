-- D-008 and D-011, as tests rather than notes. Run through supabase/tests/run.sh.
--
-- Loads demo.sql over the seed, signs in as each principal the way PostgREST would (role +
-- request.jwt.claims), and asserts what that principal can and cannot do. Every assertion
-- names the hole it guards; a failure stops the run.

\set ON_ERROR_STOP 1
-- Results are noise; the NOTICEs are the report.
\o /dev/null
set client_min_messages = warning;

-- ---------------------------------------------------------------- harness

insert into auth.users (email) values
  ('ravi@auraforge.example'), ('elena@auraforge.example'), ('meera@auraforge.example'),
  ('karan@auraforge.example'), ('nilesh@patelcasting.example'), ('ops@forge-a.example'),
  ('marcus@scottsdalediamond.example'), ('priya@abcjewelers.example'),
  ('intruder@other-org.example');

\ir ../demo.sql

-- A second tenant, to prove org isolation.
insert into orgs (id, name) values ('00000000-0000-0000-0000-000000000002', 'Other Workshop');
insert into app_users (id, org_id, principal, full_name, email)
select id, '00000000-0000-0000-0000-000000000002', 'internal', 'Intruder', email
  from auth.users where email = 'intruder@other-org.example';
insert into user_roles (user_id, role)
select id, 'admin' from auth.users where email = 'intruder@other-org.example';

create schema tests;
grant usage on schema tests to anon, authenticated;

create function tests.uid(p_email text) returns uuid language sql stable security definer as $$
  select id from auth.users where email = p_email
$$;

create function tests.job(p_title text) returns uuid language sql stable security definer as $$
  select id from public.jobs where title = p_title
$$;

create function tests.login(p_email text) returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims',
    case when p_email is null then ''
         else json_build_object('sub', tests.uid(p_email), 'role', 'authenticated')::text end,
    false);
  if p_email is null then set role anon; else set role authenticated; end if;
end $$;

create function tests.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_msg; end if;
  raise notice 'ok   %', p_msg;
end $$;

-- The statement must raise. p_like, when given, must appear in the error.
create function tests.refused(p_sql text, p_msg text, p_like text default null)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if p_like is not null and sqlerrm not ilike '%' || p_like || '%' then
      raise exception 'FAIL: % — refused, but with "%"', p_msg, sqlerrm;
    end if;
    raise notice 'ok   % (%)', p_msg, sqlerrm;
    return;
  end;
  raise exception 'FAIL: % — the statement succeeded', p_msg;
end $$;

-- Rows a statement touched. RLS filters UPDATE/DELETE silently, so zero is a refusal.
create function tests.touched(p_sql text) returns int language plpgsql as $$
declare n int;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on all functions in schema tests to anon, authenticated;
set client_min_messages = notice;

-- ---------------------------------------------------------------- anon: the key in the APK

select tests.login(null);
select tests.refused('select * from v_job_list',        'anon cannot read the job list view');
select tests.refused('select * from v_digital_thread',  'anon cannot read the digital thread');
select tests.refused('select * from v_partner_queue',   'anon cannot read the partner queue');
select tests.refused('select * from jobs',              'anon cannot read jobs');
select tests.refused(format('select fn_complete_stage(%L, ''cad'', %L)',
                     tests.job('Solitaire Crown v2.FINAL'), tests.uid('ravi@auraforge.example')),
                     'anon cannot complete a stage');

-- ---------------------------------------------------------------- customer

select tests.login('marcus@scottsdalediamond.example');
select tests.ok((select count(*) from v_job_list) > 0, 'customer sees their own jobs');
select tests.ok(not exists (select 1 from v_job_list where customer_name is distinct from 'Scottsdale Diamond Co.'),
                'customer sees no other customer''s job through v_job_list');
select tests.ok(not exists (select 1 from v_digital_thread where is_internal),
                'customer sees no internal thread posts through v_digital_thread');
select tests.ok(not exists (select 1 from jobs where title = 'Halo Pendant — Lab Grown'),
                'customer cannot read another customer''s job');
select tests.ok(not exists (select 1 from quotes where status = 'draft'),
                'customer sees no draft quotes');
select tests.ok(tests.touched(format(
  'update cost_lines set amount = 1 where quote_id in (select id from quotes where job_id = %L)',
  tests.job('Classic Studs 1ct'))) = 0,
  'customer cannot rewrite their own quote''s cost lines');
select tests.ok(tests.touched(
  'update shipment_checks set passed = true') = 0,
  'customer cannot pass dispatch security checks');
select tests.refused(format('insert into stones (job_id, stone_type, origin) values (%L, ''diamond'', ''natural'')',
                     tests.job('Classic Studs 1ct')),
                     'customer cannot add stones to their job');
select tests.refused(format('select fn_complete_stage(%L, ''qc'', %L)',
                     tests.job('Classic Studs 1ct'), tests.uid('marcus@scottsdalediamond.example')),
                     'customer cannot complete a stage', 'workshop or the assigned partner');
select tests.refused(format(
  'insert into activity_events (job_id, kind, actor_id, summary) values (%L, ''approved'', %L, ''Approved'')',
  tests.job('Classic Studs 1ct'), tests.uid('ravi@auraforge.example')),
  'customer cannot sign the audit trail as someone else');
select tests.ok(tests.touched(format(
  'insert into activity_events (job_id, kind, actor_id, actor_label, stage, summary) values (%L, ''approved'', %L, ''Marcus Webb'', ''approval'', ''Design approved'')',
  tests.job('Classic Studs 1ct'), tests.uid('marcus@scottsdalediamond.example'))) = 1,
  'customer can record their own decision');
select tests.refused(format(
  'insert into thread_posts (job_id, author_id, body, is_internal) values (%L, %L, ''psst'', true)',
  tests.job('Classic Studs 1ct'), tests.uid('marcus@scottsdalediamond.example')),
  'customer cannot write an internal thread post');
select tests.ok(not storage_can_access('job-files',
  '00000000-0000-0000-0000-000000000001/' || tests.job('Halo Pendant — Lab Grown') || '/cad_render/x.png'),
  'customer cannot read another customer''s files');
select tests.ok(storage_can_access('job-files',
  '00000000-0000-0000-0000-000000000001/' || tests.job('Classic Studs 1ct') || '/cad_render/x.png'),
  'customer can read their own job''s files');
select tests.ok(not storage_can_access('vault', '00000000-0000-0000-0000-000000000001/_org/stone_photo/x.jpg'),
  'customer cannot read the vault');

-- ---------------------------------------------------------------- partner

select tests.login('nilesh@patelcasting.example');
select tests.ok((select count(*) from v_partner_queue) = 1, 'caster sees exactly its one job in the queue');
select tests.ok(not exists (select 1 from jobs where title = 'Ruby Cocktail Ring'),
                'caster cannot see another caster''s job');
select tests.ok(not exists (select 1 from quotes), 'caster sees no prices');
select tests.refused(format(
  'update job_stages set state = ''completed'' where job_id = %L and stage = ''casting''',
  tests.job('Eternity Band 18K')),
  'caster cannot complete casting by writing the column', 'Complete Stage');
select tests.refused(format(
  'update job_stages set assigned_partner = null where job_id = %L and stage = ''casting''',
  tests.job('Eternity Band 18K')),
  'caster cannot unassign itself', 'Only the workshop');
select tests.refused(format('select fn_complete_stage(%L, ''casting'', %L)',
                     tests.job('Eternity Band 18K'), tests.uid('nilesh@patelcasting.example')),
                     'D-011 rule 1: no casting completion without a photo', 'casting photo');
select tests.refused(format('insert into stones (job_id, stone_type, origin) values (%L, ''diamond'', ''natural'')',
                     tests.job('Eternity Band 18K')),
                     'caster cannot add stones');

-- Report an issue: exception row, then block and resume the stage.
select tests.ok(tests.touched(format(
  'insert into job_exceptions (job_id, stage, raised_by, title) values (%L, ''casting'', %L, ''Porosity on shank'')',
  tests.job('Eternity Band 18K'), tests.uid('nilesh@patelcasting.example'))) = 1,
  'caster can report an issue');
select tests.ok(tests.touched(format(
  'update job_stages set state = ''blocked'', blocked_reason = ''Porosity on shank'' where job_id = %L and stage = ''casting''',
  tests.job('Eternity Band 18K'))) = 1,
  'caster can block its own stage');
select tests.refused(format('select fn_complete_stage(%L, ''casting'', %L)',
                     tests.job('Eternity Band 18K'), tests.uid('nilesh@patelcasting.example')),
                     'a blocked stage cannot be completed', 'blocked');
select tests.ok(tests.touched(format(
  'update job_stages set state = ''active'', blocked_reason = null where job_id = %L and stage = ''casting''',
  tests.job('Eternity Band 18K'))) = 1,
  'caster can resume its own stage');

-- Upload the evidence, then complete.
select tests.ok(tests.touched(format(
  'insert into attachments (org_id, job_id, kind, bucket, path, filename, uploaded_by) values (%L, %L, ''casting_photo'', ''job-files'', ''p/x.jpg'', ''x.jpg'', %L)',
  '00000000-0000-0000-0000-000000000001', tests.job('Eternity Band 18K'), tests.uid('nilesh@patelcasting.example'))) = 1,
  'caster can attach the casting photo');
select tests.ok(tests.touched(format(
  'update casting_params set photo_id = (select id from attachments where job_id = %L and kind = ''casting_photo'') where job_id = %L',
  tests.job('Eternity Band 18K'), tests.job('Eternity Band 18K'))) = 1,
  'caster can record the photo on its casting parameters');
select fn_complete_stage(tests.job('Eternity Band 18K'), 'casting', tests.uid('nilesh@patelcasting.example'));
select tests.ok((select current_stage from jobs where id = tests.job('Eternity Band 18K')) = 'assembly',
                'casting completes with a photo and the job advances to assembly');

select tests.login('ops@forge-a.example');
select tests.refused(format('select fn_complete_stage(%L, ''casting'', %L)',
                     tests.job('Eternity Band 18K'), tests.uid('ops@forge-a.example')),
                     'a caster cannot touch another caster''s job', 'not available');

-- ---------------------------------------------------------------- internal

select tests.login('meera@auraforge.example');
select tests.refused(format('select fn_complete_stage(%L, ''qc'', %L)',
                     tests.job('Classic Studs 1ct'), tests.uid('meera@auraforge.example')),
                     'D-011 rule 3: QC refuses with unchecked items', 'unchecked');
update qc_checklist_items set passed = true
 where inspection_id in (select id from qc_inspections where job_id = tests.job('Classic Studs 1ct'));
select fn_complete_stage(tests.job('Classic Studs 1ct'), 'qc', tests.uid('meera@auraforge.example'));
select tests.ok((select current_stage from jobs where id = tests.job('Classic Studs 1ct')) = 'cert',
                'QC authorises at a full checklist');

select tests.login('ravi@auraforge.example');
select tests.refused(format('select fn_complete_stage(%L, ''cad'', %L)',
                     tests.job('Solitaire Crown v2.FINAL'), tests.uid('elena@auraforge.example')),
                     'nobody completes a stage in someone else''s name', 'as yourself');
select tests.refused(format('select fn_complete_stage(%L, ''polishing'', %L)',
                     tests.job('Solitaire Crown v2.FINAL'), tests.uid('ravi@auraforge.example')),
                     'a pending stage cannot be completed out of order', 'not the active stage');
select tests.ok(tests.touched(format(
  'update job_stages set assigned_to = %L where job_id = %L and stage = ''cad''',
  tests.uid('ravi@auraforge.example'), tests.job('Solitaire Crown v2.FINAL'))) = 1,
  'the workshop can reassign a stage (the assign sheet saves)');
select tests.ok((select coalesce(sum(job_count), 0) from v_stage_counters) >= 5,
                'dashboard counters count in-production jobs');

select tests.refused(format('select fn_complete_stage(%L, ''dispatch'', %L)',
                     tests.job('Tennis Bracelet 5ct'), tests.uid('ravi@auraforge.example')),
                     'the dispatch stage cannot be closed before the package leaves', 'dispatch it from Shipping');
select tests.refused(format('select fn_dispatch_shipment(%L, %L)',
  (select id from shipments where job_id = tests.job('Tennis Bracelet 5ct')), tests.uid('ravi@auraforge.example')),
  'D-011: dispatch refused while security checks are open', 'security protocol');
update shipment_checks set passed = true
 where shipment_id in (select id from shipments where job_id = tests.job('Tennis Bracelet 5ct'));
select fn_dispatch_shipment((select id from shipments where job_id = tests.job('Tennis Bracelet 5ct')),
                            tests.uid('ravi@auraforge.example'));
select tests.refused(format('select fn_dispatch_shipment(%L, %L)',
  (select id from shipments where job_id = tests.job('Tennis Bracelet 5ct')), tests.uid('ravi@auraforge.example')),
  'a shipment dispatches once', 'already been dispatched');
select fn_complete_stage(tests.job('Tennis Bracelet 5ct'), 'dispatch', tests.uid('ravi@auraforge.example'));
select tests.ok((select current_stage from jobs where id = tests.job('Tennis Bracelet 5ct')) = 'delivered',
                'once dispatched, the dispatch stage closes and the job reaches delivered');

-- Intake: commit a draft, then leave inquiry — the job must enter production.
select fn_commit_job(tests.job('Emerald Choker (draft)'), tests.uid('ravi@auraforge.example'));
select tests.ok((select code from jobs where id = tests.job('Emerald Choker (draft)')) ~ '^DH-[0-9]{4}-01850$',
                'commit mints the next DH code after the demo jobs');
select tests.refused(format('select fn_commit_job(%L, %L)',
  tests.job('Emerald Choker (draft)'), tests.uid('ravi@auraforge.example')),
  'a job commits once', 'already committed');
select fn_complete_stage(tests.job('Emerald Choker (draft)'), 'inquiry', tests.uid('ravi@auraforge.example'));
select tests.ok((select status from jobs where id = tests.job('Emerald Choker (draft)')) = 'in_production',
                'leaving inquiry moves the job to in_production');

-- An empty QC checklist is not a full one.
reset role;
select set_config('request.jwt.claims', '', false);
delete from qc_inspections where job_id = tests.job('Wedding Band Repair');
update job_stages set state = 'completed', blocked_reason = null
 where job_id = tests.job('Wedding Band Repair') and stage in ('setting', 'polishing');
update job_stages set state = 'active' where job_id = tests.job('Wedding Band Repair') and stage = 'qc';
select tests.login('meera@auraforge.example');
select tests.refused(format('select fn_complete_stage(%L, ''qc'', %L)',
                     tests.job('Wedding Band Repair'), tests.uid('meera@auraforge.example')),
                     'QC refuses when no checklist exists', 'checklist');

-- ---------------------------------------------------------------- another org

select tests.login('intruder@other-org.example');
select tests.ok(not exists (select 1 from v_job_list), 'another org sees none of our jobs');
select tests.ok(not exists (select 1 from v_production_board), 'another org sees none of our board');
select tests.ok(not exists (select 1 from v_inventory_available), 'another org sees none of our vault');
select tests.refused(format('select fn_complete_stage(%L, ''cad'', %L)',
                     tests.job('Solitaire Crown v2.FINAL'), tests.uid('intruder@other-org.example')),
                     'another org cannot move our jobs', 'not available');

-- ---------------------------------------------------------------- platform (0014)

reset role;
select set_config('request.jwt.claims', '', false);
insert into auth.users (email) values ('root@dhanaos.example');
insert into platform_admins (user_id, full_name, email)
select id, 'Root', email from auth.users where email = 'root@dhanaos.example';

select tests.login('root@dhanaos.example');
select tests.ok((select count(*) from jobs where org_id = '00000000-0000-0000-0000-000000000001') >= 9,
                'super admin reads every tenant''s jobs');
select tests.ok((select count(*) from v_platform_tenants) >= 2, 'super admin lists every tenant');
select tests.ok(tests.touched('update jobs set title = ''x''') = 0, 'super admin cannot edit jobs');
select tests.refused('insert into customers (org_id, name) values (''00000000-0000-0000-0000-000000000001'', ''X'')',
                     'super admin cannot add customers');
select tests.refused(format('select fn_complete_stage(%L, ''cad'', %L)',
                     tests.job('Solitaire Crown v2.FINAL'), tests.uid('root@dhanaos.example')),
                     'super admin cannot move jobs');
select tests.ok(tests.touched('update orgs set name = ''x''') = 0, 'super admin cannot edit a workspace profile');
select tests.refused('select fn_admin_create_user(''a@b.example'', ''A'', ''password1'', ''internal'', ''{engineer}'', null, null, null, null, ''00000000-0000-0000-0000-000000000001'')',
                     'super admin adds only administrators', 'Platform admins add');
select tests.refused('select fn_platform_set_org_active(''00000000-0000-0000-0000-000000000002'', false)',
                     'suspending needs a reason', 'Say why');
select fn_platform_create_org('Shree Ganesh Jewellers', 'Shree Ganesh Jewellers LLP', '24abcde1234f1z5', 'INR',
                              'Owner@ShreeGanesh.example', 'Mahesh Soni', 'Temp-pass-1');

reset role;
select set_config('request.jwt.claims', '', false);
select tests.ok(exists (select 1 from auth.users where email = 'owner@shreeganesh.example'
                          and encrypted_password = extensions.crypt('Temp-pass-1', encrypted_password)),
                'the new tenant admin can sign in with the temporary password');
select tests.ok(exists (select 1 from auth.identities i join auth.users u on u.id = i.user_id
                         where u.email = 'owner@shreeganesh.example' and i.provider = 'email'),
                'the new login has its email identity');

select tests.login('owner@shreeganesh.example');
select tests.ok((select must_change_password from app_users where id = auth.uid()),
                'a new admin must change the temporary password');
select tests.ok(not exists (select 1 from jobs), 'the new tenant sees none of AuraForge''s jobs');
select tests.ok((select count(*) from v_platform_tenants) = 1, 'a tenant admin lists only their own workspace');
select fn_password_changed();
select tests.ok(not (select must_change_password from app_users where id = auth.uid()),
                'changing the password clears the flag');
select tests.ok(fn_admin_create_user('bench@shreeganesh.example', 'Kiran Bench', 'Temp-pass-2',
                                     'internal', '{bench_operator}') is not null,
                'a tenant admin adds a member');
select tests.refused('select fn_admin_create_user(''x@shreeganesh.example'', ''X'', ''Temp-pass-3'', ''internal'', ''{engineer}'', null, null, null, null, ''00000000-0000-0000-0000-000000000001'')',
                     'a tenant admin cannot add people to another workspace', 'Only an administrator');
select tests.refused(format('select fn_admin_reset_password(%L, ''Temp-pass-9'')', tests.uid('ravi@auraforge.example')),
                     'a tenant admin cannot reset another workspace''s passwords', 'Only an administrator');
select tests.refused('select fn_admin_create_user(''ravi@auraforge.example'', ''Dup'', ''Temp-pass-4'', ''internal'', ''{engineer}'')',
                     'an email cannot be registered twice', 'already exists');
select tests.refused('select fn_admin_create_user(''y@shreeganesh.example'', ''Y'', ''short'', ''internal'', ''{engineer}'')',
                     'temporary passwords need 8 characters', 'at least 8');
select tests.refused(format('select fn_admin_set_member_active(%L, false)', tests.uid('owner@shreeganesh.example')),
                     'an admin cannot deactivate themselves', 'yourself');
select tests.refused(format('select fn_admin_update_member(%L, ''Mahesh Soni'', null, null, ''{engineer}'')', tests.uid('owner@shreeganesh.example')),
                     'an admin cannot drop their own admin role', 'your own admin role');
select tests.ok(tests.touched('update orgs set gstin = ''24ABCDE1234F1Z6''') = 1,
                'a tenant admin edits their workspace profile');
select tests.refused('update orgs set job_seq = 99', 'nobody edits the job-code counter', 'permission denied');
select tests.ok(not exists (select 1 from user_roles where user_id = tests.uid('ravi@auraforge.example')),
                'another workspace cannot read our roles');

select tests.login('ravi@auraforge.example');
select tests.ok(fn_admin_create_user('buyer2@scottsdalediamond.example', 'Second Buyer', 'Temp-pass-5',
                                     'customer', '{}', null, null,
                                     (select id from customers where code = 'SDC')) is not null,
                'an admin adds a customer portal login');
select tests.ok(exists (select 1 from customer_users where user_id = tests.uid('buyer2@scottsdalediamond.example')),
                'an admin sees which customer a portal login belongs to');
select tests.refused('select fn_admin_create_user(''p2@x.example'', ''P'', ''Temp-pass-6'', ''partner'', ''{}'')',
                     'a partner login needs its partner', 'Choose the partner');
select fn_admin_update_member(tests.uid('elena@auraforge.example'), 'Elena Rostova', 'Lead CAD Designer', null,
                              '{cad_designer,engineer}');
select tests.ok((select count(*) from user_roles where user_id = tests.uid('elena@auraforge.example')) = 2,
                'an admin changes a member''s roles');

select tests.login('meera@auraforge.example');
select tests.refused('select fn_admin_create_user(''z@auraforge.example'', ''Z'', ''Temp-pass-7'', ''internal'', ''{engineer}'')',
                     'only admins add members', 'Only an administrator');
select tests.ok(tests.touched('update orgs set gstin = ''X''') = 0, 'a non-admin cannot edit the workspace profile');

select tests.login('ravi@auraforge.example');
select fn_admin_set_member_active(tests.uid('meera@auraforge.example'), false);
select tests.login('meera@auraforge.example');
select tests.ok(not exists (select 1 from jobs), 'a deactivated member sees nothing');
select tests.ok(exists (select 1 from app_users where id = auth.uid() and not is_active),
                'a deactivated member can still read that they are deactivated');
select tests.login('ravi@auraforge.example');
select fn_admin_set_member_active(tests.uid('meera@auraforge.example'), true);

select tests.login('root@dhanaos.example');
select fn_platform_set_org_active('00000000-0000-0000-0000-000000000001', false, 'Unpaid invoice');
select tests.login('ravi@auraforge.example');
select tests.ok(not exists (select 1 from jobs), 'a suspended workspace sees nothing');
select tests.ok(exists (select 1 from orgs where not is_active), 'a suspended workspace can read that it is suspended');
select tests.login('root@dhanaos.example');
select tests.ok((select count(*) from jobs where org_id = '00000000-0000-0000-0000-000000000001') > 0,
                'the platform still reads a suspended workspace');
select fn_platform_set_org_active('00000000-0000-0000-0000-000000000001', true);
select tests.login('ravi@auraforge.example');
select tests.ok(exists (select 1 from jobs), 'reactivation restores access');

reset role;
