-- DhanaOS 0011 — hardening
-- 0008 and 0009 left D-008 and D-011 bypassable from the anon key that ships inside the APK.
-- Each section names the hole it closes. supabase/tests/test_rls.sql proves every one of them.

-- ---------------------------------------------------------------- 1. views run as the caller

-- A view runs as its owner unless security_invoker is set, and the owner owns every table, so
-- RLS never applied to any of these: v_job_list, v_digital_thread and v_partner_queue were
-- readable across orgs and principals — by the anon key, without signing in.
alter view v_stage_counters      set (security_invoker = true);
alter view v_job_list            set (security_invoker = true);
alter view v_partner_queue       set (security_invoker = true);
alter view v_digital_thread      set (security_invoker = true);
alter view v_inventory_available set (security_invoker = true);
alter view v_production_board    set (security_invoker = true);

-- ---------------------------------------------------------------- 2. anon reads nothing

-- Every screen runs signed in. Supabase's default grants hand anon every table, view and
-- function in public; RLS then decided, and RLS was not deciding for the views or the
-- security-definer functions.
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on all functions in schema public from anon, public;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from anon, public;

-- Internal plumbing. fn_commit_job calls both as the definer; nobody calls them directly.
revoke execute on function fn_mint_job_code(uuid)   from authenticated;
revoke execute on function fn_seed_job_stages(uuid) from authenticated;

-- Security-definer functions resolve names against a fixed path, never the caller's.
alter function auth_org()                  set search_path = public, pg_temp;
alter function auth_principal()            set search_path = public, pg_temp;
alter function auth_has_role(user_role)    set search_path = public, pg_temp;
alter function auth_partner()              set search_path = public, pg_temp;
alter function auth_customer()             set search_path = public, pg_temp;
alter function auth_can_see_job(uuid)      set search_path = public, pg_temp;
alter function fn_mint_job_code(uuid)      set search_path = public, pg_temp;

-- ---------------------------------------------------------------- 3. RPCs act as the session

-- The three RPCs were security definer, trusted a caller-supplied p_user, and never asked
-- whether the caller could see the job. Anyone holding the anon key could complete any stage of
-- any org's job, dispatch its shipment, and sign the audit trail as someone else.
--
-- p_user stays in each signature for the clients already built against it, and must now name
-- the signed-in user. The stage functions raise dhanaos.stage_fn so the guard in section 4 can
-- tell a sanctioned transition from a direct UPDATE.

create or replace function fn_complete_stage(
  p_job       uuid,
  p_stage     lifecycle_stage,
  p_user      uuid,
  p_resource  uuid default null,
  p_notes     text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid      uuid := auth.uid();
  v_label    text := initcap(replace(p_stage::text, '_', ' '));
  v_state    stage_state;
  v_partner  uuid;
  v_next     lifecycle_stage;
  v_seq      int;
  v_photo    uuid;
  v_items    int;
  v_open     int;
  v_cert_req boolean;
begin
  if v_uid is null or p_user is distinct from v_uid then
    raise exception 'You can only complete a stage as yourself — sign in again and retry'
      using errcode = 'insufficient_privilege';
  end if;

  if not auth_can_see_job(p_job) then
    raise exception 'This job is not available to you'
      using errcode = 'insufficient_privilege';
  end if;

  select seq, state, assigned_partner into v_seq, v_state, v_partner
    from job_stages where job_id = p_job and stage = p_stage
    for update;
  if v_seq is null then
    raise exception 'stage % not on job %', p_stage, p_job;
  end if;

  -- D-008: the workshop completes any stage; a partner only the stage assigned to it; a
  -- customer never — their sign-off is an approval event, not a stage completion.
  case auth_principal()
    when 'internal' then null;
    when 'partner' then
      if v_partner is distinct from auth_partner() then
        raise exception '% is not assigned to you', v_label
          using errcode = 'insufficient_privilege';
      end if;
    else
      raise exception 'Only the workshop or the assigned partner can complete a stage'
        using errcode = 'insufficient_privilege';
  end case;

  if v_state = 'blocked' then
    raise exception '% is blocked — resolve the exception and resume it before completing', v_label
      using errcode = 'check_violation';
  elsif v_state <> 'active' then
    raise exception '% is not the active stage, so it cannot be completed yet', v_label
      using errcode = 'check_violation';
  end if;

  -- D-011 RULE 1 — casting evidence.
  if p_stage = 'casting' then
    select photo_id into v_photo from casting_params where job_id = p_job;
    if v_photo is null then
      raise exception 'A casting photo is required before marking this stage complete'
        using errcode = 'check_violation';
    end if;
  end if;

  -- D-011 RULE 3 — QC completeness. An empty checklist is not a full one.
  if p_stage = 'qc' then
    select count(*), count(*) filter (where coalesce(i.passed, false) = false)
      into v_items, v_open
      from qc_checklist_items i
      join qc_inspections q on q.id = i.inspection_id
     where q.job_id = p_job
       and q.status <> 'failed';
    if v_items = 0 then
      raise exception 'QC cannot be authorized before the inspection checklist is started'
        using errcode = 'check_violation';
    end if;
    if v_open > 0 then
      raise exception 'QC cannot be authorized with % unchecked item(s)', v_open
        using errcode = 'check_violation';
    end if;
  end if;

  perform set_config('dhanaos.stage_fn', 'on', true);

  update job_stages
     set state        = 'completed',
         completed_at = now(),
         completed_by = v_uid,
         resource_id  = coalesce(p_resource, resource_id),
         notes        = coalesce(p_notes, notes)
   where job_id = p_job and stage = p_stage;

  select stage into v_next
    from job_stages
   where job_id = p_job and seq > v_seq and state = 'pending'
   order by seq
   limit 1;

  if v_next = 'cert' then
    select required into v_cert_req from certificates where job_id = p_job limit 1;
    if coalesce(v_cert_req, true) = false then
      update job_stages set state = 'skipped' where job_id = p_job and stage = 'cert';
      select stage into v_next
        from job_stages
       where job_id = p_job and seq > v_seq and state = 'pending'
       order by seq limit 1;
    end if;
  end if;

  if v_next is not null then
    update job_stages
       set state = 'active', entered_at = now()
     where job_id = p_job and stage = v_next;
    -- Leaving the inquiry row means the workshop has started. Nothing else moved a committed
    -- job to in_production, so the dashboard's eight counters — which read only in_production
    -- (D-002) — stayed at zero forever.
    update jobs set status = 'in_production'
     where id = p_job and status = 'approved_ready';
  else
    update jobs set status = 'completed', closed_at = now() where id = p_job;
  end if;
end;
$$;

create or replace function fn_dispatch_shipment(p_shipment uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_open   int;
  v_job    uuid;
  v_status shipment_status;
begin
  if v_uid is null or p_user is distinct from v_uid then
    raise exception 'You can only dispatch as yourself — sign in again and retry'
      using errcode = 'insufficient_privilege';
  end if;

  select job_id, status into v_job, v_status from shipments where id = p_shipment for update;
  if v_job is null or auth_principal() is distinct from 'internal' or not auth_can_see_job(v_job) then
    raise exception 'This shipment is not available to you'
      using errcode = 'insufficient_privilege';
  end if;

  if v_status <> 'draft' then
    raise exception 'This shipment has already been dispatched'
      using errcode = 'check_violation';
  end if;

  select count(*) into v_open
    from shipment_checks where shipment_id = p_shipment and passed = false;
  if v_open > 0 then
    raise exception 'Complete the security protocol first — % check(s) outstanding', v_open
      using errcode = 'check_violation';
  end if;

  update shipments
     set status = 'dispatched', dispatched_at = now()
   where id = p_shipment;

  insert into activity_events (job_id, kind, actor_id, stage, summary)
  values (v_job, 'system', v_uid, 'dispatch', 'Package dispatched');
end;
$$;

-- The CASE in 0008 yields text, which has no assignment cast to stage_state, so seeding the rail
-- raised on every call — and with it fn_commit_job. No job could ever leave draft.
create or replace function fn_seed_job_stages(p_job uuid)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_stage lifecycle_stage;
  v_seq   int := 0;
begin
  foreach v_stage in array enum_range(null::lifecycle_stage)
  loop
    v_seq := v_seq + 1;
    insert into job_stages (job_id, stage, seq, state)
    values (p_job, v_stage, v_seq,
            case when v_seq = 1 then 'active'::stage_state else 'pending'::stage_state end)
    on conflict (job_id, stage) do nothing;
  end loop;
end;
$$;

create or replace function fn_commit_job(p_job uuid, p_user uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid      uuid := auth.uid();
  v_org      uuid;
  v_existing text;
  v_code     text;
  v_open     int;
begin
  if v_uid is null or p_user is distinct from v_uid then
    raise exception 'You can only commit a job as yourself — sign in again and retry'
      using errcode = 'insufficient_privilege';
  end if;

  select org_id, code into v_org, v_existing from jobs where id = p_job for update;
  if v_org is null or auth_principal() is distinct from 'internal' or v_org <> auth_org() then
    raise exception 'job % not found', p_job;
  end if;

  -- Committing twice minted a second DH code and reset the status.
  if v_existing is not null then
    raise exception 'This job is already committed as %', v_existing
      using errcode = 'check_violation';
  end if;

  select count(*) into v_open
    from approval_gates where job_id = p_job and state <> 'approved';
  if v_open > 0 then
    raise exception 'All approval gates must clear first — % pending', v_open
      using errcode = 'check_violation';
  end if;

  v_code := fn_mint_job_code(v_org);

  update jobs
     set code         = v_code,
         draft_code   = null,
         status       = 'approved_ready',
         committed_at = now(),
         updated_at   = now()
   where id = p_job;

  perform set_config('dhanaos.stage_fn', 'on', true);
  perform fn_seed_job_stages(p_job);

  insert into activity_events (job_id, kind, actor_id, summary, detail)
  values (p_job, 'job_created', v_uid, format('Job order %s created', v_code),
          'Routing specs to CAD engineering and preliminary production queue.');

  return v_code;
end;
$$;

-- Only signed-in users reach the RPCs (section 2 took them from anon).
grant execute on function fn_complete_stage(uuid, lifecycle_stage, uuid, uuid, text) to authenticated;
grant execute on function fn_dispatch_shipment(uuid, uuid) to authenticated;
grant execute on function fn_commit_job(uuid, uuid)        to authenticated;

-- The stage cache writes jobs and activity_events on behalf of whoever moved the stage. As
-- invoker, a partner's UPDATE silently failed the jobs write (RLS) and left the cache stale.
alter function trg_job_stage_cache() security definer;
alter function trg_job_stage_cache() set search_path = public, pg_temp;

-- ---------------------------------------------------------------- 4. stages move one way

-- 0009 granted UPDATE on job_stages.state, so a partner could mark casting completed without a
-- photo, and anyone internal could authorize QC over an empty checklist, just by writing the
-- column. It also left out the assignment columns, so the assign sheet could never save.
grant update (assigned_to, assigned_partner, expected_at) on job_stages to authenticated;

create or replace function trg_job_stage_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- fn_complete_stage and fn_commit_job raise this flag for their own transaction. A null
  -- uid is the service role or the SQL editor.
  if current_setting('dhanaos.stage_fn', true) = 'on' or auth.uid() is null then
    return new;
  end if;

  if new.state is distinct from old.state
     and not (old.state = 'active'  and new.state = 'blocked')
     and not (old.state = 'blocked' and new.state = 'active') then
    raise exception 'A stage only moves forward through Complete Stage (% to % refused)',
      old.state, new.state
      using errcode = 'check_violation';
  end if;

  if new.completed_at is distinct from old.completed_at
     or new.completed_by is distinct from old.completed_by then
    raise exception 'Completion is recorded by Complete Stage, not edited directly'
      using errcode = 'check_violation';
  end if;

  if auth_principal() is distinct from 'internal' and (
       new.assigned_to      is distinct from old.assigned_to
    or new.assigned_partner is distinct from old.assigned_partner
    or new.expected_at      is distinct from old.expected_at) then
    raise exception 'Only the workshop can reassign or reschedule a stage'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create trigger job_stage_guard
before update on job_stages
for each row execute function trg_job_stage_guard();

-- ---------------------------------------------------------------- 5. writes follow the principal

-- Every job-scoped _write policy checked only auth_can_see_job on INSERT, so a partner or a
-- customer could add rows to quotes, stones, certificates, shipments… for any job they could
-- see. Writes are internal; the two things a partner genuinely writes are granted back below.
do $$
declare
  t text;
  job_tables text[] := array[
    'requirements','job_references','product_specs','metal_specs','stones','melee_parcels',
    'delivery_schedules','acceptance_criteria','quotes','approval_gates',
    'cad_revisions','casting_params','job_exceptions','stage_measurements',
    'qc_inspections','certificates','shipments','goods_in_receipts','stock_allocations'
  ];
begin
  foreach t in array job_tables loop
    execute format('drop policy %I on %I', t || '_write', t);
    execute format(
      'create policy %I on %I for all
         using (auth_principal() = ''internal'' and auth_can_see_job(job_id))
         with check (auth_principal() = ''internal'' and auth_can_see_job(job_id))',
      t || '_write', t);
  end loop;
end $$;

-- D-011 rule 1: the caster records its own parameters and the evidence photo.
create policy casting_params_partner_insert on casting_params for insert
  with check (auth_principal() = 'partner' and exists (
    select 1 from job_stages s
     where s.job_id = casting_params.job_id and s.stage = 'casting'
       and s.assigned_partner = auth_partner()));

create policy casting_params_partner_update on casting_params for update
  using (auth_principal() = 'partner' and exists (
    select 1 from job_stages s
     where s.job_id = casting_params.job_id and s.stage = 'casting'
       and s.assigned_partner = auth_partner()))
  with check (auth_principal() = 'partner' and exists (
    select 1 from job_stages s
     where s.job_id = casting_params.job_id and s.stage = 'casting'
       and s.assigned_partner = auth_partner()));

-- "Report Issue" — a partner raises an exception on a job it is working.
create policy job_exceptions_partner_insert on job_exceptions for insert
  with check (auth_principal() = 'partner' and auth_can_see_job(job_id));

-- Quotes: the workshop sees all of its own; a customer sees what was sent to them; a partner
-- sees none. The generic select let a vendor read the job's price, and made the customer's
-- "not draft" filter moot because permissive policies OR together.
drop policy quotes_select on quotes;
drop policy quotes_customer_read on quotes;
create policy quotes_select on quotes for select
  using (auth_can_see_job(job_id) and (
    auth_principal() = 'internal'
    or (auth_principal() = 'customer' and status <> 'draft')));

-- Grandchildren read through their parent's RLS and write only as the workshop. As `for all`
-- over visibility alone, a customer could rewrite their own quote's cost lines — and the
-- recalc trigger would lower their price — and a partner could tick QC items or pass the
-- dispatch security checks.
drop policy cost_lines_all  on cost_lines;
drop policy cad_ann_all     on cad_annotations;
drop policy cad_rev_all     on cad_reviews;
drop policy qc_items_all    on qc_checklist_items;
drop policy ship_checks_all on shipment_checks;

create policy cost_lines_select on cost_lines for select
  using (exists (select 1 from quotes q where q.id = quote_id));
create policy cost_lines_write on cost_lines for all
  using (auth_principal() = 'internal'
         and exists (select 1 from quotes q where q.id = quote_id))
  with check (auth_principal() = 'internal'
         and exists (select 1 from quotes q where q.id = quote_id));

create policy cad_ann_select on cad_annotations for select
  using (exists (select 1 from cad_revisions r where r.id = revision_id));
create policy cad_ann_write on cad_annotations for all
  using (auth_principal() = 'internal'
         and exists (select 1 from cad_revisions r where r.id = revision_id))
  with check (auth_principal() = 'internal'
         and exists (select 1 from cad_revisions r where r.id = revision_id));

create policy cad_rev_select on cad_reviews for select
  using (exists (select 1 from cad_revisions r where r.id = revision_id));
create policy cad_rev_write on cad_reviews for all
  using (auth_principal() = 'internal'
         and exists (select 1 from cad_revisions r where r.id = revision_id))
  with check (auth_principal() = 'internal'
         and exists (select 1 from cad_revisions r where r.id = revision_id));

create policy qc_items_select on qc_checklist_items for select
  using (exists (select 1 from qc_inspections q where q.id = inspection_id));
create policy qc_items_write on qc_checklist_items for all
  using (auth_principal() = 'internal'
         and exists (select 1 from qc_inspections q where q.id = inspection_id))
  with check (auth_principal() = 'internal'
         and exists (select 1 from qc_inspections q where q.id = inspection_id));

create policy ship_checks_select on shipment_checks for select
  using (exists (select 1 from shipments s where s.id = shipment_id));
create policy ship_checks_write on shipment_checks for all
  using (auth_principal() = 'internal'
         and exists (select 1 from shipments s where s.id = shipment_id))
  with check (auth_principal() = 'internal'
         and exists (select 1 from shipments s where s.id = shipment_id));

-- ---------------------------------------------------------------- 6. the audit trail signs itself

-- D-005: "who approved what, when" must be reconstructible. Anyone who could see a job could
-- insert an event under any actor_id. System rows come from definer functions, which bypass
-- RLS; a person can only write as themselves.
drop policy events_insert on activity_events;
create policy events_insert on activity_events for insert
  with check (auth_can_see_job(job_id) and actor_id = auth.uid());

drop policy thread_insert on thread_posts;
create policy thread_insert on thread_posts for insert
  with check (auth_can_see_job(job_id) and author_id = auth.uid()
              and (not is_internal or auth_principal() = 'internal'));

drop policy thread_edit_own on thread_posts;
create policy thread_edit_own on thread_posts for update
  using (author_id = auth.uid())
  with check (author_id = auth.uid());

-- ---------------------------------------------------------------- 7. storage

-- The app uploads to three buckets (core/config.dart) and nothing created them, so every upload
-- failed on a fresh project — including the casting photo that D-011 rule 1 demands, which made
-- casting impossible to complete. Object keys are <org>/<job id | _org>/<kind>/<uuid>-<file>
-- (data/supabase/storage.dart).
insert into storage.buckets (id, name, public)
values ('job-files', 'job-files', false),
       ('vault',     'vault',     false),
       ('brand',     'brand',     false)
on conflict (id) do nothing;

create or replace function storage_can_access(p_bucket text, p_name text)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select case
    when p_bucket = 'brand' then auth.uid() is not null
    when (storage.foldername(p_name))[1] is distinct from auth_org()::text then false
    -- vault: inventory photography and QC evidence. Internal only.
    when p_bucket = 'vault' then auth_principal() = 'internal'
    when p_bucket = 'job-files' then
      case
        when (storage.foldername(p_name))[2] = '_org' then auth_principal() = 'internal'
        when (storage.foldername(p_name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          then auth_can_see_job(((storage.foldername(p_name))[2])::uuid)
        else false
      end
    else false
  end
$$;

grant execute on function storage_can_access(text, text) to authenticated;

create policy dhanaos_read on storage.objects for select to authenticated
  using (storage_can_access(bucket_id, name));

create policy dhanaos_upload on storage.objects for insert to authenticated
  with check (storage_can_access(bucket_id, name)
              and (bucket_id <> 'brand' or auth_has_role('admin')));

-- The uploader may take back an object whose attachments row was refused; the workshop may
-- remove anything it can see.
create policy dhanaos_remove on storage.objects for delete to authenticated
  using (storage_can_access(bucket_id, name)
         and (owner = auth.uid() or auth_principal() = 'internal'));

-- ---------------------------------------------------------------- 8. backfill

-- Jobs that already left the inquiry row before this migration.
update jobs j
   set status = 'in_production'
 where j.status = 'approved_ready'
   and exists (select 1 from job_stages s
                where s.job_id = j.id and s.seq > 1 and s.state in ('active','blocked','completed'));
