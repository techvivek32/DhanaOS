#!/usr/bin/env node
// DhanaOS generative art: "alloy strata", printed like a risograph.
//
//   node website/tools/gen-art.mjs        writes website/assets/art/*.svg
//
// Every file is deterministic: the only randomness is a seeded PRNG, so re-running the script
// reproduces the committed art byte for byte. Change a seed to pull a new print of the same plate.
//
// The strata files (hero, band, cta) are built the same way:
//   1. Boundaries are sums of seeded sines. The top boundary carries the fold; each lower one is
//      the one above plus a positive, varying thickness, so the layers drape like poured alloy.
//      Each printed edge then gets its own pixel-scale wobble.
//   2. Each boundary is sampled and turned into a Catmull-Rom -> cubic Bezier path. Layer k fills
//      from above the canvas down to boundary k; layers are painted bottom-first, so each one
//      covers everything above its own edge and nothing needs a two-sided outline.
//   3. Per layer: an optional mis-registered ghost (a second ink a few units off), a shadow cast
//      by the layer above (stacked translucent offsets of that layer, broken up by the grain),
//      and engine-turned guilloché lines that follow the band's own contour, each with an offset
//      highlight so the cut reads as a groove catching light.
//   4. Gold hairline seams are drawn last, over the boundaries they solder.
//   5. The print: one cheap grain filter over everything, plus dust specks and ink-starved
//      horizontal streaks as geometry. See "The print" below for why only one filter.
//
// Sizes that should look the same on screen in every file (grain, specks, line weights) are set
// from `px`, the expected CSS pixels per viewBox unit where the page shows that file.

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT = resolve(dirname(fileURLToPath(import.meta.url)), '../assets/art');

// Metal and gem inks.
const C = {
  ink: '#0c121d',
  sapphire: '#2b4a7e',
  sapphireDeep: '#1d3157',
  platinum: '#b7bcc3',
  platinumPale: '#d5d8dc',
  gold: '#d9a640',
  goldDeep: '#b8862f',
  goldHi: '#f2c766',
  bronze: '#9a6a2a',
  rose: '#c77e62',
  bone: '#e9dcc4',
};
// Tones that only ever appear as shadows, cuts and screens of the inks above.
const T = {
  inkDeep: '#070b12',
  goldCut: '#6b4708',
  bronzeShade: '#6e4a1b',
  roseShade: '#a5634a',
  platinumShade: '#939aa4',
  platinumCut: '#6f7782',
};

// ---------------------------------------------------------------------------------------------
// Numbers and paths

/** Seeded PRNG (mulberry32). */
function prng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Coordinates: one decimal, no trailing ".0", no leading "0.". */
function num(v) {
  let r = Math.round(v * 10) / 10;
  if (Object.is(r, -0)) r = 0;
  let s = String(r);
  if (s.startsWith('0.')) s = s.slice(1);
  else if (s.startsWith('-0.')) s = '-' + s.slice(2);
  return s;
}

/** Filter parameters need more precision than coordinates. */
const fx = (v) => String(parseFloat(v.toFixed(4)));

/** Join numbers with the shortest legal separators (a minus sign separates on its own). */
function nums(...vs) {
  let out = '';
  vs.forEach((v, i) => {
    const s = num(v);
    out += i === 0 || s.startsWith('-') ? s : ' ' + s;
  });
  return out;
}

/** Open Catmull-Rom spline through pts, as cubic Bezier segments ("C..." only). */
function catmull(pts) {
  let d = '';
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] || pts[i];
    const p1 = pts[i];
    const p2 = pts[i + 1];
    const p3 = pts[i + 2] || p2;
    d +=
      'C' +
      nums(
        p1[0] + (p2[0] - p0[0]) / 6,
        p1[1] + (p2[1] - p0[1]) / 6,
        p2[0] - (p3[0] - p1[0]) / 6,
        p2[1] - (p3[1] - p1[1]) / 6,
        p2[0],
        p2[1],
      );
  }
  return d;
}

/** Closed Catmull-Rom spline through pts. */
function catmullClosed(pts) {
  const n = pts.length;
  const at = (i) => pts[((i % n) + n) % n];
  let d = 'M' + nums(pts[0][0], pts[0][1]);
  for (let i = 0; i < n; i++) {
    const p0 = at(i - 1);
    const p1 = at(i);
    const p2 = at(i + 1);
    const p3 = at(i + 2);
    d +=
      'C' +
      nums(
        p1[0] + (p2[0] - p0[0]) / 6,
        p1[1] + (p2[1] - p0[1]) / 6,
        p2[0] - (p3[0] - p1[0]) / 6,
        p2[1] - (p3[1] - p1[1]) / 6,
        p2[0],
        p2[1],
      );
  }
  return d + 'Z';
}

/**
 * y = f(x) through `knots` as a C1 cubic chain: one absolute "M", one "c", then relative "s"
 * segments (each reflects the previous control point, which is exactly Hermite continuity).
 * Endpoints are rounded in absolute tenths so the relative deltas never drift.
 */
function hermite(f, knots) {
  const e = 0.01;
  const df = (x) => (f(x + e) - f(x - e)) / (2 * e);
  const T10 = (v) => Math.round(v * 10);
  let X = T10(knots[0]);
  let Y = T10(f(knots[0]));
  let d = 'M' + nums(X / 10, Y / 10);
  for (let i = 1; i < knots.length; i++) {
    const xa = knots[i - 1];
    const xb = knots[i];
    const h = xb - xa;
    const X1 = T10(xb);
    const Y1 = T10(f(xb));
    const cx = X / 10;
    const cy = Y / 10;
    const c2x = xb - h / 3 - cx;
    const c2y = f(xb) - (df(xb) * h) / 3 - cy;
    const dx = (X1 - X) / 10;
    const dy = (Y1 - Y) / 10;
    if (i === 1) {
      const c1x = xa + h / 3 - cx;
      const c1y = f(xa) + (df(xa) * h) / 3 - cy;
      d += 'c' + nums(c1x, c1y, c2x, c2y, dx, dy);
    } else {
      d += 's' + nums(c2x, c2y, dx, dy);
    }
    X = X1;
    Y = Y1;
  }
  return d;
}

/** Sum of seeded sines. Terms are [amplitude, wavelength]; the seed jitters both and the phase. */
function waves(rand, terms) {
  const t = terms.map(([a, l]) => [
    a * (0.8 + 0.4 * rand()),
    (2 * Math.PI) / (l * (0.85 + 0.3 * rand())),
    rand() * 2 * Math.PI,
  ]);
  return (x) => {
    let s = 0;
    for (const [a, w, p] of t) s += a * Math.sin(w * x + p);
    return s;
  };
}

const smoothstep = (a, b, x) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};
const softplus = (v, k) => Math.log1p(Math.exp(k * v)) / k;
const lerp = (a, b, t) => a + (b - a) * t;

// ---------------------------------------------------------------------------------------------
// The print
//
// Cost is the constraint. Many browsers run SVG filters on the CPU, where feTurbulence,
// feDisplacementMap and arithmetic feComposite each cost tens of milliseconds per megapixel, and a
// filter inside a <pattern> is re-run for every repeat of its tile. So the print uses exactly one
// filter: grain, from one stitched noise tile (stitchTiles makes its edges meet) that feTile
// repeats and a soft-light feBlend lays over the art. Both are cheap. Everything else that reads
// as printing (edge wobble, speckle, streaks, screened shadows) is plain geometry made here.

/** Grain over the whole print, tuned to land near one CSS pixel at the size the page shows it. */
function grainFilter({ W, H, px, seed, grain = 1 }) {
  const t = Math.round(240 / px);
  const sub = `x="0" y="0" width="${t}" height="${t}"`;
  const c = 1.2 * grain; // contrast around mid-grey: soft-light leaves 0.5 untouched
  const row = `${fx(c)} 0 0 0 ${fx(0.5 - c / 2)}`;
  return `<filter id="riso" filterUnits="userSpaceOnUse" x="0" y="0" width="${W}" height="${H}" color-interpolation-filters="sRGB">
<feTurbulence ${sub} type="fractalNoise" baseFrequency="${fx(1.37 / px)}" numOctaves="2" seed="${seed}" stitchTiles="stitch"/>
<feColorMatrix ${sub} type="matrix" values="${row} ${row} ${row} 0 0 0 0 1"/>
<feTile/>
<feBlend in2="SourceGraphic" mode="soft-light"/>
</filter>`;
}

/**
 * The riso's accidents: dust specks (light, where the ink missed; dark, where it pooled) and
 * horizontal ink-starved streaks from the drum. Specks are zero-length round-capped strokes, about
 * ten bytes each. Counts and sizes are set in CSS pixels so every file prints alike on screen.
 */
function printMarks({ W, H, px, rand, specks = 1, streaks = 1 }) {
  const area = W * H * px * px;
  const dots = (n) => {
    let d = '';
    for (let i = 0; i < n; i++) d += `M${nums(rand() * W, rand() * H)}h0`;
    return d;
  };
  const speck = (n, sizePx, color, o) =>
    `<path d="${dots(Math.round(n * specks))}" stroke="${color}" stroke-width="${fx(sizePx / px)}" stroke-opacity="${o}"/>`;
  let out = `<g fill="none" stroke-linecap="round">`;
  out += speck(area / 5200, 1.1, C.bone, 0.55);
  out += speck(area / 26000, 1.9, C.bone, 0.45);
  out += speck(area / 9000, 1.3, T.inkDeep, 0.5);
  out += `</g><g fill="url(#sk)">`;
  const n = Math.round(((H * px) / 26) * streaks);
  for (let i = 0; i < n; i++) {
    const w = (140 + rand() * 560) / px;
    const x = rand() * (W + w) - w / 2;
    const y = rand() * H;
    const h = (0.6 + rand() * 1.5) / px;
    out += `<rect x="${num(x)}" y="${num(y)}" width="${num(w)}" height="${num(h)}" opacity="${fx(0.04 + rand() * 0.08)}"/>`;
  }
  return out + '</g>';
}

const streakGradient = `<linearGradient id="sk"><stop offset="0" stop-color="${C.bone}" stop-opacity="0"/><stop offset=".3" stop-color="${C.bone}"/><stop offset=".75" stop-color="${C.bone}"/><stop offset="1" stop-color="${C.bone}" stop-opacity="0"/></linearGradient>`;

// ---------------------------------------------------------------------------------------------
// Strata

/**
 * cfg.top(x)      y of the first boundary, or cfg.center(x) to centre the whole stack on a line.
 * cfg.bands[k]    { color, thick(x), ghost, shadow, guilloche, seam }. Band 0 is the field above
 *                 the first boundary and has no thickness. cfg.floor fills below the last one.
 */
function strata(cfg) {
  const { W, H, px, step, pad = 70 } = cfg;
  const xs = [];
  for (let x = -pad; x <= W + pad + 0.01; x += step) xs.push(x);

  const n = cfg.bands.length; // boundary k is the bottom edge of band k
  const thick = cfg.bands.map((b) => b.thick || (() => 0));
  const total = (x) => {
    let s = 0;
    for (let k = 1; k < n; k++) s += thick[k](x);
    return s;
  };
  const drape = [cfg.top || ((x) => cfg.center(x) - total(x) / 2)];
  for (let k = 1; k < n; k++) {
    const prev = drape[k - 1];
    const t = thick[k];
    drape[k] = (x) => prev(x) + t(x);
  }
  // Each printed edge then gets its own slight wobble, about a CSS pixel, as an ink edge would.
  // Wavelengths stay at four samples or more so the spline follows them.
  const wr = prng(cfg.wobbleSeed);
  const bnd = drape.map((f) => {
    const w = waves(wr, [
      [0.9 / px, Math.max(230, step * 6)],
      [0.6 / px, Math.max(130, step * 4)],
    ]);
    return (x) => f(x) + w(x);
  });

  // a{k}: everything above boundary k. Its other three edges sit outside the canvas, so the same
  // path also strokes as a seam along the boundary alone.
  const defs = [];
  for (let k = 0; k < n; k++) {
    const pts = xs.map((x) => [x, bnd[k](x)]);
    defs.push(
      `<path id="a${k}" d="M${nums(-pad, -pad)}L${nums(pts[0][0], pts[0][1])}${catmull(pts)}L${nums(W + pad, -pad)}Z"/>`,
    );
  }
  // Thinnest point of each band on the canvas. A shadow or a cut that stays inside its band needs
  // no clip path, and clip paths are the dearest thing left to rasterise.
  const minThick = bnd.map((f, k) => {
    let m = Infinity;
    if (k > 0) for (let x = 0; x <= W; x += 4) m = Math.min(m, f(x) - bnd[k - 1](x));
    return m;
  });
  const clips = new Set();

  // A cast shadow: the layer above, shifted down in five steps of a translucent ink. The steps
  // stack, so the shadow is densest at the boundary and fades with distance; the grain breaks the
  // steps into a printed screen.
  const SHADOW_STEPS = 5;
  const shadow = (aboveK, s, clipK) => {
    const needClip = clipK !== null && s.depth > minThick[clipK] - 1;
    if (needClip) clips.add(clipK);
    const clip = needClip ? ` clip-path="url(#k${clipK})"` : '';
    const o = 1 - Math.pow(1 - (s.strength ?? 0.72), 1 / SHADOW_STEPS);
    let uses = '';
    for (let i = SHADOW_STEPS; i >= 1; i--) uses += `<use href="#a${aboveK}" y="${num((s.depth * i) / SHADOW_STEPS)}"/>`;
    return `<g${clip} fill="${s.color}" fill-opacity="${fx(o)}">${uses}</g>`;
  };

  const body = [`<rect width="${W}" height="${H}" fill="${cfg.floor}"/>`];
  if (cfg.floorShadow) body.push(shadow(n - 1, cfg.floorShadow, null));

  for (let k = n - 1; k >= 0; k--) {
    const b = cfg.bands[k];
    let out = '';
    if (b.ghost) {
      const g = b.ghost;
      out += `<use href="#a${k}" x="${num(g.dx)}" y="${num(g.dy)}" fill="${g.color}"/>`;
    }
    out += `<use href="#a${k}" fill="${b.color}"/>`;
    if (b.guilloche && k > 0) out += guillocheBand(cfg, b.guilloche, bnd[k - 1], bnd[k], k, minThick[k], clips);
    if (b.shadow && k > 0) out += shadow(k - 1, b.shadow, k);
    body.push(out);
  }

  // Seams over everything: hairline solder lines along chosen boundaries.
  let seams = '';
  cfg.bands.forEach((b, k) => {
    if (!b.seam) return;
    const s = b.seam;
    const op = s.opacity ? ` stroke-opacity="${s.opacity}"` : '';
    seams += `<use href="#a${k}" fill="none" stroke="${s.color}" stroke-width="${num(s.width)}"${op}/>`;
    if (s.double) {
      seams += `<use href="#a${k}" y="${num(s.double)}" fill="none" stroke="${s.color}" stroke-width="${num(s.width * 0.6)}" stroke-opacity=".55"/>`;
    }
  });
  body.push(seams);

  for (const k of clips) defs.push(`<clipPath id="k${k}"><use href="#a${k}"/></clipPath>`);
  return { defs: defs.join('\n'), body: body.join('\n'), bnd };
}

/**
 * Engine-turned lines that follow a band's contour (like flow lines in rolled stock), with a
 * phase step per line so the ripples line up into diagonal ridges. `hi` adds the same cut again,
 * offset and in a light ink, as the lit lip of each groove.
 */
function guillocheBand(cfg, g, upper, lower, k, minThick, clips) {
  const { W, pad = 70 } = cfg;
  const w = (2 * Math.PI) / g.lambda;
  const ampEnv = g.ampEnv || (() => 1);
  // Stop the last cut a fixed margin above the band's lower edge, so no clip path is needed. The
  // top needs none either way: the layer above is painted later and covers any overshoot.
  const margin = g.amp + g.width + (g.hi ? g.hi.dy : 0) + 1;
  const clip = minThick < margin * 4;
  if (clip) clips.add(k);
  const floor = clip ? lower : (x) => lower(x) - margin;
  let paths = '';
  for (let j = 0; j < g.lines; j++) {
    const t = lerp(g.from ?? -0.04, clip ? 1.04 : 1, (j + 0.5) / g.lines);
    const phase = j * g.delta;
    const f = (x) => lerp(upper(x), floor(x), t) + g.amp * ampEnv(x, t) * Math.cos(w * x + phase);
    // Break at the ripple's extrema so each cubic spans half a wavelength.
    const x1 = W + pad / 2;
    let m = Math.floor(((-pad / 2) * w + phase) / Math.PI);
    const knots = [];
    for (;; m++) {
      const x = (m * Math.PI - phase) / w;
      knots.push(x);
      if (x > x1) break;
    }
    paths += `<path d="${hermite(f, knots)}"/>`;
  }
  const id = `g${k}`;
  let out = `<g${clip ? ` clip-path="url(#k${k})"` : ''} fill="none" stroke-width="${num(g.width)}">`;
  out += `<g id="${id}" stroke="${g.color}" stroke-opacity="${g.opacity}">${paths}</g>`;
  if (g.hi) {
    out += `<use href="#${id}" y="${num(g.hi.dy)}" stroke="${g.hi.color}" stroke-opacity="${g.hi.opacity}"/>`;
  }
  return out + '</g>';
}

/** The gold band's cut: the same engine settings everywhere, line weight set for screen size. */
function goldTurn(px, lines, extra = {}) {
  return {
    lines,
    lambda: 56,
    amp: 3.4,
    delta: 0.42,
    color: T.goldCut,
    width: 0.95 / px,
    opacity: 0.55,
    ampEnv: (x, t) => 0.55 + 0.45 * Math.sin(x / 160 + t * 4),
    hi: { dy: 1.1 / px, color: C.goldHi, opacity: 0.5 },
    ...extra,
  };
}

function print({ W, H, px, seeds, bands, top, center, step, riso = {} }) {
  const floorShadow = { color: T.inkDeep, depth: 50 };
  const s = strata({ W, H, px, step, bands, top, center, floor: C.ink, floorShadow, wobbleSeed: seeds[1] });
  const marks = printMarks({ W, H, px, rand: prng(seeds[1] + 7), ...riso });
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid slice">
<defs>
${grainFilter({ W, H, px, seed: seeds[0], ...riso })}
${streakGradient}
${s.defs}
</defs>
<g filter="url(#riso)">
${s.body}
${marks}
</g>
</svg>
`;
}

// Thickness profiles. `th` is log-normal so a band never vanishes; `lens` can pinch to nothing.
const thickness = (r, env = () => 1) => ({
  th: (mean, terms) => {
    const v = waves(r, terms);
    return (x) => mean * env(x) * Math.exp(v(x));
  },
  lens: (mean, terms, bias) => {
    const v = waves(r, terms);
    return (x) => mean * env(x) * softplus(bias + v(x), 6);
  },
});

// ---------------------------------------------------------------------------------------------
// 1. Hero: portrait. The crest rises to the upper right; a ticket card covers the lower left.

function hero() {
  const W = 1000;
  const H = 1250;
  const px = 0.6;
  const r = prng(1407);
  const fold = waves(r, [
    [16, 640],
    [6, 300],
  ]);
  const lift = 84; // room for the hairline course above the stock
  const top = (x) => 330 - lift - 250 * smoothstep(-60, 760, x) + 70 * smoothstep(720, 1160, x) + fold(x);
  const { th, lens } = thickness(r);
  const acc = thickness(prng(1408)).th;

  const bands = [
    { color: C.ink },
    { color: C.platinum, thick: acc(6, [[0.3, 700]]) },
    { color: C.ink, thick: (x) => lift - 6, shadow: { color: T.inkDeep, depth: 14 } },
    { color: C.sapphireDeep, thick: th(70, [[0.3, 800], [0.1, 330]]), shadow: { color: C.ink, depth: 16 } },
    {
      color: C.sapphire,
      thick: th(92, [[0.28, 700], [0.08, 300]]),
      shadow: { color: C.sapphireDeep, depth: 18 },
    },
    { color: C.platinumPale, thick: th(15, [[0.35, 600], [0.12, 260]]), seam: { color: C.goldHi, width: 1.7 } },
    {
      color: C.platinum,
      thick: th(44, [[0.3, 650], [0.1, 280]]),
      shadow: { color: T.platinumShade, depth: 18 },
      guilloche: { lines: 5, lambda: 52, amp: 1.8, delta: 0.6, color: T.platinumCut, width: 1.5, opacity: 0.32 },
    },
    { color: C.rose, thick: lens(10, [[1, 700], [0.35, 300]], 0.35), ghost: { dx: 6, dy: 5, color: C.bronze } },
    {
      color: C.gold,
      thick: th(250, [[0.2, 900], [0.08, 380]]),
      shadow: { color: C.goldDeep, depth: 40 },
      guilloche: goldTurn(px, 30),
      seam: { color: C.goldHi, width: 1.7, double: 5 },
    },
    { color: C.goldDeep, thick: th(20, [[0.35, 600], [0.12, 260]]) },
    {
      color: C.bronze,
      thick: th(32, [[0.35, 700], [0.12, 300]]),
      shadow: { color: T.bronzeShade, depth: 14 },
      seam: { color: C.goldHi, width: 1.2, opacity: 0.75 },
    },
    {
      color: C.sapphire,
      thick: th(112, [[0.25, 760], [0.08, 320]]),
      shadow: { color: C.sapphireDeep, depth: 34 },
      ghost: { dx: -5, dy: 5, color: C.rose },
    },
    { color: C.platinum, thick: th(18, [[0.35, 600], [0.12, 260]]), seam: { color: C.goldHi, width: 1.2, opacity: 0.7 } },
    { color: C.sapphireDeep, thick: th(160, [[0.25, 800]]), shadow: { color: C.ink, depth: 44 } },
  ];

  return print({ W, H, px, seeds: [21, 9], bands, top, step: 25 });
}

// ---------------------------------------------------------------------------------------------
// 2. Band: full-bleed section ground. A dark card covers the centre, so the stock is pinched a
//    little behind it and swells toward both edges, where the folds are strongest.

function band() {
  const W = 1600;
  const H = 1000;
  const px = 0.9;
  const r = prng(52031);
  const env = (x) => 0.8 + 0.2 * Math.pow(Math.abs((x - W / 2) / (W / 2)), 1.6);
  const edge = (x) => Math.pow(Math.abs((x - W / 2) / (W / 2)), 1.4);
  const swell = waves(r, [
    [30, 1300],
    [12, 520],
  ]);
  const center = (x) => 500 + swell(x) * (0.3 + edge(x)) - 70 * Math.sin((x / W) * Math.PI * 2 - 0.3) * edge(x);
  const { th } = thickness(r, env);
  const acc = thickness(prng(52032), env).th;

  const bands = [
    { color: C.ink },
    { color: C.sapphireDeep, thick: acc(100, [[0.25, 900]]), shadow: { color: C.ink, depth: 20 } },
    { color: C.platinumPale, thick: acc(7, [[0.35, 700]]), seam: { color: C.goldHi, width: 1.1, opacity: 0.8 } },
    { color: C.sapphireDeep, thick: th(130, [[0.25, 900], [0.08, 400]]), shadow: { color: C.ink, depth: 22 } },
    {
      color: C.platinum,
      thick: th(18, [[0.35, 700], [0.12, 300]]),
      seam: { color: C.goldHi, width: 1.3 },
      ghost: { dx: 6, dy: 5, color: C.rose },
    },
    {
      color: C.sapphire,
      thick: th(110, [[0.25, 800], [0.1, 350]]),
      shadow: { color: C.sapphireDeep, depth: 26 },
    },
    { color: C.goldDeep, thick: th(14, [[0.4, 600], [0.12, 300]]), seam: { color: C.goldHi, width: 1.2 } },
    {
      color: C.gold,
      thick: th(190, [[0.22, 1000], [0.08, 420]]),
      shadow: { color: C.goldDeep, depth: 34 },
      guilloche: goldTurn(px, 24),
    },
    { color: C.bronze, thick: th(30, [[0.35, 700], [0.12, 300]]), shadow: { color: T.bronzeShade, depth: 12 } },
    {
      color: C.rose,
      thick: th(10, [[0.5, 700], [0.2, 300]]),
      seam: { color: C.goldHi, width: 1.2, double: 5, opacity: 0.85 },
    },
    {
      color: C.platinumPale,
      thick: th(56, [[0.3, 800], [0.1, 340]]),
      shadow: { color: '#a8aeb6', depth: 18 },
      guilloche: { lines: 7, lambda: 52, amp: 1.8, delta: 0.6, color: T.platinumCut, width: 1, opacity: 0.32 },
    },
    { color: C.platinum, thick: th(22, [[0.35, 700], [0.12, 300]]) },
    {
      color: C.sapphire,
      thick: th(120, [[0.25, 900], [0.1, 380]]),
      shadow: { color: C.sapphireDeep, depth: 30 },
      ghost: { dx: -6, dy: 5, color: C.bronze },
    },
    { color: C.sapphireDeep, thick: th(150, [[0.25, 900]]), shadow: { color: C.ink, depth: 36 } },
    { color: C.goldDeep, thick: acc(6, [[0.35, 700]]), seam: { color: C.goldHi, width: 1.1, opacity: 0.8 } },
    { color: C.sapphireDeep, thick: acc(110, [[0.25, 900]]), shadow: { color: C.ink, depth: 30 } },
  ];

  return print({ W, H, px, seeds: [61, 17], bands, center, step: 40 });
}

// ---------------------------------------------------------------------------------------------
// 3. CTA: the stock rises diagonally, left to right. A cream card sits centre-left.

function cta() {
  const W = 1600;
  const H = 900;
  const px = 0.9;
  const r = prng(90210);
  const sway = waves(r, [
    [22, 1100],
    [9, 480],
  ]);
  const center = (x) => 470 - 0.36 * (x - W / 2) + sway(x) + 40 * Math.sin((x / W) * Math.PI * 1.6 + 0.8);
  const { th } = thickness(r);

  const bands = [
    { color: C.ink },
    { color: C.sapphireDeep, thick: th(110, [[0.25, 900], [0.08, 400]]), shadow: { color: C.ink, depth: 20 } },
    { color: C.sapphire, thick: th(100, [[0.25, 800], [0.1, 340]]), shadow: { color: C.sapphireDeep, depth: 22 } },
    {
      color: C.platinumPale,
      thick: th(18, [[0.35, 700], [0.12, 300]]),
      seam: { color: C.goldHi, width: 1.3 },
      ghost: { dx: 6, dy: 5, color: C.rose },
    },
    { color: C.platinum, thick: th(40, [[0.3, 700], [0.1, 300]]), shadow: { color: T.platinumShade, depth: 14 } },
    {
      color: C.gold,
      thick: th(200, [[0.2, 1000], [0.08, 420]]),
      shadow: { color: C.goldDeep, depth: 34 },
      guilloche: goldTurn(px, 26),
      seam: { color: C.goldHi, width: 1.4, double: 5 },
    },
    { color: C.rose, thick: th(30, [[0.4, 700], [0.12, 300]]), shadow: { color: T.roseShade, depth: 12 } },
    {
      color: C.bronze,
      thick: th(26, [[0.4, 700], [0.12, 300]]),
      seam: { color: C.goldHi, width: 1.1, opacity: 0.7 },
    },
    { color: C.sapphire, thick: th(120, [[0.25, 900], [0.1, 380]]), shadow: { color: C.sapphireDeep, depth: 30 } },
    { color: C.platinum, thick: th(16, [[0.4, 600], [0.12, 300]]), ghost: { dx: -5, dy: 5, color: C.bronze } },
    { color: C.sapphireDeep, thick: th(170, [[0.25, 900]]), shadow: { color: C.ink, depth: 36 } },
  ];

  return print({ W, H, px, seeds: [73, 29], bands, center, step: 40 });
}

// ---------------------------------------------------------------------------------------------
// 4. Rosette: a guilloché medallion. Each family is one base curve plus rotated <use> copies,
//    which is how a rose engine cuts it: one cam, indexed round the dial a fraction of a lobe
//    at a time, so neighbouring cuts cross into a lattice.

function rosette() {
  const S = 600;
  const c = S / 2;
  const polar = (rf, samples) => {
    const pts = [];
    for (let i = 0; i < samples; i++) {
      const t = (i / samples) * Math.PI * 2;
      const rr = rf(t);
      pts.push([c + rr * Math.cos(t), c + rr * Math.sin(t)]);
    }
    return catmullClosed(pts);
  };
  const op = (o) => (o < 1 ? ` stroke-opacity="${o}"` : '');
  const ring = (rad, w, o = 1) => `<circle cx="${c}" cy="${c}" r="${num(rad)}" stroke-width="${fx(w)}"${op(o)}/>`;
  // A family: `lobes` lobes per turn, radius = shape(u) with u = 0 at a lobe's crown, cut
  // `copies` times across `spread` of one lobe. A full spread braids into an even lattice; a
  // partial one keeps each lobe as a distinct fan, centred so a fan stands at twelve o'clock.
  const fam = (id, shape, lobes, perLobe, copies, spread, w, o) => {
    const lobe = (2 * Math.PI) / lobes;
    const t0 = -Math.PI / 2 - (spread < 1 ? (lobe * spread) / 2 : 0);
    const d = polar((t) => shape(lobes * (t - t0)), lobes * perLobe);
    let out = `<g stroke-width="${fx(w)}"${op(o)}><path id="${id}" d="${d}"/>`;
    const step = (360 / lobes) * (spread / (spread === 1 ? copies : copies - 1));
    for (let i = 1; i < copies; i++) {
      out += `<use href="#${id}" transform="rotate(${fx(step * i)} ${c} ${c})"/>`;
    }
    return out + '</g>';
  };
  const cos = Math.cos;

  const parts = [
    // Rim: a heavier bezel line so the medallion holds its edge at 48px.
    ring(294, 2.6),
    ring(288.5, 0.7, 0.8),
    // Rope: a 36-lobe wave cut six times across a whole lobe, braided.
    fam('o', (u) => 269 + 12 * cos(u), 36, 12, 6, 1, 0.75, 0.85),
    ring(250, 1.5),
    ring(246, 0.6, 0.8),
    // Field: twelve petals fanned from twelve cuts, with a shallower set standing between them.
    fam('p', (u) => 168 + 66 * cos(u), 12, 20, 12, 0.32, 0.65, 0.8),
    fam('s', (u) => 160 - 46 * cos(u), 12, 20, 8, 0.28, 0.55, 0.6),
    // Collar: a fine wave ring at the petals' roots.
    fam('q', (u) => 100 + 6 * cos(u), 30, 10, 5, 1, 0.6, 0.8),
    ring(89, 1.3),
    ring(85.5, 0.5, 0.8),
    // Boss: an eight-lobe flower fanned from eight cuts, and a centre pin.
    fam('m', (u) => 50 + 26 * cos(u), 8, 18, 8, 0.4, 0.6, 0.85),
    ring(20, 1.1),
    ring(6, 1.8),
  ];

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${S} ${S}">
<g fill="none" stroke="${C.gold}" stroke-linejoin="round">
${parts.join('\n')}
</g>
</svg>
`;
}

// ---------------------------------------------------------------------------------------------
// 5. Engraving tiles: engine-turned waves that repeat in both directions without a seam.
//    Horizontally every term's period divides the tile width. Vertically the per-line phase step
//    is a whole number of turns over the lines in one tile, so line j + N is line j moved down
//    exactly one tile.

function engrave(stroke) {
  const W = 240;
  const H = 120;
  const N = 24; // lines per tile, 5 units apart
  const gap = H / N;
  const lam = 60; // four waves across the tile
  const turn = 2 * Math.PI;
  const knots = [];
  for (let x = -lam / 2; x <= W + lam / 2 + 0.01; x += lam / 4) knots.push(x);
  let paths = '';
  for (let j = -3; j < N + 3; j++) {
    // Ripple phase steps three turns per tile, so the crests line up into a slow diagonal; the
    // ripple's depth swells and thins once across the tile, as a rose engine's cam would.
    const f = (x) =>
      j * gap +
      1.7 *
        (0.7 + 0.3 * Math.cos((turn * x) / W + (turn * j) / N)) *
        Math.sin((turn * x) / lam + (turn * 3 * j) / N) +
      1.2 * Math.sin((turn * x) / W);
    paths += `<path d="${hermite(f, knots)}"/>`;
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
<g fill="none" stroke="${stroke}" stroke-width=".7">${paths}</g>
</svg>
`;
}

// ---------------------------------------------------------------------------------------------

function write(name, svg) {
  mkdirSync(OUT, { recursive: true });
  writeFileSync(resolve(OUT, name), svg);
  console.log(`${name.padEnd(18)} ${(Buffer.byteLength(svg) / 1024).toFixed(1).padStart(6)} KB`);
}

write('hero.svg', hero());
write('band.svg', band());
write('cta.svg', cta());
write('rosette.svg', rosette());
write('engrave-dark.svg', engrave('rgba(217,166,64,.18)'));
write('engrave-light.svg', engrave('rgba(23,20,15,.10)'));
