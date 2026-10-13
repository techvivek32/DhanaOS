/* DhanaOS site: footer year, sheets that draw themselves on arrival, nav focus, copy-email button.
   The page reads fine without any of this. */
(function () {
  'use strict';

  var year = document.getElementById('year');
  if (year) year.textContent = String(new Date().getFullYear());

  // Sheets wait, then plot their line work when they scroll into view. Nothing is measured
  // here: the observer's first callback releases any sheet that is already on screen, so the
  // page is never forced through a layout before its first paint.
  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (!reduce && 'IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.remove('wait'); io.unobserve(e.target); }
      });
    }, { rootMargin: '0px 0px -15% 0px' });
    [].slice.call(document.querySelectorAll('.sheet[data-draw]')).forEach(function (s) {
      s.classList.add('wait');
      io.observe(s);
    });
    // Printing never scrolls, so release every sheet still waiting.
    window.addEventListener('beforeprint', function () {
      [].slice.call(document.querySelectorAll('.sheet.wait')).forEach(function (s) {
        s.classList.remove('wait');
        io.unobserve(s);
      });
    });
  }

  // Phone and tablet nav scrolls sideways: bring a focused link fully into view.
  var navLinks = document.querySelector('.nav-links');
  if (navLinks) {
    navLinks.addEventListener('focusin', function (e) {
      if (e.target && e.target.scrollIntoView) e.target.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    });
  }

  // Copy the contact email. Falls back to selecting the address when the clipboard is refused.
  var copyBtn = document.getElementById('copy-email');
  var address = document.getElementById('contact-email');
  if (!copyBtn || !address) return;

  var label = copyBtn.querySelector('.copy-label');
  var status = document.getElementById('copy-status');
  var isMac = /Mac|iP(hone|ad|od)/.test(navigator.platform || navigator.userAgent);
  var resetTimer;

  function flash(text) {
    if (!label) return;
    label.textContent = text;
    if (status) status.textContent = text === 'Copied' ? 'Email address copied' : 'Address selected. Copy it with ' + (isMac ? 'Command C' : 'Control C') + '.';
    clearTimeout(resetTimer);
    resetTimer = setTimeout(function () { label.textContent = 'Copy'; }, 2000);
  }

  function selectAddress() {
    var range = document.createRange();
    range.selectNodeContents(address);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    flash(isMac ? 'Press ⌘C' : 'Press Ctrl+C');
  }

  copyBtn.addEventListener('click', function () {
    var value = copyBtn.getAttribute('data-copy');
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(value).then(function () { flash('Copied'); }, selectAddress);
    } else {
      selectAddress();
    }
  });
})();
