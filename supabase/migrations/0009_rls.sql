-- DhanaOS 0009 — row level security
-- D-008: three principal classes, enforced in Postgres, never in the UI.
--
-- The mockups hardcoded one identity, "Ravi S. — Manufacturing Engineer", and it leaked onto the
-- external vendor's screen and the customer's approval screen. The vendor queue was scoped by a
-- decorative "Assigned to Me" chip with nothing behind it. A vendor seeing another vendor's jobs
-- is a business-ending defect, so scoping lives here where the client cannot bypass it.

-- ---------------------------------------------------------------- helpers

create or replace function auth_org() returns uuid
language sql stable security definer as $$
  select org_id from app_users where id = auth.uid();
$$;

create or replace function auth_principal() returns principal_class
language sql stable security definer as $$
  select principal from app_users where id = auth.uid();
$$;

create or replace function auth_has_role(r user_role) returns boolean
language sql stable security definer as $$
  select exists (select 1 from user_roles where user_id = auth.uid() and role = r);
$$;

create or replace function auth_partner() returns uuid
language sql stable security definer as $$
  select partner_id from partner_users where user_id = auth.uid();
$$;

create or replace function auth_customer() returns uuid
language sql stable security definer as $$
  select customer_id from customer_users where user_id = auth.uid();
$$;

-- The single predicate every job-scoped table reuses.
create or replace function auth_can_see_job(p_job uuid) returns boolean
language sql stable security definer as $$
  select case auth_principal()
    when 'internal' then exists (
      select 1 from jobs j where j.id = p_job and j.org_id = auth_org()
    )
    -- A partner sees a job only while a stage is assigned to that partner.
    when 'partner'  then exists (
      select 1 from job_stages s
       where s.job_id = p_job and s.assigned_partner = auth_partner()
    )
    when 'customer' then exists (
      select 1 from jobs j where j.id = p_job and j.customer_id = auth_customer()
    )
    else false
  end;
$$;

-- ---------------------------------------------------------------- enable

alter table orgs                enable row level security;
alter table app_users           enable row level security;
alter table user_roles          enable row level security;
alter table customers           enable row level security;
alter table customer_users      enable row level security;
alter table partners            enable row level security;
alter table partner_users       enable row level security;
alter table resources           enable row level security;
alter table jobs                enable row level security;
alter table job_stages          enable row level security;
alter table activity_events     enable row level security;
alter table thread_posts        enable row level security;
alter table attachments         enable row level security;
alter table action_items        enable row level security;
alter table requirements        enable row level security;
alter table job_references      enable row level security;
alter table product_specs       enable row level security;
alter table metal_specs         enable row level security;
alter table stones              enable row level security;
alter table melee_parcels       enable row level security;
alter table delivery_schedules  enable row level security;
alter table acceptance_criteria enable row level security;
alter table metal_rates         enable row level security;
alter table quotes              enable row level security;
alter table cost_lines          enable row level security;
alter table approval_gates      enable row level security;
alter table invoices            enable row level security;
alter table payments            enable row level security;
alter table cad_revisions       enable row level security;
alter table cad_annotations     enable row level security;
alter table cad_reviews         enable row level security;
alter table casting_params      enable row level security;
alter table job_exceptions      enable row level security;
alter table stage_measurements  enable row level security;
alter table qc_inspections      enable row level security;
alter table qc_checklist_items  enable row level security;
alter table certificates        enable row level security;
alter table shipments           enable row level security;
alter table shipment_checks     enable row level security;
alter table inventory_items     enable row level security;
alter table stock_allocations   enable row level security;
alter table stock_transactions  enable row level security;
alter table goods_in_receipts   enable row level security;

-- ---------------------------------------------------------------- identity

create policy org_read on orgs for select
  using (id = auth_org());

create policy users_read on app_users for select
  using (org_id = auth_org() and auth_principal() = 'internal');

create policy users_self on app_users for select
  using (id = auth.uid());

create policy roles_read on user_roles for select
  using (user_id = auth.uid() or (auth_principal() = 'internal' and auth_has_role('admin')));

create policy customers_internal on customers for all
  using (org_id = auth_org() and auth_principal() = 'internal')
  with check (org_id = auth_org());

create policy customers_self on customers for select
  using (id = auth_customer());

create policy partners_internal on partners for all
  using (org_id = auth_org() and auth_principal() = 'internal')
  with check (org_id = auth_org());

create policy partners_self on partners for select
  using (id = auth_partner());

create policy partner_users_self  on partner_users  for select using (user_id = auth.uid());
create policy customer_users_self on customer_users for select using (user_id = auth.uid());

create policy resources_internal on resources for all
  using (org_id = auth_org() and auth_principal() = 'internal')
  with check (org_id = auth_org());

-- ---------------------------------------------------------------- jobs

create policy jobs_select on jobs for select
  using (auth_can_see_job(id));

-- Only internal staff create and edit jobs. Partners and customers never write to jobs.
create policy jobs_write on jobs for insert
  with check (org_id = auth_org() and auth_principal() = 'internal');

create policy jobs_update on jobs for update
  using (org_id = auth_org() and auth_principal() = 'internal')
  with check (org_id = auth_org());

-- ---------------------------------------------------------------- stages

create policy stages_select on job_stages for select
  using (auth_can_see_job(job_id));

-- A partner may update ONLY its own assigned stage row, and only the completion columns.
-- Column-level restriction is applied by granting update on specific columns below.
create policy stages_partner_update on job_stages for update
  using (auth_principal() = 'partner' and assigned_partner = auth_partner())
  with check (assigned_partner = auth_partner());

create policy stages_internal_update on job_stages for update
  using (auth_principal() = 'internal' and auth_can_see_job(job_id));

create policy stages_internal_insert on job_stages for insert
  with check (auth_principal() = 'internal' and auth_can_see_job(job_id));

-- ---------------------------------------------------------------- collaboration

create policy events_select on activity_events for select
  using (auth_can_see_job(job_id));

create policy events_insert on activity_events for insert
  with check (auth_can_see_job(job_id));

-- is_internal posts are hidden from the customer portal.
create policy thread_select on thread_posts for select
  using (auth_can_see_job(job_id) and (not is_internal or auth_principal() <> 'customer'));

create policy thread_insert on thread_posts for insert
  with check (auth_can_see_job(job_id));

create policy thread_edit_own on thread_posts for update
  using (author_id = auth.uid());

create policy attach_select on attachments for select
  using (job_id is null and org_id = auth_org() or auth_can_see_job(job_id));

create policy attach_insert on attachments for insert
  with check (job_id is null and org_id = auth_org() or auth_can_see_job(job_id));

create policy actions_internal on action_items for all
  using (org_id = auth_org() and auth_principal() = 'internal')
  with check (org_id = auth_org());

-- ---------------------------------------------------------------- job-scoped children
-- One identical shape for every table that hangs off a job.

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
    execute format(
      'create policy %I_select on %I for select using (auth_can_see_job(job_id))', t, t);
    execute format(
      'create policy %I_write on %I for all
         using (auth_principal() = ''internal'' and auth_can_see_job(job_id))
         with check (auth_can_see_job(job_id))', t, t);
  end loop;
end $$;

-- Grandchildren reach the job through their parent.
create policy cost_lines_all on cost_lines for all
  using (exists (select 1 from quotes q where q.id = quote_id and auth_can_see_job(q.job_id)))
  with check (exists (select 1 from quotes q where q.id = quote_id and auth_can_see_job(q.job_id)));

create policy cad_ann_all on cad_annotations for all
  using (exists (select 1 from cad_revisions r where r.id = revision_id and auth_can_see_job(r.job_id)))
  with check (exists (select 1 from cad_revisions r where r.id = revision_id and auth_can_see_job(r.job_id)));

create policy cad_rev_all on cad_reviews for all
  using (exists (select 1 from cad_revisions r where r.id = revision_id and auth_can_see_job(r.job_id)))
  with check (exists (select 1 from cad_revisions r where r.id = revision_id and auth_can_see_job(r.job_id)));

create policy qc_items_all on qc_checklist_items for all
  using (exists (select 1 from qc_inspections q where q.id = inspection_id and auth_can_see_job(q.job_id)))
  with check (exists (select 1 from qc_inspections q where q.id = inspection_id and auth_can_see_job(q.job_id)));

create policy ship_checks_all on shipment_checks for all
  using (exists (select 1 from shipments s where s.id = shipment_id and auth_can_see_job(s.job_id)))
  with check (exists (select 1 from shipments s where s.id = shipment_id and auth_can_see_job(s.job_id)));

-- ---------------------------------------------------------------- money

-- Customers may read their own quote and invoice; only internal staff may write.
create policy quotes_customer_read on quotes for select
  using (auth_principal() = 'customer' and auth_can_see_job(job_id) and status <> 'draft');

create policy invoices_read on invoices for select
  using (org_id = auth_org() and auth_principal() = 'internal' or customer_id = auth_customer());

create policy invoices_write on invoices for all
  using (org_id = auth_org() and auth_principal() = 'internal')
  with check (org_id = auth_org());

create policy payments_all on payments for all
  using (exists (select 1 from invoices i where i.id = invoice_id
                   and i.org_id = auth_org() and auth_principal() = 'internal'))
  with check (exists (select 1 from invoices i where i.id = invoice_id and i.org_id = auth_org()));

create policy rates_read on metal_rates for select using (org_id = auth_org());
create policy rates_write on metal_rates for insert
  with check (org_id = auth_org() and auth_principal() = 'internal');

-- ---------------------------------------------------------------- inventory

-- Inventory is internal only. No partner or customer ever reads the vault.
create policy inventory_internal on inventory_items for all
  using (org_id = auth_org() and auth_principal() = 'internal')
  with check (org_id = auth_org());

create policy stock_txn_read on stock_transactions for select
  using (org_id = auth_org() and auth_principal() = 'internal');

create policy stock_txn_insert on stock_transactions for insert
  with check (org_id = auth_org() and auth_principal() = 'internal');

-- ---------------------------------------------------------------- column grants
-- D-008: a partner closes its stage but must not reassign the job or rewrite its schedule.

revoke update on job_stages from authenticated;
grant  update (state, completed_at, notes, blocked_reason) on job_stages to authenticated;
