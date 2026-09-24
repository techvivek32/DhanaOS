-- DhanaOS 0008 — functions and triggers
-- The four business rules (D-011) live here, not in Dart. A client rewrite cannot break them.

-- ---------------------------------------------------------------- D-001 job code minting

create or replace function fn_mint_job_code(p_org uuid)
returns text
language plpgsql
security definer
as $$
declare
  v_year int := extract(year from now())::int;
  v_seq  int;
begin
  update orgs
     set job_seq      = case when job_seq_year = v_year then job_seq + 1 else 1 end,
         job_seq_year = v_year
   where id = p_org
   returning job_seq into v_seq;

  if v_seq is null then
    raise exception 'org % not found', p_org;
  end if;

  return format('DH-%s-%s', v_year, lpad(v_seq::text, 5, '0'));
end;
$$;

comment on function fn_mint_job_code is
  'D-001. Year-scoped sequence. The UPDATE ... RETURNING takes a row lock, so concurrent '
  'commits cannot collide.';

-- ---------------------------------------------------------------- D-002 stage rail

create or replace function fn_seed_job_stages(p_job uuid)
returns void
language plpgsql
as $$
declare
  v_stage lifecycle_stage;
  v_seq   int := 0;
begin
  foreach v_stage in array enum_range(null::lifecycle_stage)
  loop
    v_seq := v_seq + 1;
    insert into job_stages (job_id, stage, seq, state)
    values (p_job, v_stage, v_seq, case when v_seq = 1 then 'active' else 'pending' end)
    on conflict (job_id, stage) do nothing;
  end loop;
end;
$$;

comment on function fn_seed_job_stages is
  'D-002. Inserts all 14 rail rows at commit so the timeline renders complete from day one, '
  'with future stages in pending. enum_range preserves declaration order.';

-- ---------------------------------------------------------------- D-005 stage cache + audit

create or replace function trg_job_stage_cache()
returns trigger
language plpgsql
as $$
begin
  if new.state = 'active' and (tg_op = 'INSERT' or old.state is distinct from 'active') then
    update jobs
       set current_stage    = new.stage,
           stage_entered_at = coalesce(new.entered_at, now()),
           updated_at       = now()
     where id = new.job_id;

    -- D-005: every transition writes an immutable event. The mockups specified this
    -- ("System updated status automatically") and never implemented it.
    insert into activity_events (job_id, kind, actor_label, stage, summary, detail)
    values (new.job_id, 'stage_changed', 'System', new.stage,
            format('Stage Changed: %s', initcap(replace(new.stage::text, '_', ' '))),
            'System updated status automatically.');
  end if;

  if new.state = 'blocked' and old.state is distinct from 'blocked' then
    insert into activity_events (job_id, kind, actor_label, stage, summary, detail)
    values (new.job_id, 'exception_raised', 'System', new.stage,
            format('Blocked at %s', initcap(replace(new.stage::text, '_', ' '))),
            new.blocked_reason);
  end if;

  return new;
end;
$$;

create trigger job_stage_cache
after insert or update of state on job_stages
for each row execute function trg_job_stage_cache();

-- ---------------------------------------------------------------- D-011 stage completion

-- Rule 1: casting cannot complete without a photo.
-- Rule 3: QC cannot authorize below a full checklist.
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
as $$
declare
  v_next    lifecycle_stage;
  v_seq     int;
  v_photo   uuid;
  v_open    int;
  v_cert_req boolean;
begin
  select seq into v_seq from job_stages where job_id = p_job and stage = p_stage;
  if v_seq is null then
    raise exception 'stage % not on job %', p_stage, p_job;
  end if;

  -- D-011 RULE 1 — casting evidence. Ported verbatim from caster_dashboard, which shipped
  -- "Mark Complete" disabled behind a mandatory accept="image/*" upload.
  if p_stage = 'casting' then
    select photo_id into v_photo from casting_params where job_id = p_job;
    if v_photo is null then
      raise exception 'A casting photo is required before marking this stage complete'
        using errcode = 'check_violation';
    end if;
  end if;

  -- D-011 RULE 3 — QC completeness.
  if p_stage = 'qc' then
    select count(*) into v_open
      from qc_checklist_items i
      join qc_inspections q on q.id = i.inspection_id
     where q.job_id = p_job
       and q.status <> 'failed'
       and coalesce(i.passed, false) = false;
    if v_open > 0 then
      raise exception 'QC cannot be authorized with % unchecked item(s)', v_open
        using errcode = 'check_violation';
    end if;
  end if;

  update job_stages
     set state        = 'completed',
         completed_at = now(),
         completed_by = p_user,
         resource_id  = coalesce(p_resource, resource_id),
         notes        = coalesce(p_notes, notes)
   where job_id = p_job and stage = p_stage;

  -- Advance. Certification is skipped when it was never required — a conditional the mockups
  -- declared and never wired.
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
       where job_id = p_job and seq > v_seq + 1 and state = 'pending'
       order by seq limit 1;
    end if;
  end if;

  if v_next is not null then
    update job_stages
       set state = 'active', entered_at = now()
     where job_id = p_job and stage = v_next;
  else
    update jobs set status = 'completed', closed_at = now() where id = p_job;
  end if;
end;
$$;

-- ---------------------------------------------------------------- D-011 dispatch gate

-- The mockup's security gate was cosmetic: its JS toggled opacity classes and never set
-- .disabled, so dispatch fired with the tamper-seal protocol incomplete.
create or replace function fn_dispatch_shipment(p_shipment uuid, p_user uuid)
returns void
language plpgsql
security definer
as $$
declare
  v_open int;
  v_job  uuid;
begin
  select count(*) into v_open
    from shipment_checks where shipment_id = p_shipment and passed = false;

  if v_open > 0 then
    raise exception 'Complete the security protocol first — % check(s) outstanding', v_open
      using errcode = 'check_violation';
  end if;

  update shipments
     set status = 'dispatched', dispatched_at = now()
   where id = p_shipment
   returning job_id into v_job;

  insert into activity_events (job_id, kind, actor_id, stage, summary)
  values (v_job, 'system', p_user, 'dispatch', 'Package dispatched');
end;
$$;

-- ---------------------------------------------------------------- job commit

create or replace function fn_commit_job(p_job uuid, p_user uuid)
returns text
language plpgsql
security definer
as $$
declare
  v_org  uuid;
  v_code text;
  v_open int;
begin
  select org_id into v_org from jobs where id = p_job;
  if v_org is null then raise exception 'job % not found', p_job; end if;

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

  perform fn_seed_job_stages(p_job);

  insert into activity_events (job_id, kind, actor_id, summary, detail)
  values (p_job, 'job_created', p_user, format('Job order %s created', v_code),
          'Routing specs to CAD engineering and preliminary production queue.');

  return v_code;
end;
$$;

-- ---------------------------------------------------------------- quote totals

create or replace function fn_recalc_quote(p_quote uuid)
returns void
language plpgsql
as $$
declare
  v_sub bigint;
  v_tax bigint;
begin
  select coalesce(sum(amount), 0),
         coalesce(sum(round(amount * coalesce(tax_rate_pct, 0) / 100.0)), 0)
    into v_sub, v_tax
    from cost_lines
   where quote_id = p_quote and is_client_owned = false;

  update quotes
     set subtotal    = v_sub,
         tax_total   = v_tax,
         grand_total = v_sub + v_tax
   where id = p_quote;
end;
$$;

create or replace function trg_cost_line_recalc()
returns trigger
language plpgsql
as $$
begin
  perform fn_recalc_quote(coalesce(new.quote_id, old.quote_id));
  return coalesce(new, old);
end;
$$;

create trigger cost_line_recalc
after insert or update or delete on cost_lines
for each row execute function trg_cost_line_recalc();

-- ---------------------------------------------------------------- inventory balance

create or replace function trg_stock_balance()
returns trigger
language plpgsql
as $$
begin
  update inventory_items
     set qty_on_hand = qty_on_hand + new.qty
   where id = new.item_id;

  if (select qty_on_hand from inventory_items where id = new.item_id) < 0 then
    raise exception 'Stock would go negative for item %', new.item_id
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

create trigger stock_balance
after insert on stock_transactions
for each row execute function trg_stock_balance();

-- ---------------------------------------------------------------- updated_at

create or replace function trg_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;

create trigger touch_jobs           before update on jobs           for each row execute function trg_touch();
create trigger touch_product_specs  before update on product_specs  for each row execute function trg_touch();
create trigger touch_metal_specs    before update on metal_specs    for each row execute function trg_touch();
create trigger touch_delivery       before update on delivery_schedules for each row execute function trg_touch();
create trigger touch_acceptance     before update on acceptance_criteria for each row execute function trg_touch();
