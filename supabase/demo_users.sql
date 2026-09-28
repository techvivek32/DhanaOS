-- DhanaOS demo sign-ins — creates the Supabase Auth users that demo.sql gives profiles to, so a
-- fresh project can be signed into without adding eight users by hand. DEMO PROJECTS ONLY.
--
-- Run by supabase/apply.sh before demo.sql, with the password as a psql variable:
--
--   psql "$DATABASE_URL" -v demo_password='…' -f supabase/demo_users.sql
--
-- Emails that already exist are left alone, password included. The rows mirror what GoTrue
-- writes on a confirmed email signup; the empty strings matter, because GoTrue scans those
-- token columns into Go strings and a NULL there fails every sign-in with a 500.

\set ON_ERROR_STOP 1

with demo(email) as (
  values ('ravi@auraforge.example'), ('elena@auraforge.example'),
         ('meera@auraforge.example'), ('karan@auraforge.example'),
         ('nilesh@patelcasting.example'), ('ops@forge-a.example'),
         ('marcus@scottsdalediamond.example'), ('priya@abcjewelers.example'),
         ('superadmin@dhanaos.example')
)
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new,
  email_change_token_current, phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
       'authenticated', d.email, extensions.crypt(:'demo_password', extensions.gen_salt('bf')),
       now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
       '', '', '', '', '', '', '', ''
  from demo d
 where not exists (select 1 from auth.users u where lower(u.email) = d.email);

insert into auth.identities (
  id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
)
select gen_random_uuid(), u.id, u.id::text,
       jsonb_build_object('sub', u.id::text, 'email', u.email,
                          'email_verified', true, 'phone_verified', false),
       'email', now(), now(), now()
  from auth.users u
 where lower(u.email) in ('ravi@auraforge.example', 'elena@auraforge.example',
                          'meera@auraforge.example', 'karan@auraforge.example',
                          'nilesh@patelcasting.example', 'ops@forge-a.example',
                          'marcus@scottsdalediamond.example', 'priya@abcjewelers.example',
                          'superadmin@dhanaos.example')
   and not exists (select 1 from auth.identities i
                    where i.user_id = u.id and i.provider = 'email');
