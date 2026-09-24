-- DhanaOS 0010 — derived views
-- D-002: the dashboard's 8 operational counters are a VIEW over the 14-stage rail, never a
-- second enum. In the mockup they were hardcoded numbers that summed to exactly 55 = "Total
-- Active" — strong evidence the 8 are the intended in-production subset of the 14.

-- ---------------------------------------------------------------- dashboard counters

create or replace view v_stage_counters as
select
  j.org_id,
  s.stage,
  count(*)::int as job_count
from job_stages s
join jobs j on j.id = s.job_id
where s.state = 'active'
  and j.status = 'in_production'
  and s.stage in ('cad','approval','wax','casting','assembly','setting','qc','cert')
group by j.org_id, s.stage;

comment on view v_stage_counters is
  'D-002. The 8 dashboard counters: CAD Wait, Approval Wait, In Wax, At Casting, Assembly, '
  'Setting, In QC, Certification. Their sum is Total Active by construction.';

-- ---------------------------------------------------------------- job list

create or replace view v_job_list as
select
  j.id,
  j.org_id,
  coalesce(j.code, j.draft_code)          as display_code,
  j.code,
  j.draft_code,
  j.title,
  j.status,
  j.priority,
  j.current_stage,
  j.stage_entered_at,
  j.quantity,
  j.requested_delivery,
  j.promised_delivery,
  j.currency,
  c.id                                    as customer_id,
  c.name                                  as customer_name,
  -- dwell time, which the mockup rendered as "1d in stage"
  case when j.stage_entered_at is null then null
       else now() - j.stage_entered_at end as time_in_stage,
  -- "3 At Risk" / "DUE TODAY" / "DUE TMRW"
  (j.requested_delivery is not null
     and j.requested_delivery <= current_date + 1
     and j.status not in ('completed','cancelled','archived'))    as due_soon,
  (j.requested_delivery is not null
     and j.requested_delivery < current_date
     and j.status not in ('completed','cancelled','archived'))    as overdue,
  st.assigned_to,
  u.full_name                             as assignee_name,
  st.assigned_partner,
  p.name                                  as partner_name,
  q.grand_total                           as quote_total,
  (select count(*) from job_exceptions e
    where e.job_id = j.id and e.resolved_at is null)::int as open_exceptions
from jobs j
left join customers c on c.id = j.customer_id
left join job_stages st on st.job_id = j.id and st.state = 'active'
left join app_users u on u.id = st.assigned_to
left join partners p on p.id = st.assigned_partner
left join lateral (
  select grand_total from quotes
   where job_id = j.id and status = 'approved'
   order by version desc limit 1
) q on true;

-- ---------------------------------------------------------------- partner queue

-- Replaces caster_dashboard's decorative "Assigned to Me" chip, which had nothing behind it.
create or replace view v_partner_queue as
select
  s.assigned_partner                      as partner_id,
  j.id                                    as job_id,
  coalesce(j.code, j.draft_code)          as display_code,
  j.title,
  j.priority,
  s.stage,
  s.state,
  s.entered_at,
  s.expected_at,
  (s.expected_at is not null and s.expected_at < now()) as is_late,
  cp.alloy,
  cp.flask_temp_c,
  cp.metal_temp_c,
  cp.photo_id,
  -- D-011 RULE 1: the partner cannot complete without this
  (cp.photo_id is not null)               as evidence_ready
from job_stages s
join jobs j on j.id = s.job_id
left join casting_params cp on cp.job_id = j.id
where s.assigned_partner is not null
  and s.state in ('active','blocked');

-- ---------------------------------------------------------------- digital thread

-- job_detail's core mechanic: system events and human posts in ONE chronological stream.
create or replace view v_digital_thread as
select
  job_id,
  id,
  'event'::text                           as entry_type,
  kind::text                              as sub_kind,
  actor_id,
  coalesce(actor_label, 'System')         as actor_label,
  stage,
  summary                                 as body,
  detail,
  false                                   as is_internal,
  created_at
from activity_events
union all
select
  job_id,
  id,
  'post'::text,
  null,
  author_id,
  author_label,
  stage,
  body,
  null,
  is_internal,
  created_at
from thread_posts;

-- ---------------------------------------------------------------- inventory availability

create or replace view v_inventory_available as
select
  i.*,
  (i.qty_on_hand - i.qty_allocated)       as qty_available,
  (i.reorder_level is not null
     and i.qty_on_hand <= i.reorder_level) as needs_reorder
from inventory_items i
where i.is_active;

-- ---------------------------------------------------------------- production board

-- The mockup's board had 3 of 8 columns. This exposes all eight.
create or replace view v_production_board as
select
  j.org_id,
  s.stage                                 as column_stage,
  j.id                                    as job_id,
  coalesce(j.code, j.draft_code)          as display_code,
  j.title,
  j.priority,
  c.name                                  as customer_name,
  j.requested_delivery,
  s.entered_at,
  extract(day from now() - s.entered_at)::int as days_in_stage,
  u.full_name                             as assignee_name,
  p.name                                  as partner_name
from job_stages s
join jobs j on j.id = s.job_id
left join customers c on c.id = j.customer_id
left join app_users u on u.id = s.assigned_to
left join partners p on p.id = s.assigned_partner
where s.state in ('active','blocked')
  and s.stage in ('cad','approval','wax','casting','assembly','setting','qc','cert');
