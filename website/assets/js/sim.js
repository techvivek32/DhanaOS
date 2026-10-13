/* DhanaOS: "What unrecorded gold costs you", drawn as a weight-balance sheet.
   Builds itself into every <div class="sim"> on the page, after the first paint, replacing any
   static fallback text the mount holds. Optional data-grams, data-pct and
   data-price attributes on the mount override the starting values (snapped to each range).
   Formula (illustrative): grams x pct/100 x 12 x price, computed in integers. No libraries. */
(function () {
  'use strict';

  var NS = 'http://www.w3.org/2000/svg';
  var nf0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
  var nf1 = new Intl.NumberFormat('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 1 });
  var nf1f = new Intl.NumberFormat('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  var usd = new Intl.NumberFormat('en-US', {
    style: 'currency', currency: 'USD', minimumFractionDigits: 0, maximumFractionDigits: 0
  });

  /* Each input is drawn as a drafting scale: minor/mid/major are tick spacings, nums the
     figured ticks, thin the figures dropped when the scale is narrow. */
  var CONTROLS = [
    {
      key: 'grams', id: 'grams', label: 'Gold through your bench each month',
      min: 500, max: 20000, step: 100, def: 4000, dp: 0,
      minor: 500, mid: 2500, major: 5000,
      nums: [500, 5000, 10000, 15000, 20000], thin: [5000, 15000],
      num: function (v) { return nf0.format(v); },
      text: function (v) { return nf0.format(v) + ' g'; },
      spoken: function (v) { return nf0.format(v) + ' grams a month'; }
    },
    {
      key: 'pct', id: 'loss', label: 'Unrecorded loss, % of that gold',
      min: 0.1, max: 3, step: 0.1, def: 1, dp: 1,
      minor: 0.1, mid: 0.5, major: 1,
      nums: [0.1, 0.5, 1, 1.5, 2, 2.5, 3], thin: [0.1],
      num: function (v) { return v.toFixed(1); },
      text: function (v) { return v.toFixed(1) + '%'; },
      spoken: function (v) { return v.toFixed(1) + ' percent of that gold'; }
    },
    {
      key: 'price', id: 'price', label: 'Gold price per gram',
      min: 60, max: 180, step: 1, def: 120, dp: 0,
      minor: 5, mid: 10, major: 20,
      nums: [60, 80, 100, 120, 140, 160, 180], thin: [80, 120, 160],
      num: function (v) { return '$' + nf0.format(v); },
      text: function (v) { return '$' + nf0.format(v); },
      spoken: function (v) { return nf0.format(v) + ' dollars per gram'; },
      help: 'Set your own rate.'
    }
  ];

  var MONTHS = 12;
  var TWEEN_MS = 220;
  var PCT_MIN = CONTROLS[1].min;
  var PCT_MAX = CONTROLS[1].max;
  var MONO_EM = 0.64;        // Martian Mono advance at 87.5% width, until it can be measured
  var reduceMotion = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;

  /* ---------- helpers ---------- */

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  function svg(tag, attrs, parent) {
    var n = document.createElementNS(NS, tag);
    if (attrs) for (var k in attrs) n.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(n);
    return n;
  }

  function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }
  function r2(v) { return Math.round(v * 100) / 100; }
  function crisp(v) { return Math.round(v) + 0.5; }
  function easeOut(t) { return 1 - Math.pow(1 - t, 3); }

  function snap(v, c) {
    var s = Math.round((v - c.min) / c.step) * c.step + c.min;
    return Number(clamp(s, c.min, c.max).toFixed(c.dp));
  }

  // Grams carry at most one decimal (100 g steps x tenths of a percent).
  function grams(g) { return nf1.format(g) + ' g'; }

  // All money is computed from integers: grams (whole), loss in tenths of a percent, $ per gram.
  function model(v) {
    var tenths = Math.round(v.pct * 10);
    var units = v.grams * tenths;                 // grams x 1000 lost per month
    return {
      issued: v.grams,
      monthG: units / 1000,
      returned: (v.grams * 1000 - units) / 1000,
      yearG: units * MONTHS / 1000,
      annual: Math.round(units * MONTHS * v.price / 1000),
      whole: units % 1000 === 0,
      cum: function (m) { return units * m / 1000; }
    };
  }

  /* ---------- drafting primitives (px; the viewBox is the box size) ---------- */

  var em = MONO_EM;            // measured advance of the mono face, in em

  function measureEm(parent) {
    var t = svg('text', { class: 'sim__t-ord', x: '0', y: '-20' }, parent);
    t.textContent = '0000000000';
    var w = 0;
    try { w = t.getBBox().width; } catch (e) { w = 0; }
    parent.removeChild(t);
    if (w > 30) em = w / 10 / 12;
  }

  // Text, optionally in parts [[class, text, dx]], optionally knocked out of the lines under it.
  function label(parent, cls, x, y, anchor, parts, knock) {
    var t = svg('text', { class: cls, x: r2(x), y: r2(y), 'text-anchor': anchor || 'start' }, parent);
    var chars = 0;
    if (typeof parts === 'string') {
      t.textContent = parts;
      chars = parts.length;
    } else {
      parts.forEach(function (p, i) {
        var s = svg('tspan', p[0] ? { class: p[0] } : null, t);
        if (i) s.setAttribute('dx', p[2] == null ? '0.7em' : p[2]);
        s.textContent = p[1];
        chars += p[1].length + (i ? 1 : 0);
      });
    }
    if (knock) {
      var b = null;
      try { b = t.getBBox(); } catch (e) { b = null; }
      if (!b || !b.width) {
        var w = chars * 12 * em * 1.06;
        var x0 = anchor === 'middle' ? x - w / 2 : anchor === 'end' ? x - w : x;
        b = { x: x0, y: y - 10, width: w, height: 13 };
      }
      var pad = knock === true ? 6 : knock;
      parent.insertBefore(svg('rect', {
        class: 'sim__knock', x: r2(b.x - pad), y: r2(b.y - 1), width: r2(b.width + pad * 2), height: r2(b.height + 2)
      }), t);
    }
    return t;
  }

  function arrow(parent, cls, x, y, dir) {
    // A drafting arrowhead, about 3:1, tip at (x, y), pointing dir (+1 right, -1 left).
    var L = 9, H = 3;
    svg('path', {
      class: cls,
      d: 'M' + r2(x) + ' ' + r2(y) + 'L' + r2(x - dir * L) + ' ' + r2(y - H) + 'L' + r2(x - dir * L) + ' ' + r2(y + H) + 'Z'
    }, parent);
  }

  // Horizontal dimension between two extension lines at xa < xb, dimension line at y.
  function dimension(parent, xa, xb, y, hot) {
    var cls = hot ? 'sim__dim sim__dim--hot' : 'sim__dim';
    var acls = hot ? 'sim__arrow sim__arrow--hot' : 'sim__arrow';
    var yy = crisp(y);
    if (xb - xa >= 28) {
      svg('line', { class: cls, x1: r2(xa), x2: r2(xb), y1: yy, y2: yy }, parent);
      arrow(parent, acls, xa, yy, -1);
      arrow(parent, acls, xb, yy, 1);
    } else {
      // Too tight for the arrows: they go outside and point in, as on any drawing.
      svg('line', { class: cls, x1: r2(xa - 20), x2: r2(xb + 20), y1: yy, y2: yy }, parent);
      arrow(parent, acls, xa, yy, 1);
      arrow(parent, acls, xb, yy, -1);
    }
  }

  function extension(parent, x, ya, yb) {
    svg('line', { class: 'sim__ext', x1: crisp(x), x2: crisp(x), y1: r2(ya), y2: r2(yb) }, parent);
  }

  function centreLine(parent, xa, xb, y) {
    svg('line', { class: 'sim__cl', x1: r2(xa), x2: r2(xb), y1: crisp(y), y2: crisp(y) }, parent);
  }

  function bar(parent, hatch, x0, x1, y, h) {
    var d = 'M' + r2(x0) + ' ' + r2(y) + 'H' + r2(x1) + 'V' + r2(y + h) + 'H' + r2(x0) + 'Z';
    svg('path', { class: 'sim__bar-fill', d: d }, parent);
    svg('path', { class: 'sim__bar-hatch', d: d, fill: 'url(#' + hatch + ')' }, parent);
    svg('path', { class: 'sim__obj', d: d }, parent);
  }

  function wrap(text, cols) {
    var out = [];
    var line = '';
    text.split(' ').forEach(function (w) {
      if (line && (line + ' ' + w).length > cols) { out.push(line); line = w; }
      else line = line ? line + ' ' + w : w;
    });
    if (line) out.push(line);
    return out;
  }

  // An underlined view title with a muted line under it, wrapped to maxW. Returns the last baseline.
  function viewTitle(parent, x, y, title, sub, maxW) {
    var t = label(parent, 'sim__t-view', x, y, 'start', title);
    // Drawn underline: SVG text-decoration is not rendered everywhere.
    var w = 0;
    try { w = t.getBBox().width - 12 * 0.12; } catch (e) { w = 0; }   // less the trailing tracking
    if (!(w > 0)) w = title.length * 12 * (em + 0.12);
    svg('line', { class: 'sim__t-rule', x1: r2(x), x2: r2(x + w), y1: crisp(y + 3), y2: crisp(y + 3) }, parent);
    if (!sub) return y;
    var cols = Math.max(12, Math.floor(maxW / (12 * (em + 0.08) * 1.03)));
    wrap(sub, cols).forEach(function (ln) {
      y += 18;
      label(parent, 'sim__t-sub', x, y, 'start', ln);
    });
    return y;
  }

  /* ---------- widget ---------- */

  function mount(root, index) {
    var sfx = index ? '-' + (index + 1) : '';
    var values = {};
    CONTROLS.forEach(function (c) {
      var raw = parseFloat(root.getAttribute('data-' + c.key));
      values[c.key] = snap(isFinite(raw) ? raw : c.def, c);
    });

    root.textContent = '';
    root.classList.add('sim--ready');

    var layout = el('div', 'sim__layout');

    /* ----- cell A: the three scales, then the result ----- */

    var panel = el('div', 'sim__panel');
    var inCell = el('div', 'sim__inputs');
    var pHead = el('p', 'sim__cell-head');
    pHead.setAttribute('aria-hidden', 'true');
    pHead.appendChild(el('span', 'sim__cell-n', 'A'));
    pHead.appendChild(el('span', null, 'Inputs'));
    inCell.appendChild(pHead);

    var controls = el('div', 'sim__controls');
    var inputs = {};
    var parts = {};

    CONTROLS.forEach(function (c) {
      var id = 'sim-' + c.id + sfx;
      var wrap = el('div', 'sim__control');
      var head = el('div', 'sim__head');
      var lab = el('label', 'sim__label', c.label);
      lab.htmlFor = id;
      var value = el('span', 'sim__value');
      value.setAttribute('aria-hidden', 'true');
      value.style.minWidth = 'calc(' + Math.max(c.text(c.min).length, c.text(c.max).length) + 'ch + 18px)';
      head.appendChild(lab);
      head.appendChild(value);

      var ruler = el('div', 'sim__ruler');
      var input = el('input', 'sim__range');
      input.type = 'range';
      input.id = id;
      input.min = String(c.min);
      input.max = String(c.max);
      input.step = String(c.step);
      input.value = String(values[c.key]);
      input.setAttribute('data-key', c.key);

      var scale = el('div', 'sim__scale');
      scale.setAttribute('aria-hidden', 'true');
      var marks = el('div', 'sim__marks');
      var span = c.max - c.min;
      var n = Math.round(span / c.minor);
      function on(v, every) { return Math.abs(v / every - Math.round(v / every)) < 1e-6; }
      for (var i = 0; i <= n; i++) {
        var v = Number((c.min + i * c.minor).toFixed(4));
        var kind = on(v, c.major) ? 'major' : on(v, c.mid) ? 'mid' : 'minor';
        var t = el('span', 'sim__tick sim__tick--' + kind);
        t.style.left = ((v - c.min) / span * 100).toFixed(4) + '%';
        marks.appendChild(t);
      }
      c.nums.forEach(function (v) {
        var num = el('span', 'sim__num' + (on(v, c.major) ? '' : ' sim__num--mid') +
          (c.thin.indexOf(v) >= 0 ? ' sim__num--thin' : ''), c.num(v));
        num.style.left = ((v - c.min) / span * 100).toFixed(4) + '%';
        marks.appendChild(num);
      });
      scale.appendChild(marks);
      scale.appendChild(el('span', 'sim__run'));
      var cursor = el('span', 'sim__cursor');
      cursor.setAttribute('aria-hidden', 'true');

      ruler.appendChild(input);
      ruler.appendChild(scale);
      ruler.appendChild(cursor);

      wrap.appendChild(head);
      wrap.appendChild(ruler);
      if (c.help) {
        var help = el('p', 'sim__help', c.help);
        help.id = id + '-help';
        input.setAttribute('aria-describedby', help.id);
        wrap.appendChild(help);
      }
      controls.appendChild(wrap);
      inputs[c.key] = input;
      parts[c.key] = { value: value, ruler: ruler };
    });
    inCell.appendChild(controls);
    panel.appendChild(inCell);

    var result = el('div', 'sim__result');
    var live = el('div', 'sim__live');
    live.setAttribute('aria-live', 'polite');
    live.setAttribute('aria-atomic', 'true');
    var kicker = el('p', 'sim__kicker', 'Unrecorded gold, per year');
    var figure = el('p', 'sim__figure');
    figure.setAttribute('aria-hidden', 'true');
    var cur = el('span', 'sim__cur', '$');
    var amount = el('span', 'sim__amount');
    figure.appendChild(cur);
    figure.appendChild(amount);
    var spoken = el('span', 'sim__sr');
    live.appendChild(kicker);
    live.appendChild(figure);
    live.appendChild(spoken);
    var gramsLine = el('p', 'sim__grams');
    result.appendChild(live);
    result.appendChild(gramsLine);
    panel.appendChild(result);

    /* ----- cell B: the weight balance, drawn ----- */

    var fig = el('div', 'sim__fig');
    var fHead = el('p', 'sim__cell-head');
    fHead.setAttribute('aria-hidden', 'true');
    fHead.appendChild(el('span', 'sim__cell-n', 'B'));
    fHead.appendChild(el('span', null, 'Weight balance'));
    fig.appendChild(fHead);

    var draw = el('div', 'sim__draw');
    draw.setAttribute('role', 'img');
    var hatchId = 'sim-hatch' + sfx;
    var clipId = 'sim-clip' + sfx;
    var s = svg('svg', { class: 'sim__svg', 'aria-hidden': 'true', focusable: 'false' });
    var defs = svg('defs', null, s);
    var pattern = svg('pattern', {
      id: hatchId, patternUnits: 'userSpaceOnUse', width: '7', height: '7',
      patternTransform: 'rotate(45)'
    }, defs);
    svg('line', { class: 'sim__hatch-line', x1: '0', y1: '-1', x2: '0', y2: '8' }, pattern);
    var clip = svg('clipPath', { id: clipId }, defs);
    var clipCircle = svg('circle', { cx: '0', cy: '0', r: '1' }, clip);
    var layer = svg('g', null, s);
    draw.appendChild(s);
    fig.appendChild(draw);

    layout.appendChild(panel);
    layout.appendChild(fig);

    var foot = el('div', 'sim__foot');
    foot.appendChild(el('span', 'sim__note-k', 'Note'));
    foot.appendChild(el('p', 'sim__note',
      'Illustrative. With DhanaOS, gold issued and returned is recorded by weight against each job, so loss becomes a number instead of a guess.'));

    root.appendChild(layout);
    root.appendChild(foot);

    /* ---------- state ---------- */

    var st = { w: 0, h: 0, m: null, pct: values.pct, raf: 0, snap: 0, em: false };
    var speakTimer = 0;

    function refreshInputs() {
      CONTROLS.forEach(function (c) {
        var v = values[c.key];
        parts[c.key].ruler.style.setProperty('--sim-p', String((v - c.min) / (c.max - c.min)));
        inputs[c.key].setAttribute('aria-valuetext', c.spoken(v));
        parts[c.key].value.textContent = c.text(v);
      });
    }

    function refreshResult(announce) {
      var m = st.m;
      var full = usd.format(m.annual);
      amount.textContent = full.replace(/^\$/, '');
      figure.setAttribute('data-len', String(full.length));
      gramsLine.textContent = '';
      // Same figures as the tally: one decimal on both whenever the month is not whole.
      var gfmt = m.whole ? nf0 : nf1f;
      var a = el('span', 'sim__grams-part');
      a.appendChild(el('span', 'sim__grams-num', gfmt.format(m.monthG) + ' g'));
      a.appendChild(document.createTextNode(' a month'));
      var b = el('span', 'sim__grams-part');
      b.appendChild(el('span', 'sim__grams-num', gfmt.format(m.yearG) + ' g'));
      b.appendChild(document.createTextNode(' a year'));
      gramsLine.appendChild(a);
      gramsLine.appendChild(document.createTextNode(' · '));
      gramsLine.appendChild(b);

      draw.setAttribute('aria-label',
        'Weight balance for one month: ' + grams(m.issued) + ' of gold issued, ' + grams(m.returned) +
        ' returned, ' + grams(m.monthG) + ' unrecorded. Over 12 months: ' + grams(m.yearG) + '.');

      clearTimeout(speakTimer);
      if (announce) {
        speakTimer = setTimeout(function () { spoken.textContent = full; }, 450);
      } else {
        spoken.textContent = full;
      }
    }

    /* ---------- the drawing ---------- */

    function render() {
      var W = st.w;
      if (!W) return;
      var m = st.m;
      if (!st.em) { measureEm(layer); st.em = true; }
      // Narrow: the detail is centred with its notes under it. Wide: notes sit beside it.
      var narrow = W < 400;
      layer.textContent = '';

      /* View A: one month, issued against returned, in true proportion. */
      var x0 = 10;
      var xI = W - 42;
      var xR = xI - (xI - x0) * st.pct / 100;
      var bh = narrow ? 20 : 24;
      // Narrow: the names leave the dimension lines so the arrows stay visible.
      var dim1 = narrow ? 32 : 14;
      var yI = dim1 + 22;
      var yR = yI + bh + 10;
      var dim2 = yR + bh + 22;

      var gv = svg('g', { class: 'sim__view' }, layer);
      bar(gv, hatchId, x0, xI, yI, bh);
      bar(gv, hatchId, x0, xR, yR, bh);
      centreLine(gv, x0 - 8, xI + 10, yI + bh / 2);
      centreLine(gv, x0 - 8, xR + 10, yR + bh / 2);

      extension(gv, x0, yI - 3, dim1 - 7);
      extension(gv, xI, yI - 3, dim1 - 7);
      dimension(gv, x0, xI, dim1);
      extension(gv, x0, yR + bh + 3, dim2 + 7);
      extension(gv, xR, yR + bh + 3, dim2 + 7);
      dimension(gv, x0, xR, dim2);
      if (narrow) {
        label(gv, 'sim__t-dim', x0, dim1 - 16, 'start', [['sim__t-name', 'Gold issued']]);
        label(gv, 'sim__t-dim', (x0 + xI) / 2, dim1 + 4.5, 'middle', [['sim__t-val', grams(m.issued)]], true);
        label(gv, 'sim__t-dim', (x0 + xR) / 2, dim2 + 4.5, 'middle', [['sim__t-val', grams(m.returned)]], true);
        label(gv, 'sim__t-dim', x0, dim2 + 24, 'start', [['sim__t-name', 'Gold returned']]);
      } else {
        label(gv, 'sim__t-dim', (x0 + xI) / 2, dim1 + 4.5, 'middle',
          [['sim__t-name', 'Gold issued'], ['sim__t-val', grams(m.issued)]], true);
        label(gv, 'sim__t-dim', (x0 + xR) / 2, dim2 + 4.5, 'middle',
          [['sim__t-name', 'Gold returned'], ['sim__t-val', grams(m.returned)]], true);
      }

      // Detail circle B on the bar ends.
      var bcx = (xI + xR) / 2;
      var bcy = yI + (yR + bh - yI) / 2;
      var br = (yR + bh - yI) / 2 + 9;
      svg('circle', { class: 'sim__ring', cx: r2(bcx), cy: r2(bcy), r: r2(br) }, gv);
      label(gv, 'sim__t-letter', bcx + br * 0.72 + 4, bcy - br * 0.72 - 2, 'start', 'B', 3);

      var tA = dim2 + (narrow ? 58 : 36);
      viewTitle(gv, x0, tA, 'View A · one month', 'To scale', W - x0);

      /* Detail B: the same bar ends, enlarged so the gap can be read. Not to scale. */
      var R = narrow ? clamp(W * 0.36, 92, 118) : clamp(W * 0.23, 104, 128);
      var dcx = narrow ? W / 2 : W - R - 4;
      var dcy = (narrow ? tA + 26 : dim2 + 30) + R;
      var dh = R * 0.29;
      var dg = R * 0.1;
      var dyI = dcy - R * 0.5;
      var dyR = dyI + dh + dg;
      var dyB = dyR + dh;
      var xE = dcx + R * 0.06;
      var gMin = 16;
      var gMax = R * 0.82 - 20;
      var gap = gMin + (clamp(st.pct, PCT_MIN, PCT_MAX) - PCT_MIN) / (PCT_MAX - PCT_MIN) * (gMax - gMin);
      var xRE = xE - gap;

      setAttrs(clipCircle, { cx: r2(dcx), cy: r2(dcy), r: r2(R - 0.5) });
      var gd = svg('g', { class: 'sim__detail' }, layer);
      var inside = svg('g', { 'clip-path': 'url(#' + clipId + ')' }, gd);
      bar(inside, hatchId, dcx - R - 4, xE, dyI, dh);
      bar(inside, hatchId, dcx - R - 4, xRE, dyR, dh);
      // Where the unrecorded gold would have been: a phantom outline.
      svg('rect', { class: 'sim__phantom', x: r2(xRE), y: r2(dyR + 0.6), width: r2(gap), height: r2(dh - 1.2) }, inside);
      centreLine(inside, dcx - R, xE + 12, dyI + dh / 2);
      centreLine(inside, dcx - R, xRE + 12, dyR + dh / 2);
      svg('circle', { class: 'sim__ring sim__ring--detail', cx: r2(dcx), cy: r2(dcy), r: r2(R) }, gd);

      label(gd, 'sim__t-end', xE + 9, dyI + dh / 2 + 4.5, 'start', 'Issued', 3);
      label(gd, 'sim__t-end', xE + 9, dyR + dh / 2 + 4.5, 'start', 'Returned', 3);

      var dimY = dyB + R * 0.17;
      extension(gd, xE, dyI + dh + 3, dimY + 7);
      extension(gd, xRE, dyB + 3, dimY + 7);
      dimension(gd, xRE, xE, dimY, true);
      var ly = dimY + R * 0.21;
      var half = Math.sqrt(Math.max(0, R * R - Math.pow(ly - dcy, 2)));
      var lx = clamp((xRE + xE) / 2, dcx - half + 34, dcx + half - 34);
      label(gd, 'sim__t-loss', lx, ly, 'middle', grams(m.monthG), 4);

      // General notes: say plainly what the enlargement does.
      var notes = [
        'The gap is the unrecorded loss: ' + values.pct.toFixed(1) + '% of the gold issued.',
        'The gap is enlarged to be read. View A shows it in true proportion.'
      ];
      var noteW = narrow ? W - x0 * 2 : dcx - R - 22 - x0;
      var cols = Math.max(14, Math.floor((noteW - 22) / (12 * em * 1.04)));
      var lines = [];
      notes.forEach(function (n, i) {
        wrap(n, cols).forEach(function (ln, j) { lines.push([j ? '' : String(i + 1), ln, j === 0 && i > 0]); });
      });
      var noteH = 18 + 26 + lines.length * 18 + 8;
      var tB = narrow ? dcy + R + 30 : Math.max(tA + 46, dcy + R - noteH + 6);
      viewTitle(gd, x0, tB, 'Detail B', 'Not to scale', noteW);
      var ny = tB + 44;
      lines.forEach(function (ln) {
        if (ln[2]) ny += 6;
        if (ln[0]) label(gd, 'sim__t-note-n', x0, ny, 'start', ln[0]);
        label(gd, 'sim__t-note', x0 + 20, ny, 'start', ln[1]);
        ny += 18;
      });
      var notesEnd = ny - 18;

      /* The tally: twelve months of unrecorded gold, dimensioned from a datum like any part. */
      var tTop = Math.max(dcy + R, notesEnd) + 36;
      var gt = svg('g', { class: 'sim__tally' }, layer);
      var fmt = m.whole ? nf0 : nf1f;
      // The year figure is the widest on the strip; 9px keeps neighbouring figures apart.
      var figW = fmt.format(m.yearG).length * 12 * em + 9;
      var tx0 = x0 + 4;
      var tx1 = W - Math.max(24, Math.ceil(figW / 2) + 2);   // room for half of the year figure
      var cell = (tx1 - tx0) / MONTHS;
      // Figure every month when the figures fit across, else the fewest months that still divide 12.
      var every = [1, 2, 3, 4, 6, 12].filter(function (n) { return figW <= cell * n; })[0] || 12;
      var sy = tTop + 26;
      var sh = 12;

      svg('rect', { class: 'sim__strip', x: r2(tx0), y: r2(sy), width: r2(tx1 - tx0), height: sh }, gt);
      for (var k = 0; k <= MONTHS; k++) {
        var x = crisp(tx0 + k * cell);
        var figured = k % every === 0;
        svg('line', {
          class: 'sim__ord', x1: x, x2: x,
          y1: r2(sy - (figured ? 6 : 0)), y2: r2(sy + sh + (figured ? 5 : 0))
        }, gt);
        if (!figured) continue;
        label(gt, k === MONTHS ? 'sim__t-ord sim__t-ord--year' : 'sim__t-ord', x, sy - 11, 'middle',
          k ? fmt.format(m.cum(k)) : '0');
        if (k) label(gt, 'sim__t-month', x, sy + sh + 19, 'middle', (k < 10 ? '0' : '') + k);
      }
      var tC = sy + sh + 50;
      var tEnd = viewTitle(gt, x0, tC, '12-month tally', 'Grams unrecorded, running total', W - x0 * 2);

      var H = Math.ceil(tEnd + 6);
      if (H !== st.h) {
        st.h = H;
        s.setAttribute('height', H);
      }
      s.setAttribute('width', W);
      s.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    }

    function setAttrs(n, attrs) {
      for (var k in attrs) n.setAttribute(k, attrs[k]);
    }

    function animateTo(target) {
      cancelAnimationFrame(st.raf);
      clearTimeout(st.snap);
      var still = !st.w || document.hidden || (reduceMotion && reduceMotion.matches) ||
        Math.abs(target - st.pct) < 1e-4;
      if (still) {
        st.pct = target;
        render();
        return;
      }
      var from = st.pct;
      var t0 = 0;
      function frame(now) {
        if (!t0) t0 = now;
        var t = Math.min(1, (now - t0) / TWEEN_MS);
        st.pct = from + (target - from) * easeOut(t);
        render();
        if (t < 1) st.raf = requestAnimationFrame(frame);
      }
      st.raf = requestAnimationFrame(frame);
      // If frames are starved (throttled tab, busy main thread), land on the true shape anyway.
      st.snap = setTimeout(function () {
        cancelAnimationFrame(st.raf);
        st.pct = target;
        render();
      }, TWEEN_MS + 150);
    }

    function update(announce) {
      st.m = model(values);
      refreshInputs();
      refreshResult(announce);
      if (Math.abs(values.pct - st.pct) < 1e-4) render();
      else animateTo(values.pct);
    }

    function resize(w) {
      w = Math.floor(w);
      if (w < 120 || w === st.w) return;
      st.w = w;
      render();
    }

    /* ---------- events ---------- */

    CONTROLS.forEach(function (c) {
      inputs[c.key].addEventListener('input', function (e) {
        values[c.key] = snap(parseFloat(e.target.value), c);
        update(true);
      });
    });

    /* ---------- first paint: complete at once, then follow the layout ---------- */

    st.m = model(values);
    refreshInputs();
    refreshResult(false);
    st.w = Math.floor(draw.getBoundingClientRect().width) || 560;
    render();

    function measure() {
      st.em = false;
      var w = Math.floor(draw.getBoundingClientRect().width);
      if (w >= 120 && w !== st.w) { st.w = w; render(); }
      else if (w >= 120) render();      // fonts changed: re-measure the knockouts
    }
    if (window.ResizeObserver) {
      new ResizeObserver(function (entries) { resize(entries[0].contentRect.width); }).observe(draw);
    } else {
      window.addEventListener('resize', measure);
    }
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(measure);
  }

  function init() {
    var roots = document.querySelectorAll('.sim');
    for (var i = 0; i < roots.length; i++) {
      if (!roots[i].classList.contains('sim--ready')) mount(roots[i], i);
    }
  }

  // Build after the first paint, so nothing here forces a layout before the page is drawn once.
  // Until then the mount shows its static text, which mount() clears. A hidden tab gets no
  // animation frames, so it builds on a plain timer instead.
  function later() {
    if (document.hidden || !window.requestAnimationFrame) setTimeout(init, 0);
    else requestAnimationFrame(function () { setTimeout(init, 0); });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', later);
  else later();
})();
