-- DhanaOS 0013 — dispatch cannot be closed around its own gate
-- The job detail screen offers "Complete <stage> and advance" for every active stage. For
-- dispatch that called fn_complete_stage straight past fn_dispatch_shipment's security-protocol
-- refusal: the D-011 gate held the Shipping screen's button shut and left this one open.
-- Unchanged from 0011 apart from the dispatch block.

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

  -- D-011 — dispatch leaves through the security protocol. fn_dispatch_shipment refuses while a
  -- tamper-seal check is open; closing the stage directly would walk around that refusal.
  if p_stage = 'dispatch' and not exists (
       select 1 from shipments
        where job_id = p_job and leg = 'final_dispatch'
          and status in ('dispatched', 'in_transit', 'delivered')) then
    raise exception 'Dispatch closes once the package has left through the security protocol — dispatch it from Shipping first'
      using errcode = 'check_violation';
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

grant execute on function fn_complete_stage(uuid, lifecycle_stage, uuid, uuid, text) to authenticated;
