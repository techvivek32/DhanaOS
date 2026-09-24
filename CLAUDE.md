# DhanaOS

Manufacturing operations for a bespoke jewellery workshop. Flutter (Android first) + Supabase.

The product was designed in Google Stitch across four exports (~46 screens) before any code
existed. Those mockups are the specification, but they contradict each other in several places.
**[DECISIONS.md](DECISIONS.md) records which version won and why — read it before changing
anything structural.** Re-deriving those choices from the mockups will produce a different and
wrong answer.

## Layout

```
lib/
  core/        theme tokens, Money + GST, config, router
  domain/      enums.dart (mirrors the Postgres enums), models/ (freezed)
  data/        supabase/ (client, errors, storage, realtime), repositories/
  features/    auth, intake, jobs, dashboard, production, cad, qc,
               certification, shipping, billing, inventory, partner, portal
  shared/      widgets/ (the design system), shell/ (responsive app shell)
supabase/
  migrations/  0001..0010 — schema, functions, RLS, views
  seed.sql     reference data using the mockups' real sample records
```

## Running it

```bash
cp env/dev.example.json env/dev.json     # then fill in your Supabase URL + anon key
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run --dart-define-from-file=env/dev.json
```

Release APK:

```bash
flutter build apk --release --dart-define-from-file=env/prod.json
```

`env/*.json` is gitignored. Keys never enter the repo — they reach the build through
`--dart-define`. The anon key is safe in an APK **because** every table is behind RLS; that is
what makes [D-008](DECISIONS.md) load-bearing rather than decorative.

## Conventions

- **Enums cross the wire through `.wire` and `Xxx.parse()`** — never `.name`, never
  `toString()`. Renaming a Dart enum value does not change the database.
- **Money is `Money`** (integer minor units + currency). Never `double`. Indian digit grouping
  and GST live in `core/money.dart`.
- **No colour, radius or spacing literals in widgets.** Read `context.scheme`, `context.dh`,
  `Spacing`, `Radii`. Every widget must render correctly in both themes.
- **Monospace for data.** Every SKU, job code, weight, carat, dimension and timestamp uses
  `AppTheme.mono()` so operators can compare digits down a column.
- **Generated files are not committed** (`*.freezed.dart`, `*.g.dart`). Run build_runner.

## Things that will bite you

**Stage is derived, not stored.** `jobs.current_stage` and `jobs.status` are a trigger-maintained
cache. Move a job by calling `fn_complete_stage`, never by updating those columns — see
[D-005](DECISIONS.md).

**Business rules live in the database.** Four rules are enforced by Postgres functions and
CHECK constraints, not by the client:

| Rule | Enforced by |
|---|---|
| Casting needs a photo before completion | `fn_complete_stage` |
| CAD rejection needs a comment; approval does not | `cad_reviews` CHECK |
| QC authorises only at a full checklist | `fn_complete_stage` |
| Dispatch is refused while a security check is open | `fn_dispatch_shipment` |

They raise `check_violation` with messages already written from the operator's side — surface
those verbatim rather than re-implementing the rule in Dart.

**`stones.origin` (Natural / Lab Grown) is never optional.** It survived in exactly one of the
46 mockups; every later redesign dropped it. It changes valuation, disclosure and certification.

**Customer-supplied stones need a full custody record** — declared value, verifier, timestamp,
receipt code, risk acknowledgement. The mockups took custody of a client's diamond and recorded
nothing.

## Build order

Phases 0–8 are listed in the blueprint. Phase 0 (contracts, schema, tokens) and the Flutter
foundation are done; features land per `lib/features/`.
