-- DhanaOS 0014 — the platform: super admins, tenant lifecycle, and the admin panel's writes
--
-- Three levels of authority:
--   * super admin  — operates the DhanaOS platform. Belongs to no org. Creates tenants and their
--                    first admins, suspends and reactivates them, resets a locked-out admin, and
--                    reads every tenant's data for support — read-only: no write policy anywhere
--                    names a super admin, and a super admin has no app_users row, so every
--                    principal check refuses them.
--   * tenant admin — the existing `admin` role, inside one org. Manages that org's people,
--                    roles, customers, partners and profile.
--   * everyone else — unchanged (0009, 0011).
--
-- New accounts get a temporary password from whoever creates them and must change it at first
-- sign-in. Accounts are created here, as the definer, because the anon key cannot reach the
-- GoTrue admin API and the platform has no mail relay for invitations.

-- ---------------------------------------------------------------- 1. super admins

create table platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null,
  email      text,
  created_at timestamptz not null default now()
);

comment on table platform_admins is
  'Platform operators. Not members of any org. Added by SQL only — no policy writes this table.';

create or replace function auth_is_super_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from platform_admins where user_id = auth.uid());
$$;

alter table platform_admins enable row level security;
create policy platform_admins_read on platform_admins for select
  using (user_id = auth.uid() or auth_is_super_admin());

-- ---------------------------------------------------------------- 2. tenant and member state

alter table orgs
  add column is_active        boolean not null default true,
  add column suspended_at     timestamptz,
  add column suspended_reason text,
  add column created_by       uuid references auth.users(id) on delete set null;

alter table app_users
  add column must_change_password boolean not null default false;

-- A deactivated member, or any member of a suspended org, resolves to no org and no principal,
-- so every policy built on these helpers refuses them — reads included — without touching the
-- policies themselves.
create or replace function auth_org() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select u.org_id from app_users u join orgs o on o.id = u.org_id
   where u.id = auth.uid() and u.is_active and o.is_active;
$$;

create or replace function auth_principal() returns principal_class
language sql stable security definer set search_path = public, pg_temp as $$
  select u.principal from app_users u join orgs o on o.id = u.org_id
   where u.id = auth.uid() and u.is_active and o.is_active;
$$;

create or replace function auth_has_role(r user_role) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from user_roles ur
      join app_users u on u.id = ur.user_id
      join orgs o on o.id = u.org_id
     where ur.user_id = auth.uid() and ur.role = r and u.is_active and o.is_active);
$$;

create or replace function auth_partner() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select pu.partner_id from partner_users pu
    join app_users u on u.id = pu.user_id
    join orgs o on o.id = u.org_id
   where pu.user_id = auth.uid() and u.is_active and o.is_active;
$$;

create or replace function auth_customer() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select cu.customer_id from customer_users cu
    join app_users u on u.id = cu.user_id
    join orgs o on o.id = u.org_id
   where cu.user_id = auth.uid() and u.is_active and o.is_active;
$$;

-- A locked-out member can still read their own org row, so the app can say "this workspace is
-- suspended" instead of failing to load.
create policy org_read_own on orgs for select
  using (id = (select org_id from app_users where id = auth.uid()));

-- ---------------------------------------------------------------- 3. super admin reads

-- One select-only policy per table. Writes are untouched: they all require an org principal,
-- which a super admin does not have.
do $$
declare
  t text;
begin
  for t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and c.relname <> 'platform_admins'
  loop
    execute format(
      'create policy %I on %I for select using (auth_is_super_admin())', t || '_platform_read', t);
  end loop;
end $$;

create policy dhanaos_platform_read on storage.objects for select to authenticated
  using (bucket_id in ('job-files', 'vault', 'brand') and auth_is_super_admin());

-- ---------------------------------------------------------------- 4. who can see whom

-- roles_read let an admin read every org's role rows; and nobody could see which customer or
-- partner a portal login belongs to, which the admin panel has to show.
drop policy roles_read on user_roles;
create policy roles_read on user_roles for select
  using (user_id = auth.uid()
         or (auth_principal() = 'internal'
             and exists (select 1 from app_users u where u.id = user_id and u.org_id = auth_org())));

create policy partner_users_org on partner_users for select
  using (auth_principal() = 'internal'
         and exists (select 1 from app_users u where u.id = user_id and u.org_id = auth_org()));

create policy customer_users_org on customer_users for select
  using (auth_principal() = 'internal'
         and exists (select 1 from app_users u where u.id = user_id and u.org_id = auth_org()));

-- ---------------------------------------------------------------- 5. org profile

-- An admin edits the profile an invoice prints (D-004), never the job-code counter (D-001).
revoke update on orgs from authenticated;
grant update (name, legal_name, gstin, pan, address, base_currency, logo_path) on orgs to authenticated;

create policy orgs_admin_update on orgs for update
  using (id = auth_org() and auth_principal() = 'internal' and auth_has_role('admin'))
  with check (id = auth_org());

-- ---------------------------------------------------------------- 6. accounts

-- Mirrors a confirmed email signup. The empty strings matter: GoTrue scans those token columns
-- into Go strings and a NULL there fails every sign-in with a 500 (see demo_users.sql).
create or replace function _dh_create_login(p_email text, p_password text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_id    uuid := gen_random_uuid();
  v_email text := lower(trim(p_email));
begin
  if v_email is null or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Enter a valid email address' using errcode = 'check_violation';
  end if;
  if length(coalesce(p_password, '')) < 8 then
    raise exception 'The temporary password must be at least 8 characters'
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from auth.users where lower(email) = v_email) then
    raise exception 'An account with % already exists', v_email using errcode = 'unique_violation';
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change, email_change_token_new,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token)
  values (
    '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
    crypt(p_password, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
    '', '', '', '', '', '', '', '');

  insert into auth.identities (
    id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (
    gen_random_uuid(), v_id, v_id::text,
    jsonb_build_object('sub', v_id::text, 'email', v_email,
                       'email_verified', true, 'phone_verified', false),
    'email', now(), now(), now());

  return v_id;
end;
$$;

-- Who may administer members of p_org: its own active admins. Raises otherwise.
create or replace function _dh_require_org_admin(p_org uuid)
returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null or auth_principal() is distinct from 'internal'
     or not auth_has_role('admin') or auth_org() is distinct from p_org then
    raise exception 'Only an administrator of this workspace can do that'
      using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- Active admins of an org, optionally ignoring one user (the one being changed).
create or replace function _dh_active_admins(p_org uuid, p_except uuid default null)
returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::int
    from app_users u join user_roles r on r.user_id = u.id and r.role = 'admin'
   where u.org_id = p_org and u.is_active and u.principal = 'internal'
     and (p_except is null or u.id <> p_except);
$$;

-- Create a member. A tenant admin creates anyone in their own org. A super admin creates only a
-- tenant's administrators — the tenant admin adds everyone else.
create or replace function fn_admin_create_user(
  p_email         text,
  p_full_name     text,
  p_temp_password text,
  p_principal     principal_class default 'internal',
  p_roles         user_role[] default '{}',
  p_title         text default null,
  p_phone         text default null,
  p_customer      uuid default null,
  p_partner       uuid default null,
  p_org           uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_org   uuid;
  v_id    uuid;
  v_roles user_role[];
  v_name  text := nullif(trim(p_full_name), '');
begin
  if auth_is_super_admin() and auth_org() is null then
    if p_org is null or not exists (select 1 from orgs where id = p_org) then
      raise exception 'Choose the workspace this administrator belongs to'
        using errcode = 'check_violation';
    end if;
    if p_principal <> 'internal' or not ('admin' = any(p_roles)) then
      raise exception 'Platform admins add workspace administrators; the workspace admin adds everyone else'
        using errcode = 'insufficient_privilege';
    end if;
    v_org := p_org;
  else
    v_org := auth_org();
    if p_org is not null and p_org is distinct from v_org then
      raise exception 'Only an administrator of this workspace can do that'
        using errcode = 'insufficient_privilege';
    end if;
    perform _dh_require_org_admin(v_org);
  end if;

  if v_name is null then
    raise exception 'Enter the person''s name' using errcode = 'check_violation';
  end if;

  case p_principal
    when 'internal' then
      v_roles := array(select distinct unnest(p_roles));
      if coalesce(array_length(v_roles, 1), 0) = 0 then
        raise exception 'Give the member at least one role' using errcode = 'check_violation';
      end if;
      if 'partner' = any(v_roles) or 'customer' = any(v_roles) then
        raise exception 'Partner and customer logins are added from their own record'
          using errcode = 'check_violation';
      end if;
    when 'partner' then
      if p_partner is null or not exists (select 1 from partners where id = p_partner and org_id = v_org) then
        raise exception 'Choose the partner this login belongs to' using errcode = 'check_violation';
      end if;
      v_roles := array['partner']::user_role[];
    when 'customer' then
      if p_customer is null or not exists (select 1 from customers where id = p_customer and org_id = v_org) then
        raise exception 'Choose the customer this login belongs to' using errcode = 'check_violation';
      end if;
      v_roles := array['customer']::user_role[];
  end case;

  v_id := _dh_create_login(p_email, p_temp_password);

  insert into app_users (id, org_id, principal, full_name, title, initials, email, phone,
                         must_change_password)
  values (v_id, v_org, p_principal, v_name, nullif(trim(p_title), ''),
          upper(left(regexp_replace(v_name, '(\w)\w*\s*', '\1', 'g'), 3)),
          lower(trim(p_email)), nullif(trim(p_phone), ''), true);

  insert into user_roles (user_id, role) select v_id, unnest(v_roles);

  if p_principal = 'partner' then
    insert into partner_users (user_id, partner_id) values (v_id, p_partner);
  elsif p_principal = 'customer' then
    insert into customer_users (user_id, customer_id) values (v_id, p_customer);
  end if;

  return v_id;
end;
$$;

-- Name, title, phone and — for workspace staff — roles.
create or replace function fn_admin_update_member(
  p_user      uuid,
  p_full_name text,
  p_title     text default null,
  p_phone     text default null,
  p_roles     user_role[] default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_org       uuid;
  v_principal principal_class;
  v_roles     user_role[];
  v_name      text := nullif(trim(p_full_name), '');
begin
  select org_id, principal into v_org, v_principal from app_users where id = p_user;
  if v_org is null then
    raise exception 'That member does not exist' using errcode = 'no_data_found';
  end if;
  perform _dh_require_org_admin(v_org);

  if v_name is null then
    raise exception 'Enter the person''s name' using errcode = 'check_violation';
  end if;

  update app_users
     set full_name = v_name,
         title     = nullif(trim(p_title), ''),
         phone     = nullif(trim(p_phone), ''),
         initials  = upper(left(regexp_replace(v_name, '(\w)\w*\s*', '\1', 'g'), 3))
   where id = p_user;

  if p_roles is null or v_principal <> 'internal' then
    return;
  end if;

  v_roles := array(select distinct unnest(p_roles));
  if coalesce(array_length(v_roles, 1), 0) = 0 then
    raise exception 'Give the member at least one role' using errcode = 'check_violation';
  end if;
  if 'partner' = any(v_roles) or 'customer' = any(v_roles) then
    raise exception 'Partner and customer logins are added from their own record'
      using errcode = 'check_violation';
  end if;

  if not ('admin' = any(v_roles)) and exists (
       select 1 from user_roles where user_id = p_user and role = 'admin') then
    if p_user = auth.uid() then
      raise exception 'You cannot remove your own admin role — ask another admin'
        using errcode = 'check_violation';
    end if;
    if _dh_active_admins(v_org, p_user) = 0 then
      raise exception 'This is the only admin left — make someone else an admin first'
        using errcode = 'check_violation';
    end if;
  end if;

  delete from user_roles where user_id = p_user and not (role = any(v_roles));
  insert into user_roles (user_id, role)
  select p_user, r from unnest(v_roles) r
  on conflict do nothing;
end;
$$;

-- Deactivate or reactivate. A deactivated member keeps their history on every record; they just
-- cannot sign in, and RLS gives an existing session nothing.
create or replace function fn_admin_set_member_active(p_user uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_org uuid;
begin
  select org_id into v_org from app_users where id = p_user;
  if v_org is null then
    raise exception 'That member does not exist' using errcode = 'no_data_found';
  end if;
  perform _dh_require_org_admin(v_org);

  if not p_active then
    if p_user = auth.uid() then
      raise exception 'You cannot deactivate yourself' using errcode = 'check_violation';
    end if;
    if exists (select 1 from user_roles where user_id = p_user and role = 'admin')
       and _dh_active_admins(v_org, p_user) = 0 then
      raise exception 'This is the only admin left — make someone else an admin first'
        using errcode = 'check_violation';
    end if;
  end if;

  update app_users set is_active = p_active where id = p_user;
  update auth.users
     set banned_until = case when p_active then null else now() + interval '100 years' end
   where id = p_user;
end;
$$;

-- Set a new temporary password. The tenant admin for their members; a super admin for anyone,
-- which is how a workspace whose only admin is locked out gets back in.
create or replace function fn_admin_reset_password(p_user uuid, p_temp_password text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_org uuid;
begin
  select org_id into v_org from app_users where id = p_user;
  if v_org is null then
    raise exception 'That member does not exist' using errcode = 'no_data_found';
  end if;
  if not (auth_is_super_admin() and auth_org() is null) then
    perform _dh_require_org_admin(v_org);
  end if;
  if p_user = auth.uid() then
    raise exception 'Change your own password from your account instead'
      using errcode = 'check_violation';
  end if;
  if length(coalesce(p_temp_password, '')) < 8 then
    raise exception 'The temporary password must be at least 8 characters'
      using errcode = 'check_violation';
  end if;

  update auth.users
     set encrypted_password = crypt(p_temp_password, gen_salt('bf')), updated_at = now()
   where id = p_user;
  update app_users set must_change_password = true where id = p_user;
end;
$$;

-- Called by the app after auth.updateUser(password) succeeds for the signed-in user.
create or replace function fn_password_changed()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update app_users set must_change_password = false where id = auth.uid();
$$;

-- ---------------------------------------------------------------- 7. tenants

create or replace function _dh_require_super_admin()
returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not auth_is_super_admin() then
    raise exception 'Only a platform administrator can do that'
      using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- A new workspace and its first administrator, in one transaction.
create or replace function fn_platform_create_org(
  p_name           text,
  p_legal_name     text,
  p_gstin          text,
  p_base_currency  char(3),
  p_admin_email    text,
  p_admin_name     text,
  p_admin_password text,
  p_address        jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_org  uuid;
  v_user uuid;
  v_name text := nullif(trim(p_admin_name), '');
begin
  perform _dh_require_super_admin();
  if nullif(trim(p_name), '') is null then
    raise exception 'Enter the workspace name' using errcode = 'check_violation';
  end if;
  if v_name is null then
    raise exception 'Enter the administrator''s name' using errcode = 'check_violation';
  end if;

  insert into orgs (name, legal_name, gstin, base_currency, address, created_by)
  values (trim(p_name), nullif(trim(p_legal_name), ''), nullif(upper(trim(p_gstin)), ''),
          coalesce(p_base_currency, 'INR'), coalesce(p_address, '{}'::jsonb), auth.uid())
  returning id into v_org;

  v_user := _dh_create_login(p_admin_email, p_admin_password);

  insert into app_users (id, org_id, principal, full_name, title, initials, email,
                         must_change_password)
  values (v_user, v_org, 'internal', v_name, 'Administrator',
          upper(left(regexp_replace(v_name, '(\w)\w*\s*', '\1', 'g'), 3)),
          lower(trim(p_admin_email)), true);
  insert into user_roles (user_id, role) values (v_user, 'admin');

  return v_org;
end;
$$;

create or replace function fn_platform_set_org_active(p_org uuid, p_active boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform _dh_require_super_admin();
  if not exists (select 1 from orgs where id = p_org) then
    raise exception 'That workspace does not exist' using errcode = 'no_data_found';
  end if;
  if not p_active and nullif(trim(p_reason), '') is null then
    raise exception 'Say why the workspace is being suspended' using errcode = 'check_violation';
  end if;

  update orgs
     set is_active        = p_active,
         suspended_at     = case when p_active then null else now() end,
         suspended_reason = case when p_active then null else trim(p_reason) end
   where id = p_org;
end;
$$;

-- One row per tenant with the figures the platform console lists. Runs as the caller: a super
-- admin sees every tenant, a workspace member only their own.
create or replace view v_platform_tenants
with (security_invoker = true)
as
select
  o.id,
  o.name,
  o.legal_name,
  o.gstin,
  o.base_currency,
  o.is_active,
  o.suspended_at,
  o.suspended_reason,
  o.created_at,
  (select count(*) from app_users u where u.org_id = o.id and u.is_active)::int as active_members,
  (select count(*) from app_users u join user_roles r on r.user_id = u.id and r.role = 'admin'
    where u.org_id = o.id and u.is_active)::int as admins,
  (select count(*) from customers c where c.org_id = o.id)::int as customers,
  (select count(*) from partners p where p.org_id = o.id)::int as partners,
  (select count(*) from jobs j where j.org_id = o.id and j.code is not null
      and j.status not in ('completed', 'cancelled', 'archived'))::int as open_jobs,
  (select count(*) from jobs j where j.org_id = o.id and j.code is not null)::int as total_jobs,
  (select max(j.updated_at) from jobs j where j.org_id = o.id) as last_activity
from orgs o;

-- ---------------------------------------------------------------- 8. grants

revoke all on function _dh_create_login(text, text) from public, anon, authenticated;
revoke all on function _dh_require_org_admin(uuid) from public, anon, authenticated;
revoke all on function _dh_active_admins(uuid, uuid) from public, anon, authenticated;
revoke all on function _dh_require_super_admin() from public, anon, authenticated;

grant execute on function auth_is_super_admin() to authenticated;
grant execute on function fn_admin_create_user(text, text, text, principal_class, user_role[], text, text, uuid, uuid, uuid) to authenticated;
grant execute on function fn_admin_update_member(uuid, text, text, text, user_role[]) to authenticated;
grant execute on function fn_admin_set_member_active(uuid, boolean) to authenticated;
grant execute on function fn_admin_reset_password(uuid, text) to authenticated;
grant execute on function fn_password_changed() to authenticated;
grant execute on function fn_platform_create_org(text, text, text, char, text, text, text, jsonb) to authenticated;
grant execute on function fn_platform_set_org_active(uuid, boolean, text) to authenticated;
