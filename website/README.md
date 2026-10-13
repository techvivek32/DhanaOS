# DhanaOS website

The public one-page site for DhanaOS. Plain HTML, CSS and JavaScript with no build step, so it
deploys to Vercel as-is.

```
index.html               the whole page
assets/css/style.css     tokens (D-010) + layout
assets/js/main.js        footer year, copy-email button
assets/favicon.svg       mark
assets/apple-touch-icon.png
assets/og-image.png      1200×630 link preview
vercel.json              security + cache headers
robots.txt, sitemap.xml
```

## Run locally

Open `index.html` in a browser, or:

```bash
npx serve website
```

## Deploy

```bash
cd website
npx vercel          # preview
npx vercel --prod   # production
```

Set the Vercel project's root directory to `website/` if you deploy from the Git integration.

## Before going live

- **Domain.** `https://dhanaos.vercel.app/` is assumed in `index.html` (canonical, Open Graph,
  Twitter), `robots.txt` and `sitemap.xml`. If the project gets a different URL or a custom
  domain, search-and-replace it in those three files.
- **Contact.** The demo button and the copy button both use `info@madvision.tech`. Change it in
  `index.html` (three places: the `mailto:`, the visible address, and `data-copy`), and in the
  JSON-LD block.

## Keeping it accurate

Every claim on the page maps to something in the app or the brief. If one of these changes,
change the page:

| Page says | Source |
|---|---|
| 14 steps and their names | `LifecycleStage` in `lib/domain/enums.dart`, D-002 |
| Four rules + the on-screen messages | `fn_complete_stage`, `fn_dispatch_shipment`, `cad_reviews` CHECK, D-011 |
| Partners see only their jobs, never prices | RLS in `0009_rls.sql`, D-008 |
| Natural / lab-grown always recorded | `stones.origin`, D-012 |
| Goods-in receipt fields, `GRN-…` code, vault location | `goods_in_receipts`, `inventory_items.location` in `0007_inventory.sql` |
| US 6½ = UK M½ = IN 12 | `lib/features/intake/ring_sizes.dart` |
| USD + INR, GST split | `core/money.dart`, D-004 |
| Web admin panel (team, logins, invoice profile, metal rates) | `lib/admin/`, `0014_platform.sql` |
| 8-week rollout, not-included list | the project brief |

The rule messages are quoted verbatim from Postgres. If the wording changes in a migration,
update the matching `.screen-msg` in `index.html`.

The sample job (`DH-2026-01842`) and receipt (`GRN-2026-00184`) are illustrative and labeled
"Sample record" on the page.
