# DhanaOS — Architecture Decision Record

Locked contracts. Changing anything here after Phase 2 is a rewrite, not a refactor.

Source of truth for every decision: the forensic analysis of 46 Stitch mockups across 4 exports
(`stitch_jewelry_production_workflow`, `stitch_remix_*`, `stitch_remix_* (1)`, `stitch_remix_* (2)`).
Where the mockups disagreed, the winning option and its reasoning are recorded below.

---

## D-001 — Job ID scheme

**Decision:** `DH-<year>-<5-digit sequence>` — e.g. `DH-2026-01842`

| State | Identifier | Example |
|---|---|---|
| Pre-commit draft | `DRAFT-<4 char>` | `DRAFT-992A` |
| Committed job | `DH-<year>-<seq>` | `DH-2026-01842` |
| Design reference | `RF-<4 digit>` | `RF-9921` |

**Rejected:** `DH-1048` (no year — breaks across years), `#JB-2094`, `WR-8472-X`, `ORD-992-B`,
`JOB-9842`, `#992-A`, `Order #8824`, `JOB #4829`, `Job #892-A`.

**Why:** five formats coexisted in the mockups. All five folders named `*_dh_1048` rendered a
*different* id on screen; the `$4,850` total proves `pricing_approval` and `job_detail` are the
same job under two ids. Year-scoped sequences are the only scheme that survives multi-year
operation, and the two most recent screens (`review_job_order`, `job_order_created`) already agree
on it.

---

## D-002 — Lifecycle stage vocabulary

**Decision:** the 14-stage enum from `job_detail_dh_1048` is canonical.

```
1  inquiry      5  final_app    9  setting      13  dispatch
2  cad          6  wax         10  polishing    14  delivered
3  approval     7  casting     11  qc
4  pricing      8  assembly    12  cert
```

The dashboard's 8 operational counters are a **derived view**, never a second enum:

| Counter | Derives from |
|---|---|
| CAD Wait | `cad` active, unassigned or awaiting review |
| Approval Wait | `approval` active |
| In Wax | `wax` active |
| At Casting | `casting` active |
| Assembly | `assembly` active |
| Setting | `setting` active |
| In QC | `qc` active |
| Certification | `cert` active |

**Rejected:** the 6-step mobile tracker, the 5-stage created-screen list, the 3-column board.

**Why:** the 14-stage rail is the only vocabulary covering the whole pipeline. The dashboard's
8 counters summed to exactly 55 = "Total Active" in the mockup, which is strong evidence the 8 are
the intended in-production subset of the 14 — a derived grouping, not a rival enum.

**Kept from the rejected vocabularies:** hallmarking (from the mobile tracker's "Final QC &
Hallmarking") survives as a QC checklist item, since it is a real Indian-market requirement.

---

## D-003 — Cost schema

**Decision:** five customer-facing categories.

```
metal · gemstones · labor · setting · certification
```

**Rejected:** the commercial screen's four lines (CAD Design / Setting / Finishing & Polish /
Certification). Those map into the five as internal cost lines: CAD Design → `labor`,
Finishing & Polish → `labor`.

**Why:** the five-category breakdown is what a customer actually approves (`pricing_approval`,
total `$4,850`, which ties to job DH-1048's "Value $4,850"). The four-line version summed to `$970`
and no screen ever displayed that total.

---

## D-004 — Currency and tax

**Decision:** `INR` primary, `USD` supported. Money stored as **integer minor units** (paise /
cents) plus an ISO-4217 currency code. Never floats.

Required from day one because the manufacturer is an Indian entity:

- GSTIN on the org and on every customer
- HSN code per cost line (jewellery: 7113)
- CGST / SGST / IGST split on the invoice
- Tax invoice as a first-class document, not a PDF export

**Why:** every money field in all 46 mockups was USD-only with no selector, while the manufacturer
is "AuraForge India" and one spec screen already used India ring sizing. An Indian manufacturer
cannot legally ship without a tax invoice.

---

## D-005 — State as append-only events

**Decision:** a job has **no mutable status column**. Stage is derived from the latest row in
`job_stages`, an append-only transition log. Every transition writes an `activity_events` row.

**Why:** the mockups already specify this — `certification` titles its feed an "Immutable Audit
Trail", and `job_detail` says "Stage Changed: Casting — System updated status automatically".
For a business taking custody of clients' diamonds and signing QC authorisations, "who approved
what, when" must be reconstructible. A mutable column cannot answer that.

`jobs.current_stage` exists as a **denormalised cache** maintained by trigger, for query speed only.

---

## D-006 — States the mockups omitted

**Decision:** these ship in Phase 2, not later.

```
on_hold · cancelled · rework · qc_failed · lab_rejected · price_rejected · archived
```

**Why:** every gate in the mockups was one-way. `pricing_approval` offered only "Approve".
`quality_control` was irreversible and had no fail path — yet its own JavaScript removed a
`bg-error` class in the else branch, proving a FAILED state was designed and made unreachable.
Retrofitting states into a live append-only audit log is far worse than defining them up front.

---

## D-007 — Stack

| Layer | Choice |
|---|---|
| Client | Flutter 3.47.5 / Dart 3.13.4, Android first |
| State | Riverpod (code-gen) |
| Routing | go_router, declarative, role-guarded |
| Backend | Supabase — Postgres + Auth + Storage + Realtime |
| Auth | Supabase Auth, email/password + phone OTP |
| Offline | Local SQLite mirror for the shop-floor surfaces (Phase 6) |
| Money | `int` minor units + currency code |
| Files | Supabase Storage, one bucket per sensitivity class |

---

## D-008 — Tenancy and row-level security

**Decision:** three principal classes, enforced in Postgres RLS, never in the UI.

| Principal | Sees |
|---|---|
| Internal user | all jobs in their org, scoped further by role |
| Partner (vendor) | only jobs with a stage assigned to that partner |
| Customer (retailer) | only their own jobs, and only customer-visible fields |

**Why:** all 46 mockups hardcoded one identity, "Ravi S. — Manufacturing Engineer", and it leaked
onto the external vendor's screen and the customer's approval screen. The vendor queue was scoped
by a decorative "Assigned to Me" chip with nothing behind it. A vendor seeing another vendor's
jobs is a business-ending defect.

**Test, not a note:** no screen may render an identity that is not the session user.

---

## D-009 — Requirement codes

**Decision:** extend `REQ-<3 letter domain>-<2 digit seq>` to every specification field, as a
first-class `requirements` table.

The mockups carried exactly five, all on one screen:

```
REQ-MAT-01  Base Metal        REQ-FIN-04  Target Budget
REQ-PUR-02  Alloy Purity      REQ-TML-05  Delivery Target
REQ-GEM-03  Gemstone Inset
```

**Why:** it gives shop floor, QC and customer a shared citation for any spec line — QC's checklist
helpers already read like requirement references ("Target: 4.8g Pt950. Allowable variance:
±0.2g."). Cheap at schema time, painful to retrofit.

---

## D-010 — Design tokens

**Decision:** one token set, two themes. Light is the product default; dark is the shop-floor and
mobile theme. One component set, never two screen sets.

| Role | Light | Dark |
|---|---|---|
| surface | `#f7f9fb` | `#041329` |
| surface container | `#ffffff` | `#112036` |
| primary | `#000000` | `#f2ca50` |
| secondary | `#4648d4` | `#b5c7ea` |
| gold / milestone | `#f7be1d` | `#f2ca50` |
| tertiary | `#4648d4` | `#45e6c3` |
| on surface | `#191c1e` | `#d6e3ff` |
| on surface variant | `#45464d` | `#d0c5af` |

**Why:** every mockup declared `darkMode:"class"` yet contained **zero** `dark:` variants — light
and dark shipped as separate exports with complete standalone palettes bound to the same token
names. The markup was theme-agnostic by construction. That is a gift: build once, theme twice.

The warm sand `#d0c5af` label colour against the cold midnight ground is the most deliberate choice
in the source system. Keep it.

**Fixed from the source:** four Tailwind classes silently produced nothing, including
`w-[sidebar-width]` — so the sidebar had no width as shipped. The radius scale was overridden one
step smaller than the spec in every file, making `rounded-full` a 12px rounded square. Both are
corrected here rather than ported.

---

## D-011 — Business rules ported verbatim

Out of 46 screens, real logic appeared four times. All four encode genuine shop-floor thinking.

| Rule | Behaviour |
|---|---|
| **Casting evidence** | A partner cannot complete the casting stage without uploading a photo. Button ships disabled. |
| **Asymmetric CAD decision** | "Request Revisions" is blocked on an empty comment; "Approve" is not. Rejection owes the designer a reason. |
| **QC completeness** | Authorisation enables only at a full checklist. |
| **Capture before continue** | Intake cannot advance past media capture without a reference — *extended* so a voice note or an uploaded sketch also satisfies it, which the mockup's camera-only gate did not. |

---

## D-012 — Canonical screen sources

Where mockups competed, the implementation follows these and merges the named extras.

| Step | Base | Merge in |
|---|---|---|
| Job Type | `start_new_job_light` (B) | — (B has 4 types; C dropped Repair) |
| Media Capture | `capture_details` (C) | `reference_material_capture`'s form + export A's working recorder |
| Product Category | `product_selection` (B) | split into category + sub-style |
| Design Spec | `engagement_ring_specs_expanded` (B) | India sizing primary, US/UK conversion |
| Metal | `metal_materials` | **union** with `quick_specs` — disjoint field sets |
| Stones | `stone_requirements_refined_inputs` (C) | grade ladders from `interactive_inputs`, custody card from `customer_supplied`, **and `origin` + Moissanite + typed carat from the original `stone_requirements`** |
| Commercials | `commercial_requirements` | least-evolved step — needs the most net-new design |
| Delivery | `delivery_requirements` (B) | strip the leaked "CNC Machining" template text |
| Quality | `quality_acceptance` (B) | — |
| Review | `review_job_order` (C) | summary-card idiom from `confirm_order` |
| Created | `job_order_created` (C) | — |

**`stone_origin` is the field to watch.** Natural vs lab-grown changes valuation, disclosure and
certification, and it survived in **exactly one file out of 46** — every later redesign silently
dropped it.
