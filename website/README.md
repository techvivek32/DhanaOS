# DhanaOS website

The public one-page site for DhanaOS. Plain HTML, CSS and JavaScript with no build step, so it
deploys to Vercel as-is.

The page is a numbered **drawing set** for one sample ring. Every callout, table and note on
the sheets is a field DhanaOS keeps on the job record:

| Sheet | Section | Drawing device |
|---|---|---|
| 01 | Overview (`#top`) | three-view drawing of the sample ring, zone frame, title block = the job record |
| 02 | How it works (`#how`) | process sheet: phase dimension lines, dashed outside-partner boxes, rule flags, the sample job's path, sticky column header |
| 03 | The rules (`#rules`) | 01–14 scale with leaders, four drawing notes, operator messages in revision clouds |
| 04 | Custody (`#custody`) | stone paper drawn flat, Detail A, vault plan, goods-in receipt as a parts list, six general notes |
| 05 | Try it (`#try`) | the calculator (built by `sim.js`) inside trim marks |
| 06 | Access (`#access`) | CAD layer table: roles as layers, outside partners dashed |
| 07 | In the app (`#features`) | parts list (BOM) with item balloons |
| 08 | Rollout (`#rollout`) | revision schedule on a ring-mandrel week axis, week 8 "Issued for production" |
| 09 | FAQ (`#faq`) | general notes (`<details>`) |
| 10 | Demo (`#contact`) | an empty title block for the visitor's own past job |

```
index.html               the whole page (hand-edited; drawings live in gen: blocks, see below)
assets/css/style.css     tokens, sheets, drawing ink, every section, breakpoints
assets/css/sim.css       the gold-loss calculator
assets/js/main.js        footer year, copy-email button, sheets that draw on arrival, nav focus
assets/js/sim.js         builds the calculator into #gold-sim
assets/fonts/            Barlow Semi Condensed 600/700, Barlow 400/500, Martian Mono (latin, OFL)
assets/favicon.svg, apple-touch-icon.png (180×180), og-image.jpg (1200×630)
tools/drawings.py        regenerates the line drawings inside index.html; not deployed
vercel.json              security + cache headers
.vercelignore            keeps tools/ and this README off the live site
robots.txt, sitemap.xml
```

## Design notes

- **Inks.** Desk `#DCE1DE`, drafting film `#F3F5F2`, graphite `#14171A` / `#30363B` / `#5A626A`.
  Non-photo blue `#3A97C2` is used only for centre and projection lines. Molten `#FF5A1F`
  (`#B13A07` for small text and thin strokes, 5.5:1 on film) is used for what is live right now
  (the sample job's step 07, its casting photo 0/1, "Here now") and for rule breaches (open
  checklist boxes, the missing reason, the open contents check, the "On screen" label).
  `#B13A07` also draws the rule flags and their labels (sheet 02's steps and legend, sheet 03's
  rule cards), the edge of the "now" disc in the legend and on the phone's step 07, the receipt's
  "Required" tag on sheet 04, and the calculator's yearly figure on sheet 05. Nothing else is
  orange. Never use `#FF5A1F` for text or a thin line on film: it is only 2.8:1.
- **Type.** Barlow Semi Condensed for headlines, Barlow for text, Martian Mono (width pinned at
  87.5% by Google Fonts, weight variable) for every code, weight, size and label. No serif, no
  italics. Nothing is set under 11px on desktop or 12px on phones, except the zone numbers
  around sheet 01, which are decorative and hidden from screen readers.
- **Frames.** Only sheet 01 has the full zone frame (1–12, A–F). The other sheets have a single
  edge and a sheet-number tab. On phones the sheets go full-bleed with a 16px gutter.
- **The hero drawing.** Top, front and side views share one scale (13 px/mm: the 16.92 mm
  inside diameter is 220 units) and one set of projection lines. The six claws sit at 0°, 60° …
  300°: four show in the front view and three in the side view, and the far ones hide exactly
  behind them. Section A–A is drawn at 2:1 and hatched in graphite at 45°. The drawing's text is
  HTML laid over the SVG, so it stays readable when the drawing scales.
- **Motion.** Lines plot on load; sheets 03 and 04 plot when they arrive, and printing releases
  them. Because the sample job is at casting, molten metal rises once from the sprue end of the
  band (SMIL on the clip rect, about 1.2 s) and then cools away. The step 07 pulse runs twice and
  stops. With `prefers-reduced-motion` there is no animation and no glow at all.
- **Revision clouds** are pure CSS (`border-image` with an inline SVG), so they need no script.
- **Breakpoints.** 1360 (the sheet 03 scale and its leaders show only from here up: the leader
  ends are fixed points that drift off the flags on a narrower sheet), 1240 (rules go 2×2), 1180
  (hero drawing crops its empty left margin; the stage callout steps aside because the title
  block carries it), 980 (nav links become a scrolling second row; the nav stops being sticky),
  960 (hero stacks), 700 (phone: the hero drawing crops to the top and front views with numbered
  balloons and a callout list).

## Editing the drawings

The SVG drawings are generated so their geometry stays consistent. `index.html` is the real
page; the script only rewrites the blocks between `<!-- gen:NAME -->` and `<!-- /gen:NAME -->`:

```bash
python website/tools/drawings.py
```

Blocks: `hero`, `rule1`–`rule4`, `parcel`, `detail`, `vault`, `mandrel`. Edit anything outside
those markers by hand. The sheet 03 scale leaders and all copy are plain HTML.

## Run locally

The fonts are self-hosted, and browsers block them over `file://`, so serve the folder:

```bash
python -m http.server 8080 --directory website
```

## Deploy

Live at **https://dhanaos.vercel.app**. The Vercel project `dhanaos`
(`vivekvora3226-2527s-projects`) is connected to this GitHub repo with **Root Directory =
`website`**. Every push to `main` deploys to production; other branches get preview URLs.

Do not run `vercel` from inside `website/`. The project's root directory would then resolve to
`website/website` and the deploy fails. For a manual deploy, run it from the repo root:

```bash
npx vercel --prod
```

If the Root Directory setting is ever reset to `.`, Vercel serves the Flutter repo root, which
has no `index.html`, and the site returns 404.

## Placeholders

- **Domain.** `https://dhanaos.vercel.app/` is written into `index.html` (canonical, Open Graph,
  Twitter), `robots.txt` and `sitemap.xml`. If you add a custom domain, search-and-replace it in
  those three files.
- **Contact.** The demo stamp, the FAQ link and the copy button use `info@madvision.tech`. Change
  it in `index.html` (four places: the stamp's `mailto:`, the FAQ `mailto:`, the visible address
  and `data-copy`), and in the JSON-LD block.

## Keeping it accurate

Every claim on the page maps to something in the app or the brief. If one of these changes,
change the page:

| Page says | Source |
|---|---|
| 14 steps, their names, Design 1–5 / Make 6–10 / Prove & ship 11–14 | `LifecycleStage` in `lib/domain/enums.dart`, D-002 |
| Rule messages for casting, QC and dispatch (verbatim) | `fn_complete_stage`, `fn_dispatch_shipment` (redefined in `0011`/`0013`) |
| Design-approval message, shown when a rejection has no comment (verbatim) | `CadReview.rejectionNeedsComment` in `lib/domain/models/production.dart` |
| Rules numbered 01–04 by step (03, 07, 11, 13) | presentation only; the steps come from `LifecycleStage` |
| Casting and certification are the two outside-partner steps | `isPartnerStage` |
| Partners see only their jobs, never quotes or invoices | RLS in `0009_rls.sql` / `0011_hardening.sql`, D-008 |
| Layer table: team "Screens for their role", partners "Limited by the database" | `lib/features/auth/permissions.dart` (team); RLS as above (partners) |
| Approval history can't be edited | `activity_events` has no update or delete policy |
| Every center and side stone must be marked natural or lab-grown (hero Origin callout, receipt, note 4) | intake checklist (`IntakeDraft._stoneGates` → `Stone.openQuestions`); melee parcels are not gated, so the page doesn't say "every stone"; `stones.origin` itself is nullable |
| Goods-in receipt fields and `GRN-…` code (no location: the receipt has none) | `goods_in_receipts` in `0007_inventory.sql` |
| Stock in the vault has a location (note 2, the vault plan's stock lot) | `inventory_items.location` in `0007_inventory.sql` |
| Layer table: six team layers plus two outside; no front-desk layer, because opening an order is limited to admin, engineer and production manager (row 01 carries it) | `UserRole` in `lib/domain/enums.dart`, `AreaRoles.intake` in `lib/shared/shell/app_shell.dart` |
| Rules "the database enforces" (sheet 03, the hero stat, the share text and image) | the four rules above; the copy stops short of "no one can skip" while checklist and shipment-check rows can still be deleted through the API |
| Ø16.92 mm inside diameter = US 6½ = UK M½ = IN 12 | `lib/features/intake/ring_sizes.dart` |
| USD + INR, GST split | `core/money.dart`, D-004 |
| Web admin panel (team, logins, invoice profile, metal rates) | `lib/admin/`, `0014_platform.sql` |
| Gold-loss calculator | illustrative: grams × % × 12 × price, in `assets/js/sim.js`; the static line inside `#gold-sim` (shown without JavaScript) states the default inputs and must match them |
| 8-week rollout, not-included list (no accounting export) | the project brief; `lib/` has no accounting or CSV export |
| Certification labs GIA, IGI, HRD, AGS | `CertLab` in `lib/domain/enums.dart` |
| Job thread: stage changes can't be edited (messages can, by their author) | `activity_events` has no update or delete policy; `thread_posts` has `thread_edit_own` in `0011_hardening.sql` |
| Vault A's eight-tray plan and its tray 4 stock lot, the 12-box QC checklist, "2 open", "contents" open | illustrative, labeled "Sample" on the page; they match the sample on-screen messages, not fields on the record |
| Rev letters A–G, "Issued for production" on week 8 | presentation of the rollout plan, not a product claim |

Keep the copy no stronger than the code. Things the page deliberately does **not** claim, because
the app doesn't enforce them yet: that every step needs proof (only casting and QC do), that
weights are required at each step, that retailers can't see quote internals (the portal
currently fetches `cost_lines(*)` and `margin_pct`), that melee origin is required, that a
goods-in receipt records a vault location, that there is a front-desk role or an accounting
export, that photos are required at goods-in, or that approving a design is one tap (it opens a
confirm dialog). For the same reason the layer table says the
team works from the screens for their role, and only the outside partners are "limited by the
database".

The rule messages are quoted verbatim. If the wording changes, update the matching `.cl-m` in
`index.html`. The outside customer is always the "retailer" (sheet 02 owners, quotes, portal,
admin logins); "client" is used only for the owner of the stone on sheet 04.

Fonts are self-hosted from `assets/fonts/` (latin subsets from Google Fonts, OFL), so the page
makes no third-party requests.

The sample job (`DH-2026-01842`), the client's stone job (`DH-2026-01857`) and the receipt
(`GRN-2026-00184`) are illustrative and labeled "Sample record" on the page.
