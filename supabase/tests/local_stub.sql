-- LOCAL TESTING ONLY. Never run this against a Supabase project.
--
-- Recreates the slice of a Supabase database the migrations lean on — the anon / authenticated
-- / service_role roles, auth.uid(), auth.users, a storage schema and Supabase's default grants —
-- so `run.sh` can apply 0001..N to a throwaway Postgres and exercise RLS as each principal.
-- Runs as the cluster superuser; the migrations then run as `postgres`, which (as on Supabase)
-- owns the tables but is not a superuser.

-- Roles are cluster-wide, so a second database on the same cluster finds them already there.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'postgres') then
    create role postgres login createrole;
  end if;
end $$;
grant anon, authenticated, service_role to postgres;
grant create on database dhanaos_test to postgres;  -- run.sh names the database

create schema auth;
-- The columns GoTrue reads on sign-in, so fn_admin_create_user's inserts are exercised as they
-- run on Supabase.
create table auth.users (
  instance_id                uuid,
  id                         uuid primary key default gen_random_uuid(),
  aud                        varchar(255),
  role                       varchar(255),
  email                      varchar(255) unique,
  encrypted_password         varchar(255),
  email_confirmed_at         timestamptz,
  confirmation_token         varchar(255),
  recovery_token             varchar(255),
  email_change_token_new     varchar(255),
  email_change               varchar(255),
  email_change_token_current varchar(255),
  phone_change               text,
  phone_change_token         varchar(255),
  reauthentication_token     varchar(255),
  last_sign_in_at            timestamptz,
  raw_app_meta_data          jsonb,
  raw_user_meta_data         jsonb,
  banned_until               timestamptz,
  created_at                 timestamptz,
  updated_at                 timestamptz,
  is_sso_user                boolean not null default false,
  is_anonymous               boolean not null default false
);
create table auth.identities (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  provider_id     text not null,
  identity_data   jsonb not null,
  provider        text not null,
  last_sign_in_at timestamptz,
  created_at      timestamptz,
  updated_at      timestamptz,
  unique (provider_id, provider)
);

-- Supabase reads the caller from the JWT that PostgREST puts in request.jwt.claims.
create function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(
    current_setting('request.jwt.claim.sub', true),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  ), '')::uuid
$$;

grant usage on schema auth to postgres, anon, authenticated, service_role;
grant select, insert, update, references on auth.users to postgres;
grant select, insert, update on auth.identities to postgres;
grant execute on function auth.uid() to postgres, anon, authenticated, service_role;

create schema extensions;
grant usage on schema extensions to postgres, anon, authenticated, service_role;
create extension if not exists pgcrypto with schema extensions;

create schema storage;
create table storage.buckets (
  id                 text primary key,
  name               text not null unique,
  public             boolean not null default false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz default now()
);
create table storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text references storage.buckets(id),
  name       text not null,
  owner      uuid,
  metadata   jsonb,
  created_at timestamptz default now(),
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1]
$$;
grant usage on schema storage to postgres, anon, authenticated, service_role;
grant all on storage.buckets, storage.objects to postgres, service_role;
grant select, insert, update, delete on storage.objects to authenticated;
grant select on storage.buckets to anon, authenticated;
grant execute on function storage.foldername(text) to postgres, anon, authenticated;
alter table storage.objects owner to postgres;
alter table storage.buckets owner to postgres;

-- Supabase's default privileges: everything in public is reachable by every API role, and RLS
-- is what actually decides. This is exactly why a view without security_invoker leaks.
grant usage on schema public to postgres, anon, authenticated, service_role;
grant create on schema public to postgres;
alter default privileges for role postgres in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on functions to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on sequences to anon, authenticated, service_role;
