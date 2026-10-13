(function () {
  'use strict';

  var year = document.getElementById('year');
  if (year) year.textContent = String(new Date().getFullYear());

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
