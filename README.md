# DhanaOS

Manufacturing operations for a bespoke jewellery workshop — job intake, a tracked production
lifecycle, external vendor and customer portals, QC, certification, dispatch and inventory.

Flutter (Android first) on Supabase. Built for an Indian manufacturer, so INR and GST are
first-class rather than bolted on.

---

## What problem this solves

A custom piece passes through ten-plus pairs of hands: front-desk intake, CAD designer,
commercial approver, wax print, an external casting vendor, bench assembly, stone setter,
polisher, QC, an external gem lab, then insured dispatch. That coordination normally lives in
WhatsApp, spreadsheets and paper spec sheets — so specs drift, clients' stones go missing,
delays surface too late, and nobody can prove what was agreed.

DhanaOS makes the **job order** the single record: a structured intake wizard captures the full
specification, a 14-stage lifecycle tracks it, and a "digital thread" interleaves human messages
with system-written stage events as an audit trail.

## Where the design came from

The product was designed in Google Stitch across four exports (~46 screens) before any code
existed. Those mockups are the specification — but they **contradict each other**: five job-ID
formats, four stage vocabularies, two cost schemas, seven competing stone-requirement screens.

**[DECISIONS.md](DECISIONS.md) records which version won and why.** Read it before changing
anything structural. Re-deriving those choices from the mockups will produce a different, wrong
answer — and several of them are primary keys, so getting one wrong is a rewrite, not a refactor.

[CLAUDE.md](CLAUDE.md) covers day-to-day conventions and the things that will bite you.

---

## Getting started

**Prerequisites** — Flutter 3.47.5+, Android SDK 36, JDK 17.

```bash
flutter doctor           # Android toolchain must be green; Visual Studio is irrelevant here
```

**1. Create a Supabase project**, then apply the schema, the seed and the demo data:

```bash
# Project Settings → Database → Connection string → Session pooler
echo "DATABASE_URL='postgresql://postgres.<ref>:<password>@<host>:5432/postgres'" > env/db.env
DEMO_PASSWORD='choose-one' supabase/apply.sh      # migrations, seed.sql, demo sign-ins + demo.sql
supabase/apply.sh --no-demo                       # production: migrations and seed only
```

`apply.sh` records what it applied in the Supabase CLI's own migrations table, so it is safe to
re-run and `supabase db push` can take over later. `0009_rls.sql` and `0011_hardening.sql` must
both run — without them the anon key in the APK reads and moves every job.

With demo data, `apply.sh` creates the sign-ins listed at the top of
[supabase/demo.sql](supabase/demo.sql) — all with `DEMO_PASSWORD` — including the platform super
admin, and gives each a profile and a role. Never run the demo step against a production
project: the super admin reads every workspace.

**Database tests** — every migration applied to a throwaway local Postgres, then RLS and the
four business rules exercised as each principal (needs Homebrew `postgresql@17`):

```bash
supabase/tests/run.sh
```

**2. Configure the app:**

```bash
cp env/dev.example.json env/dev.json     # fill in your project URL and anon key
```

**3. Run it:**

```bash
flutter pub get
dart run build_runner build
flutter run --dart-define-from-file=env/dev.json
```

**Release APK:**

```bash
flutter build apk --release --dart-define-from-file=env/prod.json
```

To sign a release properly, create `android/key.properties` (gitignored):

```properties
storeFile=C:/keys/dhanaos.jks
storePassword=...
keyAlias=dhanaos
keyPassword=...
```

Without it the release build falls back to debug keys, which is fine for internal testing and
not fine for distribution.

**Web admin panel** — a separate entry point on the same code, models and design system:

```bash
flutter run -d chrome -t lib/admin/main.dart --dart-define-from-file=env/dev.json
flutter build web -t lib/admin/main.dart --dart-define-from-file=env/prod.json -o build/admin
```

`build/admin` is a static site; host it anywhere (Netlify, Vercel, Firebase Hosting, S3).

| Who signs in | What they get |
|---|---|
| Platform super admin (`platform_admins`, no workspace) | Every workspace: create one with its first admin, suspend / reactivate, add an admin, reset a password. Read-only view of each workspace's members, customers, partners and jobs. |
| Workspace admin (`admin` role) | Their own workspace: team and roles, customer and partner records with their portal logins, invoice profile, metal rates, benches. |
| Anyone else | Told to use the app. |

New accounts get a temporary password from whoever creates them and must choose their own at
first sign-in — in the app and in the panel. The rules (last admin, own admin role, other
workspaces) are enforced by the `fn_admin_*` / `fn_platform_*` functions in
[0014_platform.sql](supabase/migrations/0014_platform.sql), not by the screens.

---

## Layout

```
lib/
  core/        design tokens, Money + GST, config, router
  domain/      enums.dart (mirrors the Postgres enums), models/ (freezed)
  data/        supabase/ (client, errors, storage, realtime), repositories/
  features/    auth, intake, jobs, dashboard, production, cad, qc,
               certification, shipping, billing, inventory, partner, portal
  shared/      widgets/ (the design system), shell/ (responsive app shell)
  admin/       the web admin panel (main.dart is its entry point)
supabase/
  migrations/  0001..0014 — schema, functions, RLS, views, hardening, platform
  seed.sql     reference data
  demo.sql     demo profiles and a job at every stage
  apply.sh     apply all of the above to a project
  tests/       RLS and business-rule tests against a local Postgres
website/       public one-page site, static HTML, deploys to Vercel (see website/README.md)
```

## The parts that are easy to get wrong

**Stage is derived, not stored.** `jobs.current_stage` is a trigger-maintained cache. Move a job
with the `fn_complete_stage` RPC — never by updating that column.

**Four business rules live in Postgres**, not in Dart, so a client rewrite cannot break them:

| Rule | Enforced by |
|---|---|
| Casting cannot complete without a photo | `fn_complete_stage` |
| A CAD rejection needs a comment; an approval does not | `cad_reviews` CHECK |
| QC authorises only at a full checklist | `fn_complete_stage` |
| Dispatch is refused while a security check is open | `fn_dispatch_shipment` |

They raise `check_violation` with messages already written for the operator — surface those
verbatim instead of reimplementing the rule client-side.

**Tenancy is enforced in the database.** A partner sees only jobs assigned to them; a customer
sees only their own. The Supabase anon key ships inside the APK, so RLS is the only thing
standing between a vendor and another vendor's jobs.

**`stones.origin` (Natural / Lab Grown) is never optional.** It survived in exactly one of the 46
mockups; every later redesign dropped it. It changes valuation, disclosure and certification.

**Customer-supplied stones need a full custody record** — declared value, verifier, timestamp,
receipt code, risk acknowledgement. The mockups took custody of a client's diamond and recorded
nothing about it.

## Status

Schema, design tokens, domain enums and the Android build are in place. Feature screens are
landing per `lib/features/`. See DECISIONS.md for the phase plan.
