"""Regenerates the line drawings inside index.html.

index.html is the real page and is edited by hand. This script only rewrites the blocks
between <!-- gen:NAME --> and <!-- /gen:NAME --> markers, so the geometry stays honest:
the top, front and side views of the sample ring share one scale and one set of
projection lines, and every claw in one view appears in the others.

    python tools/drawings.py

Nothing in tools/ is deployed (see .vercelignore).
"""
import math
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAGE = ROOT / "index.html"


def n(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def polar(cx, cy, r, deg):
    a = math.radians(deg)
    return (cx + r * math.cos(a), cy - r * math.sin(a))


def P(p):
    return f"{n(p[0])},{n(p[1])}"


def pct(v, total):
    return f"{v / total * 100:.3f}".rstrip("0").rstrip(".") + "%"


# --------------------------------------------------------------------------- shared shapes

def facets(cx, cy, R, rt=0.59, rs=0.79):
    """Round brilliant crown seen from above: table, star facets, upper-girdle facets."""
    V = [polar(cx, cy, R * rt, k * 45) for k in range(8)]
    S = [polar(cx, cy, R * rs, 22.5 + k * 45) for k in range(8)]
    Gd = [polar(cx, cy, R, k * 45) for k in range(8)]
    H = [polar(cx, cy, R, 22.5 + k * 45) for k in range(8)]
    table = "M" + " L".join(P(p) for p in V) + " Z"
    stars, kites = [], []
    for k in range(8):
        k1 = (k + 1) % 8
        stars.append(f"M{P(V[k])} L{P(S[k])} L{P(V[k1])}")
        kites.append(f"M{P(Gd[k])} L{P(S[k])} L{P(Gd[k1])} M{P(S[k])} L{P(H[k])}")
    return table, " ".join(stars), " ".join(kites)


def hatch(x0, y0, x1, y1, step=5.0):
    """45-degree section lines covering a box (clip them to the section outline)."""
    d, w, h = [], x1 - x0, y1 - y0
    k = -h
    while k < w:
        d.append(f"M{n(x0 + k)},{n(y1)} L{n(x0 + k + h)},{n(y0)}")
        k += step
    return " ".join(d)


def dr(cls, d0, t, body, extra=""):
    """A stroke that draws itself on (pathLength=1 + dash animation in CSS)."""
    return f'<path class="{cls} dr" style="--d:{d0:.2f}s;--t:{t:.2f}s" pathLength="1" d="{body}"{extra}/>'


# --------------------------------------------------------------------------- hero drawing

W, H = 880, 600
CX, TY, FY, SX = 300, 105, 420, 610        # top + front views share CX; side view at SX
RO, RI = 132, 110                           # band: 16.92 mm inside diameter at 13 px/mm
G = 56                                      # stone girdle radius (2.40 ct is about 8.6 mm)
YT, YGT, YGB, YC = 199, 216, 220, 268       # table, girdle top/bottom, culet
COL_T, COL_B, COL_W, COL_BW = 279, 292, 33, 20   # head seat: a short cone that sits on the shank
RAIL_T, RAIL_B, RAIL_W = 243, 250, 49       # gallery rail
BAND_TOP, BAND_BOT = 16, 12                 # band half-width at the top and bottom (side view)
SECX, SECY = 792, 498                       # Section A-A, drawn at 2:1
CLAWS = [0, 60, 120, 180, 240, 300]         # six claws; 0 deg points along +x


def stone_elev(cx):
    outline = (f"M{cx-32},{YT} H{cx+32} L{cx+G},{YGT} V{YGB} L{cx},{YC} "
               f"L{cx-G},{YGB} V{YGT} Z")
    girdle = f"M{cx-G},{YGT} H{cx+G}"
    crown_pts = [(-44, YGT), (-32, YT), (-22, YGT), (-12, YT), (0, YGT), (12, YT), (22, YGT), (32, YT), (44, YGT)]
    crown = "M" + " L".join(f"{cx+x},{y}" for x, y in crown_pts)
    pav = " ".join(f"M{cx+x},{YGB} L{cx},{YC}" for x in (-38, -16, 16, 38))
    return outline, girdle, crown, pav


def claw_edge(cx, s):
    """A claw on the silhouette: rises from the collar, grips the girdle, tips over the crown."""
    pts = [(24, 281), (31, 262), (49, 240), (55.5, 222), (55.5, 216), (47.5, 210),
           (47, 204.5), (52, 203.5), (60, 204.5), (62.5, 212), (63, 222),
           (58, 240), (41, 262), (32, 281)]
    X = lambda i: n(cx + s * pts[i][0])
    Y = lambda i: n(pts[i][1])
    return (f"M{X(0)},{Y(0)} C{X(1)},{Y(1)} {X(2)},{Y(2)} {X(3)},{Y(3)} L{X(4)},{Y(4)} L{X(5)},{Y(5)} "
            f"Q{X(6)},{Y(6)} {X(7)},{Y(7)} Q{X(8)},{Y(8)} {X(9)},{Y(9)} L{X(10)},{Y(10)} "
            f"C{X(11)},{Y(11)} {X(12)},{Y(12)} {X(13)},{Y(13)} Z")


def claw_face(cx, s, base, girdle, tip, w=4.0):
    """A claw seen roughly face-on, in front of the stone: a tapered strip with a rounded tip."""
    bx, gx, tx = base, girdle, tip
    pts = [(bx - w + .8, 281), (bx - w + 2, 262), (gx - w - 3, 240), (gx - w, 221),
           (tx - w + .5, 211), (tx - w + .8, 203.8), (tx + .5, 203.6), (tx + w + 1.5, 204.6), (gx + w, 213),
           (gx + w, 221), (gx + w - 3, 240), (bx + w + 2, 262), (bx + w - .8, 281)]
    X = lambda i: n(cx + s * pts[i][0])
    Y = lambda i: n(pts[i][1])
    return (f"M{X(0)},{Y(0)} C{X(1)},{Y(1)} {X(2)},{Y(2)} {X(3)},{Y(3)} L{X(4)},{Y(4)} "
            f"Q{X(5)},{Y(5)} {X(6)},{Y(6)} Q{X(7)},{Y(7)} {X(8)},{Y(8)} L{X(9)},{Y(9)} "
            f"C{X(10)},{Y(10)} {X(11)},{Y(11)} {X(12)},{Y(12)} Z")


def head(cx, claws, d0):
    """Collar, stone in elevation, gallery rail, then the visible claws on top."""
    outline, girdle, crown, pav = stone_elev(cx)
    out = [
        dr("ln fillp", d0, .5, f"M{cx-COL_W},{COL_T+1.5} Q{cx-COL_W},{COL_T} {cx-COL_W+1.5},{COL_T} H{cx+COL_W-1.5} "
                               f"Q{cx+COL_W},{COL_T} {cx+COL_W},{COL_T+1.5} L{cx+COL_BW},{COL_B} H{cx-COL_BW} Z"),
        dr("ln fillp", d0 + .1, .9, outline),
        dr("th", d0 + .4, .5, girdle),
        dr("th", d0 + .5, .8, crown),
        dr("th", d0 + .6, .8, pav),
        dr("ln fillp", d0 + .7, .6, f"M{cx-RAIL_W},{RAIL_T} H{cx+RAIL_W} V{RAIL_B} H{cx-RAIL_W} Z"),
    ]
    for i, d in enumerate(claws):
        out.append(dr("ln fillp", d0 + .8 + i * .07, .7, d))
    return "\n".join(out)


def hero():
    s = []
    s.append(f'<svg class="ga" viewBox="0 0 {W} {H}" aria-hidden="true" focusable="false">')
    s.append(f"""<defs>
  <marker id="h-ar" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="9" markerHeight="9" markerUnits="userSpaceOnUse" orient="auto-start-reverse"><path d="M0,1.8 L10,5 L0,8.2 z" class="ar-fill"/></marker>
  <clipPath id="h-sec"><path d="{section_path()}"/></clipPath>
  <clipPath id="h-pour"><rect x="{CX-RO-2}" y="{FY+RO+2}" width="{2*RO+4}" height="0">
    <animate attributeName="y" values="{FY+RO+2};{FY-RO-2}" begin="1.25s" dur="1.2s" fill="freeze" calcMode="spline" keyTimes="0;1" keySplines=".45 0 .2 1"/>
    <animate attributeName="height" values="0;{2*RO+4}" begin="1.25s" dur="1.2s" fill="freeze" calcMode="spline" keyTimes="0;1" keySplines=".45 0 .2 1"/>
  </rect></clipPath>
  <linearGradient id="h-heat" gradientUnits="userSpaceOnUse" x1="0" y1="{FY+RO}" x2="0" y2="{FY-RO}">
    <stop offset="0" stop-color="#FF5A1F" stop-opacity=".82"/><stop offset=".5" stop-color="#FF5A1F" stop-opacity=".46"/><stop offset="1" stop-color="#FF5A1F" stop-opacity=".14"/>
  </linearGradient>
</defs>""")

    # centre lines (non-photo blue chain lines) -----------------------------------
    s.append('<g class="cl fade" style="--d:.05s">')
    s.append(f'<path d="M{CX-150},{TY} H{CX+150} M{CX},{TY-74} V{TY+74}"/>')
    s.append(f'<path d="M{CX-154},{FY} H{CX-114} M{CX+114},{FY} H{CX+154} M{CX},{YT-10} V514"/>')
    s.append(f'<path d="M{SX},{YT-10} V572 M{SX-34},{FY} H{SX+34}"/>')
    s.append(f'<path d="M{SECX-38},{SECY} H{SECX+38} M{SECX},{SECY-36} V{SECY+32}"/>')
    s.append('</g>')

    # projection lines ---------------------------------------------------------------
    s.append('<g class="pj">')
    half = G * math.cos(math.radians(60))
    pj = [
        f"M{CX-G},{TY+22} V{YGT-8}", f"M{CX+G},{TY+22} V{YGT-8}",
        f"M{n(CX-half)},{TY+56} V{YT-2}", f"M{n(CX+half)},{TY+56} V{YT-2}",
        f"M{CX-RO},{TY+22} V{FY-8}", f"M{CX+RO},{TY+22} V{FY-8}",
        f"M{CX+64},{YT} H{SX-64}", f"M{CX+60},{COL_B} H{SX-32}",
        f"M{CX+24},{FY+RO} H{SX-20}",
    ]
    for i, d in enumerate(pj):
        cls = "pj-s" if i >= 6 else "pj-v"
        s.append(dr(cls, .15 + i * .05, .9, d))
    s.append('</g>')

    # TOP VIEW -----------------------------------------------------------------------
    table, stars, kites = facets(CX, TY, G)
    s.append('<g class="view top">')
    s.append(dr("ln", .3, 1.0, f"M{CX-RO},{TY-BAND_TOP} H{CX+RO} V{TY+BAND_TOP} H{CX-RO} Z"))
    s.append(f'<path class="hid fade" style="--d:1.2s" d="M{CX-RI},{TY-BAND_TOP} V{TY+BAND_TOP} M{CX+RI},{TY-BAND_TOP} V{TY+BAND_TOP}"/>')
    s.append(f'<circle class="ln fillp dr" style="--d:.45s;--t:.9s" pathLength="1" cx="{CX}" cy="{TY}" r="{G}"/>')
    s.append(dr("ln", .8, .7, table))
    s.append(dr("th", 1.0, 1.1, stars))
    s.append(dr("th", 1.15, 1.3, kites))
    for k, a in enumerate(CLAWS):
        px, py = polar(CX, TY, G - 2.5, a)
        s.append(f'<ellipse class="ln fillp dr" style="--d:{1.3+k*.05:.2f}s;--t:.4s" pathLength="1" '
                 f'cx="{n(px)}" cy="{n(py)}" rx="6.5" ry="4.2" transform="rotate({-a} {n(px)} {n(py)})"/>')
    s.append('</g>')

    # FRONT VIEW ---------------------------------------------------------------------
    ann = (f"M{CX-RO},{FY} a{RO},{RO} 0 1 0 {2*RO},0 a{RO},{RO} 0 1 0 {-2*RO},0 Z "
           f"M{CX-RI},{FY} a{RI},{RI} 0 1 0 {2*RI},0 a{RI},{RI} 0 1 0 {-2*RI},0 Z")
    s.append('<g class="view front">')
    # the job is at casting: metal pours up from the sprue end once, then cools away
    s.append(f'<path class="melt" clip-path="url(#h-pour)" fill-rule="evenodd" d="{ann}"/>')
    s.append(f'<circle class="ln dr" style="--d:.25s;--t:1.2s" pathLength="1" cx="{CX}" cy="{FY}" r="{RO}"/>')
    s.append(f'<circle class="ln dr" style="--d:.4s;--t:1.2s" pathLength="1" cx="{CX}" cy="{FY}" r="{RI}"/>')
    s.append(f'<circle class="xt dr" style="--d:.7s;--t:1.2s" pathLength="1" cx="{CX}" cy="{FY}" r="{RO-3.5}"/>')
    s.append(f'<circle class="xt dr" style="--d:.8s;--t:1.2s" pathLength="1" cx="{CX}" cy="{FY}" r="{RI+3}"/>')
    # visible claws from the front: the two on the silhouette (0, 180 deg) and the near
    # pair at 240/300 deg, which sit at x = +-G/2. The far pair hides exactly behind them.
    front_claws = [claw_edge(CX, -1), claw_edge(CX, 1),
                   claw_face(CX, -1, 14, 29.5, 23.75), claw_face(CX, 1, 14, 29.5, 23.75)]
    s.append(head(CX, front_claws, .55))
    s.append('</g>')

    # SIDE VIEW ----------------------------------------------------------------------
    s.append('<g class="view side">')
    s.append(dr("ln fillp", .5, 1.1, f"M{SX-BAND_TOP},{FY-RO+2} H{SX+BAND_TOP} L{SX+BAND_BOT},{FY+RO} H{SX-BAND_BOT} Z"))
    hw = lambda y: BAND_TOP - (BAND_TOP - BAND_BOT) * (y - (FY - RO)) / (2 * RO)
    s.append(f'<path class="hid fade" style="--d:1.4s" d="M{n(SX-hw(FY-RI)+1)},{FY-RI} H{n(SX+hw(FY-RI)-1)} '
             f'M{n(SX-hw(FY+RI)+1)},{FY+RI} H{n(SX+hw(FY+RI)-1)}"/>')
    # from the side: the claw at 0 deg faces the viewer at the centre, the 60/300 deg pair
    # sits at +-0.866 of each radius. The other three hide behind them.
    c = math.cos(math.radians(30))
    side_claws = [claw_face(SX, -1, 28 * c, 59 * c, 47.5 * c), claw_face(SX, 1, 28 * c, 59 * c, 47.5 * c),
                  f"M{SX-4},{COL_T+2} L{SX-4.4},211 Q{SX-4.4},203.6 {SX},203.6 Q{SX+4.4},203.6 {SX+4.4},211 L{SX+4},{COL_T+2} Z"]
    s.append(head(SX, side_claws, .75))
    s.append('</g>')

    # cutting plane A-A through the bottom of the shank ---------------------------------
    s.append('<g class="cut fade" style="--d:1.55s">')
    s.append(f'<path class="cl-ink" d="M{CX},524 V560"/>')
    s.append(f'<path class="cut-thick" d="M{CX},514 V526 M{CX},558 V570"/>')
    s.append(f'<path class="th" marker-end="url(#h-ar)" d="M{CX},514 H{CX+20}"/>')
    s.append(f'<path class="th" marker-end="url(#h-ar)" d="M{CX},570 H{CX+20}"/>')
    s.append('</g>')

    # SECTION A-A (2:1), hatched in graphite at 45 degrees ------------------------------
    s.append('<g class="view sec">')
    s.append(f'<g clip-path="url(#h-sec)" class="fade" style="--d:1.75s"><path class="hatch" d="{hatch(SECX-30, SECY-30, SECX+30, SECY+26, 5)}"/></g>')
    s.append(dr("ln", 1.45, .8, section_path()))
    s.append('</g>')

    # inside diameter: the ring size ---------------------------------------------------
    s.append('<g class="dim fade" style="--d:1.7s">')
    s.append(f'<path class="th" marker-start="url(#h-ar)" marker-end="url(#h-ar)" d="M{CX-RI},{FY} H{CX+RI}"/>')
    s.append('</g>')

    # leaders for the callouts (text is HTML, so it stays readable at every width) --------
    for co in CALLOUTS:
        (ax, ay), (ex, ey) = co["anchor"], co["elbow"]
        s.append(f'<g class="lead co-d fade {co["cls"]}" style="--d:{co["d"]:.2f}s">'
                 f'<circle class="dot" cx="{n(ax)}" cy="{n(ay)}" r="2.6"/>'
                 f'<path class="th" d="M{n(ax)},{n(ay)} L{n(ex)},{n(ey)}"/></g>')
    for b in BALLOONS:
        (bx, by), (ax, ay) = b["at"], b["anchor"]
        s.append(f'<g class="lead co-m"><circle class="dot" cx="{n(ax)}" cy="{n(ay)}" r="2.6"/>'
                 f'<path class="th" d="M{n(bx)},{n(by)} L{n(ax)},{n(ay)}"/></g>')
    s.append('</svg>')

    # HTML annotation layer ---------------------------------------------------------------
    a = ['<div class="ann" aria-hidden="true">']

    def at(x, y):
        return f'--x:{pct(x, W)};--y:{pct(y, H)}'

    # x=154, not CX-RO: at 768-1180 the label would otherwise run into the stone outline
    a.append(f'<span class="vl" style="{at(154, TY-38)}">Top view</span>')
    a.append(f'<span class="vl" style="{at(CX-RO, 590)}">Front view</span>')
    a.append(f'<span class="vl vl-c" style="{at(SX, 590)}">Side view</span>')
    a.append(f'<span class="vl vl-c" style="{at(SECX, 548)}">Section A–A <span class="vl-s">2:1</span></span>')
    a.append(f'<span class="cut-l" style="{at(CX+26, 514)}">A</span>')
    a.append(f'<span class="cut-l" style="{at(CX+26, 570)}">A</span>')
    a.append(f'<span class="dm-v" style="{at(CX, FY)}">Ø16.92</span>')
    a.append(f'<span class="dm-s" style="{at(CX, FY)}"><span class="k">Ring size</span>US 6½ · UK M½<span class="dm-sep"> · </span><span class="dm-in">IN 12</span></span>')
    for co in CALLOUTS:
        ex, ey = co["elbow"]
        sub = f'<span class="co-s">{co["sub"]}</span>' if co.get("sub") else ""
        mw = f';--mw:{pct(co["mw"], W)}' if co.get("mw") else ""
        a.append(f'<span class="co {co["cls"]}{" end" if co["align"] == "end" else ""}" style="{at(ex, ey)}{mw}">'
                 f'<span class="co-k">{co["label"]}</span><span class="co-b"><span class="co-v">{co["value"]}</span>{sub}</span></span>')
    for b in BALLOONS:
        bx, by = b["at"]
        a.append(f'<span class="bal" style="{at(bx, by)}">{b["n"]}</span>')
    a.append('</div>')
    return "\n".join(s) + "\n" + "\n".join(a)


def section_path():
    """Comfort-fit band section at the bottom of the shank, 2:1 (24 x 22 mm/13 px)."""
    x, y = SECX, SECY
    return (f"M{x-24},{y-20} Q{x},{y-27} {x+24},{y-20} C{x+26},{y-2} {x+17},{y+22} {x},{y+22} "
            f"C{x-17},{y+22} {x-26},{y-2} {x-24},{y-20} Z")


CALLOUTS = [
    dict(cls="co-stone", anchor=(CX + 24, TY - 30), elbow=(372, 38), align="start", d=2.0,
         label="Center stone", value="2.40 ct round brilliant", mw=480),
    dict(cls="co-origin", anchor=(SX + 14, 246), elbow=(672, 124), align="start", d=2.15,
         label="Origin", value="Lab-grown", sub="Every center and side stone must be marked natural or lab-grown", mw=206),
    dict(cls="co-metal", anchor=(SX + 9, 392), elbow=(654, 352), align="start", d=2.3,
         label="Metal", value="18K yellow gold", mw=220),
    dict(cls="co-stage is-hot", anchor=(CX - 121 * math.cos(math.radians(22)), FY + 121 * math.sin(math.radians(22))),
         elbow=(142, 486), align="end", d=2.45, label="Stage 07 / 14", value="Casting", sub="Photo 0 / 1", mw=140),
]

BALLOONS = [
    dict(n=1, at=(448, 44), anchor=(CX + 22, TY - 26)),
    dict(n=2, at=(450, 196), anchor=(CX + 18, 246)),
    dict(n=3, at=(454, 300), anchor=(CX + 121 * math.cos(math.radians(32)), FY - 121 * math.sin(math.radians(32)))),
]


# --------------------------------------------------------------------------- sheet 03 rule details

def rule1():
    return """<svg class="rule-art" viewBox="0 0 220 120" aria-hidden="true" focusable="false">
  <defs><marker id="r1-ar" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" markerUnits="userSpaceOnUse" orient="auto"><path d="M0,1.8 L10,5 L0,8.2 z" class="ar-fill"/></marker></defs>
  <path class="ln fillp dr" style="--d:.1s;--t:.7s" pathLength="1" d="M14,24 H70 V96 H14 Z"/>
  <path class="th dr" style="--d:.4s;--t:.4s" pathLength="1" d="M14,82 H70 M48,82 V96"/>
  <text class="t-lab" x="20" y="38">CAD</text><text class="t-big" x="42" y="68" text-anchor="middle">v2</text>
  <path class="th dr" style="--d:.6s;--t:.5s" pathLength="1" marker-end="url(#r1-ar)" d="M76,44 H128"/>
  <text class="t-lab fade" style="--d:.9s" x="134" y="48">APPROVE</text>
  <path class="th dr" style="--d:.7s;--t:.6s" pathLength="1" marker-end="url(#r1-ar)" d="M76,78 H104 V92 H128"/>
  <text class="t-lab fade" style="--d:1s" x="134" y="88">SEND BACK</text>
  <g class="fade" style="--d:1.2s"><rect class="redbox" x="133" y="96" width="80" height="17"/>
  <text class="t-hot" x="140" y="108.5">+ REASON</text></g>
</svg>"""


def rule2():
    return """<svg class="rule-art" viewBox="0 0 220 120" aria-hidden="true" focusable="false">
  <path class="th dr" style="--d:.1s;--t:.6s" pathLength="1" d="M40,16 h-16 v16 M196,16 h16 v16 M40,108 h-16 v-16 M196,108 h16 v-16"/>
  <g class="phantom-g fade" style="--d:.4s">
    <circle cx="86" cy="68" r="25"/><circle cx="86" cy="68" r="19"/>
    <path d="M77,44 L80,33 H92 L95,44"/>
    <path d="M82,93 V106 M90,93 V106"/>
  </g>
  <text class="t-lab fade" style="--d:.6s" x="86" y="25" text-anchor="middle">CAST PIECE</text>
  <text class="t-hot fade" style="--d:.9s" x="200" y="78" text-anchor="end">PHOTO</text>
  <text class="t-hot lg fade" style="--d:.9s" x="200" y="98" text-anchor="end">0 / 1</text>
</svg>"""


def rule3():
    s = ['<svg class="rule-art" viewBox="0 0 220 120" aria-hidden="true" focusable="false">']
    s.append('<text class="t-lab" x="14" y="18">CHECKLIST · SAMPLE</text>')
    for i in range(12):
        r, c = divmod(i, 6)
        x, y = 14 + c * 33, 30 + r * 40
        open_ = i >= 10
        d = .15 + i * .05
        s.append(f'<rect class="{"redbox" if open_ else "ln fillp"} fade" style="--d:{d:.2f}s" x="{x}" y="{y}" width="22" height="22"/>')
        if not open_:
            s.append(f'<path class="tick dr" style="--d:{d+.2:.2f}s;--t:.25s" pathLength="1" d="M{x+5},{y+11} l4,5 l8,-10"/>')
    s.append('<text class="t-hot fade" style="--d:.9s" x="206" y="112" text-anchor="end">2 OPEN</text>')
    s.append('</svg>')
    return "\n".join(s)


def rule4():
    return """<svg class="rule-art" viewBox="0 0 220 120" aria-hidden="true" focusable="false">
  <path class="ln fillp dr" style="--d:.1s;--t:.6s" pathLength="1" d="M22,46 L64,30 L106,46 L64,62 Z"/>
  <path class="ln fillp dr" style="--d:.2s;--t:.6s" pathLength="1" d="M22,46 V88 L64,104 V62 Z"/>
  <path class="ln fillp dr" style="--d:.3s;--t:.6s" pathLength="1" d="M106,46 V88 L64,104 V62 Z"/>
  <path class="th dr" style="--d:.5s;--t:.5s" pathLength="1" d="M43,38 L85,54 V96"/>
  <circle class="seal fade" style="--d:.8s" cx="85" cy="74" r="8"/>
  <path class="ln fillp" d="M122,30 h12 v12 h-12 z M122,56 h12 v12 h-12 z"/>
  <path class="tick dr" style="--d:.9s;--t:.25s" pathLength="1" d="M124.5,36 l3.5,3.5 l5,-7"/>
  <path class="tick dr" style="--d:1s;--t:.25s" pathLength="1" d="M124.5,62 l3.5,3.5 l5,-7"/>
  <rect class="redbox" x="122" y="82" width="12" height="12"/>
  <text class="t-lab" x="142" y="40.5">SEAL</text>
  <text class="t-lab" x="142" y="66.5">PHOTO</text>
  <text class="t-hot" x="142" y="92.5">CONTENTS</text>
  <text class="t-lab" x="142" y="114">SAMPLE</text>
</svg>"""


# --------------------------------------------------------------------------- sheet 04 custody

def parcel():
    """The client's stone paper, unfolded flat: two folds across, two at the ends."""
    x0, y0, x1, y1 = 8, 22, 332, 232
    fy1, fy2 = 92, 162
    fx1, fx2 = 62, 278
    cx, cy, R = 170, 127, 22
    table, stars, kites = facets(cx, cy, R)
    s = ['<svg class="parcel" viewBox="0 0 340 262" aria-hidden="true" focusable="false">']
    s.append(dr("ln fillp", .1, 1.0, f"M{x0},{y0} H{x1} V{y1} H{x0} Z"))
    s.append(f'<path class="fold fade" style="--d:.6s" d="M{x0},{fy1} H{x1} M{x0},{fy2} H{x1} M{fx1},{y0} V{y1} M{fx2},{y0} V{y1}"/>')
    s.append('<g class="cl fade" style="--d:.5s">'
             f'<path d="M{cx-34},{cy} H{cx+34} M{cx},{cy-30} V{cy+30}"/></g>')
    s.append(f'<circle class="ln fillp dr" style="--d:.7s;--t:.6s" pathLength="1" cx="{cx}" cy="{cy}" r="{R}"/>')
    s.append(dr("th", .9, .5, table))
    s.append(dr("th", 1.0, .6, stars + " " + kites))
    # detail circle A around the stone, labelled below right
    s.append(f'<circle class="phantom fade" style="--d:1.2s" cx="{cx}" cy="{cy}" r="31"/>')
    s.append(f'<g class="fade" style="--d:1.3s"><path class="th" d="M{cx+22},{cy+22} L{cx+38},{cy+38}"/>'
             f'<text class="t-cut" x="{cx+42}" y="{cy+52}">A</text></g>')
    # the pencil note on the top flap. Two lines normally; on a narrow phone the text is set
    # larger (CSS), so the long first line splits in three to stay clear of the right fold.
    s.append('<g class="fade pn-2" style="--d:1.1s">')
    s.append(f'<text class="t-note" x="{fx1+10}" y="{y0+30}">1.52 ct · GRN-2026-00184</text>')
    s.append(f'<text class="t-note" x="{fx1+10}" y="{y0+52}">DH-2026-01857</text>')
    s.append('</g>')
    s.append('<g class="fade pn-3" style="--d:1.1s">')
    for i, line in enumerate(("1.52 ct", "GRN-2026-00184", "DH-2026-01857")):
        s.append(f'<text class="t-note" x="{fx1+10}" y="{y0+22+i*18}">{line}</text>')
    s.append('</g>')
    s.append(f'<text class="t-view fade" style="--d:1.2s" x="{x0}" y="254">STONE PAPER · FLAT</text>')
    s.append('</svg>')
    return "\n".join(s)


def detail():
    cx, cy, R = 120, 128, 84
    table, stars, kites = facets(cx, cy, R)
    s = ['<svg class="detail" viewBox="0 0 240 272" aria-hidden="true" focusable="false">']
    s.append(f'<g class="cl"><path d="M{cx-112},{cy} H{cx+112} M{cx},{cy-112} V{cy+112}"/></g>')
    s.append(f'<circle class="phantom fade" style="--d:.1s" cx="{cx}" cy="{cy}" r="104"/>')
    s.append(f'<circle class="ln fillp dr" style="--d:.3s;--t:1s" pathLength="1" cx="{cx}" cy="{cy}" r="{R}"/>')
    s.append(f'<circle class="xt dr" style="--d:.5s;--t:1s" pathLength="1" cx="{cx}" cy="{cy}" r="{R-3}"/>')
    s.append(dr("ln", .6, .8, table))
    s.append(dr("th", .8, 1.2, stars))
    s.append(dr("th", 1.0, 1.4, kites))
    s.append(f'<text class="t-view fade" style="--d:1.2s" x="{cx}" y="262" text-anchor="middle">DETAIL A</text>')
    s.append('</svg>')
    return "\n".join(s)


def vault():
    s = ['<svg class="vault" viewBox="0 0 360 128" aria-hidden="true" focusable="false">']
    s.append('<text class="t-lab" x="2" y="15">VAULT A · SAMPLE LAYOUT</text>')
    s.append(dr("ln", .2, .8, "M2,26 H206 V122 H2 Z"))
    w, h = 44, 40
    for i in range(8):
        r, c = divmod(i, 4)
        x, y = 8 + c * (w + 4), 32 + r * (h + 4)
        hot = (i == 3)
        s.append(f'<rect class="{"tray-on" if hot else "tray"}" x="{x}" y="{y}" width="{w}" height="{h}"/>')
        if hot:
            s.append(f'<clipPath id="v-t4"><rect x="{x}" y="{y}" width="{w}" height="{h}"/></clipPath>')
            s.append(f'<g clip-path="url(#v-t4)"><path class="hatch" d="{hatch(x, y, x+w, y+h, 5)}"/></g>')
        if hot:  # knock the hatching out behind the numeral
            s.append(f'<rect class="paper" x="{x+2}" y="{y+3}" width="15" height="15"/>')
        s.append(f'<text class="t-tray" x="{x+5}" y="{y+15}">{i+1}</text>')
    tx, ty = 8 + 3 * (w + 4) + w - 12, 32 + h / 2
    s.append(f'<circle class="dot" cx="{n(tx)}" cy="{n(ty)}" r="2.6"/>')
    s.append(f'<path class="th" d="M{n(tx)},{n(ty)} L{n(tx+30)},{n(ty-14)} H358"/>')
    s.append(f'<text class="t-lab" x="{n(tx+34)}" y="{n(ty-21)}">TRAY 4</text>')
    # a stock lot, not the client's stone: goods-in receipts carry no vault location
    s.append(f'<text class="t-sub" x="{n(tx+34)}" y="{n(ty+3)}">Stock lot</text>')
    s.append(f'<text class="t-lab" x="{n(tx+34)}" y="{n(ty+20)}">SAMPLE</text>')
    s.append('</svg>')
    return "\n".join(s)


# --------------------------------------------------------------------------- sheet 08 mandrel

def mandrel():
    """A ring mandrel drawn as the week axis: a taper graduated 1 to 8, tip on the left."""
    s = ['<svg class="md-svg" viewBox="0 0 800 40" preserveAspectRatio="none" focusable="false">']
    s.append('<path class="md-body" d="M0,15.5 L800,3 V37 L0,24.5 Z"/>')
    s.append('<path class="md-cl" d="M0,20 H800"/>')
    ticks = []
    for i in range(0, 33):
        x = i * 25
        major = i % 4 == 0
        top = 15.5 - 12.5 * x / 800
        ticks.append(f"M{x},{n(top)} V{n(top + (10 if major else 4.5))}")
    s.append(f'<path class="md-t" d="{" ".join(ticks)}"/>')
    s.append('</svg>')
    return "\n".join(s)


BLOCKS = {
    "hero": hero, "rule1": rule1, "rule2": rule2, "rule3": rule3, "rule4": rule4,
    "parcel": parcel, "detail": detail, "vault": vault, "mandrel": mandrel,
}


def build():
    html = PAGE.read_text(encoding="utf-8")
    for name, fn in BLOCKS.items():
        pat = re.compile(rf"(<!-- gen:{name} -->)(.*?)(<!-- /gen:{name} -->)", re.S)
        if not pat.search(html):
            raise SystemExit(f"marker gen:{name} not found in index.html")
        html = pat.sub(lambda m: m.group(1) + "\n" + fn() + "\n" + m.group(3), html, count=1)
    PAGE.write_text(html, encoding="utf-8", newline="\n")
    print("index.html:", len(html.encode("utf-8")), "bytes")


if __name__ == "__main__":
    build()
