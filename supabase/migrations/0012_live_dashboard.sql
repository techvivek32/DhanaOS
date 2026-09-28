-- DhanaOS 0012 — the dashboard, live
-- Two things the first run against a real project showed.

-- ---------------------------------------------------------------- counters count blocked jobs

-- A job blocked at casting is still at casting — the production board shows it in that column
-- (v_production_board takes active and blocked). Counting only active stages dropped every
-- blocked job from the tiles, so the dashboard's own "rail and status counts disagree" check
-- fired for a situation that is normal on any shop floor.
create or replace view v_stage_counters
with (security_invoker = true)
as
select
  j.org_id,
  s.stage,
  count(*)::int as job_count
from job_stages s
join jobs j on j.id = s.job_id
where s.state in ('active', 'blocked')
  and j.status = 'in_production'
  and s.stage in ('cad','approval','wax','casting','assembly','setting','qc','cert')
group by j.org_id, s.stage;

comment on view v_stage_counters is
  'D-002. The 8 dashboard counters: CAD Wait, Approval Wait, In Wax, At Casting, Assembly, '
  'Setting, In QC, Certification. Blocked jobs count where they stand. Their sum is Total '
  'Active by construction.';

-- ---------------------------------------------------------------- realtime

-- data/supabase/realtime.dart and the feature gateways subscribe to these; Postgres only streams
-- tables the publication names, so without this every live feed subscribed cleanly and never
-- delivered a row. RLS still applies per subscriber. Guarded so a plain Postgres
-- (supabase/tests) without the publication still migrates.
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    return;
  end if;
  foreach t in array array['jobs','job_stages','activity_events','thread_posts','attachments',
                           'casting_params','job_exceptions','cad_revisions','cad_reviews']
  loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public'
                      and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
