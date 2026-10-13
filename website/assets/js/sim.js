/* DhanaOS: "What unmeasured gold costs you" calculator.
   Builds itself into every <div class="sim"> on the page. Optional data-grams, data-pct and
   data-price attributes on the mount override the starting values (clamped to each range). */
(function () {
  'use strict';

  var NS = 'http://www.w3.org/2000/svg';
  var nf0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
  var usd = new Intl.NumberFormat('en-US', {
    style: 'currency', currency: 'USD', minimumFractionDigits: 0, maximumFractionDigits: 0
  });
  var usdShort = new Intl.NumberFormat('en-US', {
    style: 'currency', currency: 'USD', notation: 'compact',
    minimumFractionDigits: 0, maximumFractionDigits: 1
  });

  var CONTROLS = [
    {
      key: 'grams', id: 'grams', label: 'Gold through your bench each month',
      min: 500, max: 20000, step: 100, def: 4000, dp: 0,
      text: function (v) { return nf0.format(v) + ' g'; },
      spoken: function (v) { return nf0.format(v) + ' grams a month'; }
    },
    {
      key: 'pct', id: 'loss', label: 'Unrecorded loss, % of that gold',
      min: 0.1, max: 3, step: 0.1, def: 1, dp: 1,
      text: function (v) { return v.toFixed(1) + '%'; },
      spoken: function (v) { return v.toFixed(1) + ' percent of that gold'; }
    },
    {
      key: 'price', id: 'price', label: 'Gold price per gram',
      min: 60, max: 180, step: 1, def: 120, dp: 0,
      text: function (v) { return '$' + nf0.format(v); },
      spoken: function (v) { return nf0.format(v) + ' dollars per gram'; },
      help: 'Set your own rate.'
    }
  ];

  var MONTHS = 12;
  var TWEEN_MS = 260;
  var reduceMotion = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;

  /* ---------- helpers ---------- */

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  function svg(tag, attrs) {
    var n = document.createElementNS(NS, tag);
    if (attrs) for (var k in attrs) n.setAttribute(k, attrs[k]);
    return n;
  }

  function setAttrs(n, attrs) {
    for (var k in attrs) n.setAttribute(k, attrs[k]);
  }

  function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }

  function snap(v, c) {
    var s = Math.round((v - c.min) / c.step) * c.step + c.min;
    return Number(clamp(s, c.min, c.max).toFixed(c.dp));
  }

  function grams(g) {
    return g < 10 ? g.toFixed(1) + ' g' : nf0.format(Math.round(g)) + ' g';
  }

  // All money is computed from integers: grams (whole), loss in tenths of a percent, $ per gram.
  function model(v) {
    var tenths = Math.round(v.pct * 10);
    var units = v.grams * tenths;                 // grams x 1000 lost per month
    return {
      monthG: units / 1000,
      yearG: units * MONTHS / 1000,
      annual: Math.round(units * MONTHS * v.price / 1000),
      at: function (m) { return Math.round(units * m * v.price / 1000); }
    };
  }

  // Three or four round gridline steps whose top sits as close above the value as possible.
  function niceScale(top) {
    var mult = [1, 2, 2.5, 3, 4, 5];
    var e0 = Math.floor(Math.log10(Math.max(top, 1)));
    var best = null;
    for (var e = e0 - 1; e <= e0; e++) {
      for (var i = 0; i < mult.length; i++) {
        var step = mult[i] * Math.pow(10, e);
        if (step < 1) continue;
        var n = Math.ceil(top / step - 1e-9);
        if (n < 3 || n > 4) continue;
        var fill = top / (n * step);
        if (!best || fill > best.fill + 1e-9) best = { step: step, n: n, max: n * step, fill: fill };
      }
    }
    return best || { step: Math.max(1, Math.ceil(top / 4)), n: 4, max: Math.max(4, Math.ceil(top / 4) * 4), fill: 1 };
  }

  function easeOut(t) { return 1 - Math.pow(1 - t, 3); }

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
    var panel = el('div', 'sim__panel');
    var controls = el('div', 'sim__controls');
    var inputs = {};
    var readouts = {};

    CONTROLS.forEach(function (c) {
      var id = 'sim-' + c.id + sfx;
      var wrap = el('div', 'sim__control');
      var head = el('div', 'sim__head');
      var label = el('label', 'sim__label', c.label);
      label.htmlFor = id;
      var value = el('span', 'sim__value');
      value.setAttribute('aria-hidden', 'true');
      head.appendChild(label);
      head.appendChild(value);

      var input = el('input', 'sim__range');
      input.type = 'range';
      input.id = id;
      input.min = String(c.min);
      input.max = String(c.max);
      input.step = String(c.step);
      input.value = String(values[c.key]);
      input.setAttribute('data-key', c.key);

      wrap.appendChild(head);
      wrap.appendChild(input);
      if (c.help) {
        var help = el('p', 'sim__help', c.help);
        help.id = id + '-help';
        input.setAttribute('aria-describedby', help.id);
        wrap.appendChild(help);
      }
      controls.appendChild(wrap);
      inputs[c.key] = input;
      readouts[c.key] = value;
    });

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

    panel.appendChild(controls);
    panel.appendChild(result);

    /* chart */
    var chart = el('div', 'sim__chart');
    chart.tabIndex = 0;
    chart.setAttribute('role', 'group');
    chart.setAttribute('aria-label',
      'Cumulative unaccounted gold value over 12 months. Use the left and right arrow keys to read each month.');
    var chartLive = el('span', 'sim__sr');
    chartLive.setAttribute('aria-live', 'polite');

    var hatchId = 'sim-hatch' + sfx;
    var s = svg('svg', { class: 'sim__svg', 'aria-hidden': 'true', focusable: 'false' });
    var defs = svg('defs');
    var pattern = svg('pattern', {
      id: hatchId, patternUnits: 'userSpaceOnUse', width: '20', height: '5',
      patternTransform: 'rotate(-45)'
    });
    // A guilloche-like wave, the engine-turned lines on a watch dial or a cigarette case.
    pattern.appendChild(svg('path', {
      class: 'sim__hatch-line', d: 'M0 2.5 C3.3 1.2 6.7 1.2 10 2.5 S16.7 3.8 20 2.5'
    }));
    defs.appendChild(pattern);
    s.appendChild(defs);

    var gGrid = svg('g', { class: 'sim__gridlines' });
    var gAxis = svg('g', { class: 'sim__axis' });
    var area = svg('path', { class: 'sim__area' });
    var hatch = svg('path', { class: 'sim__hatch', fill: 'url(#' + hatchId + ')' });
    var cuts = svg('path', { class: 'sim__cuts' });
    var line = svg('path', { class: 'sim__line' });
    var gEnd = svg('g', { class: 'sim__end' });
    var endHalo = svg('circle', { class: 'sim__end-halo', r: '9' });
    var endDot = svg('circle', { class: 'sim__end-dot', r: '4.5' });
    var endText = svg('text', { class: 'sim__end-text', 'text-anchor': 'end' });
    gEnd.appendChild(endHalo);
    gEnd.appendChild(endDot);
    gEnd.appendChild(endText);
    var gHover = svg('g', { class: 'sim__hover' });
    var hLine = svg('line', { class: 'sim__hover-line' });
    var hDot = svg('circle', { class: 'sim__hover-dot', r: '4' });
    var hMonth = svg('text', { class: 'sim__hover-month' });
    var hValue = svg('text', { class: 'sim__hover-value' });
    gHover.appendChild(hLine);
    gHover.appendChild(hDot);
    gHover.appendChild(hMonth);
    gHover.appendChild(hValue);

    s.appendChild(gGrid);
    s.appendChild(area);
    s.appendChild(hatch);
    s.appendChild(cuts);
    s.appendChild(gAxis);
    s.appendChild(line);
    s.appendChild(gHover);
    s.appendChild(gEnd);
    chart.appendChild(s);
    chart.appendChild(chartLive);

    layout.appendChild(panel);
    layout.appendChild(chart);

    var foot = el('div', 'sim__foot');
    foot.appendChild(el('p', 'sim__note',
      'Illustrative. With DhanaOS, gold issued and returned is recorded by weight against each job, so loss becomes a number instead of a guess.'));

    root.appendChild(layout);
    root.appendChild(foot);

    /* ---------- state ---------- */

    var st = {
      w: 0, h: 0,
      m: null, scale: null,
      fill: 0,          // drawn height of month 12 as a share of the plot (tweened)
      raf: 0,
      snap: 0,
      hover: null,
      geo: null
    };
    var speakTimer = 0;

    function refreshInputs() {
      CONTROLS.forEach(function (c) {
        var input = inputs[c.key];
        var v = values[c.key];
        input.style.setProperty('--sim-p', String((v - c.min) / (c.max - c.min)));
        input.setAttribute('aria-valuetext', c.spoken(v));
        readouts[c.key].textContent = c.text(v);
      });
    }

    function refreshResult(announce) {
      var m = st.m;
      var full = usd.format(m.annual);
      amount.textContent = full.replace(/^\$/, '');
      figure.setAttribute('data-len', String(full.length));
      gramsLine.textContent = '';
      var a = el('span', 'sim__grams-num', grams(m.monthG));
      var b = el('span', 'sim__grams-num', grams(m.yearG));
      gramsLine.appendChild(a);
      gramsLine.appendChild(document.createTextNode(' a month · '));
      gramsLine.appendChild(b);
      gramsLine.appendChild(document.createTextNode(' a year'));

      clearTimeout(speakTimer);
      if (announce) {
        speakTimer = setTimeout(function () { spoken.textContent = full; }, 450);
      } else {
        spoken.textContent = full;
      }
    }

    /* ---------- chart drawing ---------- */

    function geometry() {
      var w = st.w, h = st.h;
      var narrow = w < 420;
      var g = {
        w: w, h: h,
        x0: 0,
        x1: w - (narrow ? 12 : 14),
        top: narrow ? 34 : 40,
        base: h - (narrow ? 44 : 48)
      };
      g.plot = g.base - g.top;
      g.x = function (mo) { return g.x0 + (mo / MONTHS) * (g.x1 - g.x0); };
      return g;
    }

    function crisp(v) { return Math.round(v) + 0.5; }

    function drawStatic() {
      // Gridlines, $ labels, month ticks: depend on size and the target scale, not on the tween.
      var g = st.geo, sc = st.scale;
      gGrid.textContent = '';
      for (var k = 1; k <= sc.n; k++) {
        var v = k * sc.step;
        var y = crisp(g.base - (v / sc.max) * g.plot);
        gGrid.appendChild(svg('line', { class: 'sim__grid', x1: g.x0, x2: g.w, y1: y, y2: y }));
        var t = svg('text', { class: 'sim__ylabel', x: g.x0, y: y - 7 });
        t.textContent = usdShort.format(v);
        gGrid.appendChild(t);
      }

      gAxis.textContent = '';
      var by = crisp(g.base);
      gAxis.appendChild(svg('line', { class: 'sim__baseline', x1: g.x0, x2: g.w, y1: by, y2: by }));
      for (var mo = 1; mo <= MONTHS; mo++) {
        var x = crisp(g.x(mo));
        gAxis.appendChild(svg('line', { class: 'sim__tick', x1: x, x2: x, y1: by, y2: by + 5 }));
        var lbl = svg('text', { class: 'sim__xlabel', x: g.x(mo), y: g.base + 21, 'text-anchor': mo === MONTHS ? 'end' : 'middle' });
        if (mo === MONTHS) lbl.setAttribute('x', g.x(mo) + 7);
        lbl.textContent = String(mo);
        gAxis.appendChild(lbl);
      }
      var cap = svg('text', { class: 'sim__caption', x: g.x0, y: g.h - 6 });
      cap.textContent = 'Months';
      gAxis.appendChild(cap);
    }

    function lineY(g, mo) { return g.base - st.fill * (mo / MONTHS) * g.plot; }

    function drawShape() {
      var g = st.geo;
      var yEnd = lineY(g, MONTHS);
      var d = 'M' + g.x0 + ' ' + g.base + 'L' + g.x1 + ' ' + yEnd.toFixed(2) + 'L' + g.x1 + ' ' + g.base + 'Z';
      area.setAttribute('d', d);
      hatch.setAttribute('d', d);
      line.setAttribute('d', 'M' + g.x0 + ' ' + g.base + 'L' + g.x1 + ' ' + yEnd.toFixed(2));
      // Month-end cuts through the gold: twelve pours, each one adding to the pile.
      var c = '';
      for (var mo = 1; mo < MONTHS; mo++) {
        var cx = crisp(g.x(mo));
        c += 'M' + cx + ' ' + g.base + 'V' + (lineY(g, mo) + 1.5).toFixed(2);
      }
      cuts.setAttribute('d', c);
      setAttrs(endHalo, { cx: g.x1, cy: yEnd.toFixed(2) });
      setAttrs(endDot, { cx: g.x1, cy: yEnd.toFixed(2) });
      setAttrs(endText, { x: g.x1 + 4, y: (yEnd - 16).toFixed(2) });
      endText.textContent = usd.format(st.m.annual);
      if (st.hover != null) drawHover();
    }

    function drawHover() {
      var g = st.geo, mo = st.hover;
      var x = g.x(mo);
      var y = lineY(g, mo);
      setAttrs(hLine, { x1: crisp(x), x2: crisp(x), y1: g.top - 14, y2: g.base });
      setAttrs(hDot, { cx: x, cy: y });
      hMonth.textContent = 'Month ' + mo;
      hValue.textContent = usd.format(st.m.at(mo));

      // Sit the readout above the line: to the left of the hairline when it fits, else to the right.
      var wText = Math.max(hValue.textContent.length * 7.9, hMonth.textContent.length * 7.4) + 2;
      var slope = st.fill * g.plot / (g.x1 - g.x0);
      var gap = 12;
      var left = x - gap - wText > 46;
      var anchorX = left ? x - gap : x + gap;
      var probe = left ? x - gap : x + gap + wText;      // highest point of the line under the readout
      var bottom = g.base - slope * (probe - g.x0) - 10;
      bottom = Math.min(bottom, y - 10);
      bottom = Math.max(bottom, 34);
      var anchor = left ? 'end' : 'start';
      setAttrs(hValue, { x: anchorX, y: bottom.toFixed(2), 'text-anchor': anchor });
      setAttrs(hMonth, { x: anchorX, y: (bottom - 17).toFixed(2), 'text-anchor': anchor });
      gHover.classList.add('is-on');
      gEnd.classList.toggle('is-quiet', true);
    }

    function setHover(mo) {
      mo = clamp(Math.round(mo), 1, MONTHS);
      st.hover = mo;
      if (st.geo) drawHover();
    }

    function clearHover() {
      st.hover = null;
      gHover.classList.remove('is-on');
      gEnd.classList.remove('is-quiet');
    }

    function animateTo(target) {
      cancelAnimationFrame(st.raf);
      clearTimeout(st.snap);
      var still = !st.geo || document.hidden || (reduceMotion && reduceMotion.matches) ||
        Math.abs(target - st.fill) < 1e-4;
      if (still) {
        st.fill = target;
        if (st.geo) drawShape();
        return;
      }
      var from = st.fill;
      var t0 = 0;
      function frame(now) {
        if (!t0) t0 = now;
        var t = Math.min(1, (now - t0) / TWEEN_MS);
        st.fill = from + (target - from) * easeOut(t);
        drawShape();
        if (t < 1) st.raf = requestAnimationFrame(frame);
      }
      st.raf = requestAnimationFrame(frame);
      // If frames are starved (throttled tab, busy main thread), land on the true shape anyway.
      st.snap = setTimeout(function () {
        cancelAnimationFrame(st.raf);
        st.fill = target;
        drawShape();
      }, TWEEN_MS + 150);
    }

    function update(announce) {
      st.m = model(values);
      var prev = st.scale;
      st.scale = niceScale(st.m.annual);
      refreshInputs();
      refreshResult(announce);
      if (st.geo && (!prev || prev.step !== st.scale.step || prev.n !== st.scale.n)) drawStatic();
      animateTo(st.m.annual / st.scale.max);
    }

    function resize(w, h) {
      w = Math.floor(w);
      h = Math.floor(h);
      if (w < 40 || h < 80 || (w === st.w && h === st.h)) return;
      st.w = w;
      st.h = h;
      setAttrs(s, { width: w, height: h, viewBox: '0 0 ' + w + ' ' + h });
      st.geo = geometry();
      drawStatic();
      drawShape();
    }

    /* ---------- events ---------- */

    CONTROLS.forEach(function (c) {
      inputs[c.key].addEventListener('input', function (e) {
        values[c.key] = snap(parseFloat(e.target.value), c);
        update(true);
      });
    });

    var keyboardHover = false;

    function pointerMonth(e) {
      if (!st.geo) return;
      keyboardHover = false;
      var r = s.getBoundingClientRect();
      var px = e.clientX - r.left;
      setHover(((px - st.geo.x0) / (st.geo.x1 - st.geo.x0)) * MONTHS);
    }
    chart.addEventListener('pointermove', pointerMonth);
    chart.addEventListener('pointerdown', pointerMonth);
    chart.addEventListener('pointerleave', function (e) {
      // Touch keeps the last tapped month until the next tap elsewhere.
      if (e.pointerType === 'mouse' && !keyboardHover) clearHover();
    });
    document.addEventListener('pointerdown', function (e) {
      if (!chart.contains(e.target)) clearHover();
    });

    function speakMonth() {
      chartLive.textContent = 'Month ' + st.hover + ': ' + usd.format(st.m.at(st.hover));
    }
    chart.addEventListener('keydown', function (e) {
      var mo = st.hover == null ? MONTHS : st.hover;
      if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') mo -= 1;
      else if (e.key === 'ArrowRight' || e.key === 'ArrowUp') mo += 1;
      else if (e.key === 'Home') mo = 1;
      else if (e.key === 'End') mo = MONTHS;
      else if (e.key === 'Escape') { clearHover(); return; }
      else return;
      e.preventDefault();
      keyboardHover = true;
      setHover(mo);
      speakMonth();
    });
    chart.addEventListener('focus', function () {
      var kb = true;
      try { kb = chart.matches(':focus-visible'); } catch (err) { /* older engines */ }
      if (kb && st.hover == null) {
        keyboardHover = true;
        setHover(MONTHS);
      }
    });
    chart.addEventListener('blur', function () {
      keyboardHover = false;
      clearHover();
    });

    /* ---------- first paint ---------- */

    update(false);
    var box = chart.getBoundingClientRect();
    resize(box.width, box.height);

    if (window.ResizeObserver) {
      new ResizeObserver(function (entries) {
        var cr = entries[0].contentRect;
        resize(cr.width, cr.height);
      }).observe(chart);
    } else {
      window.addEventListener('resize', function () {
        var b = chart.getBoundingClientRect();
        resize(b.width, b.height);
      });
    }

    // Web fonts change the column heights the chart stretches to.
    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(function () {
        var b = chart.getBoundingClientRect();
        resize(b.width, b.height);
      });
    }
  }

  function init() {
    var roots = document.querySelectorAll('.sim');
    for (var i = 0; i < roots.length; i++) {
      if (!roots[i].classList.contains('sim--ready')) mount(roots[i], i);
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
