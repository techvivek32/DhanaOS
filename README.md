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

**1. Create a Supabase project**, then apply the schema in order:

```bash
supabase link --project-ref YOUR-REF
supabase db push                                  # runs supabase/migrations/0001..0010
psql "$DATABASE_URL" -f supabase/seed.sql         # reference data
```

Or paste each file into the Supabase SQL editor in numeric order. `0009_rls.sql` must run —
without it every table is readable by every signed-in user.

**2. Configure the app:**

```bash
cp env/dev.example.json env/dev.json     # fill in your project URL and anon key
```

**3. Run it:**

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
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
supabase/
  migrations/  0001..0010 — schema, functions, RLS, views
  seed.sql     reference data
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
