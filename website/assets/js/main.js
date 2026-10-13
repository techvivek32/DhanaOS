(function () {
  'use strict';

  var year = document.getElementById('year');
  if (year) year.textContent = String(new Date().getFullYear());

  // Copy the contact email. Falls back to selecting the address when the clipboard is refused.
  var copyBtn = document.getElementById('copy-email');
  var emailText = document.getElementById('contact-email');
  if (!copyBtn || !emailText) return;

  var label = copyBtn.querySelector('span');
  var resetTimer;

  function flash(text) {
    if (!label) return;
    label.textContent = text;
    clearTimeout(resetTimer);
    resetTimer = setTimeout(function () { label.textContent = 'Copy email'; }, 2000);
  }

  function selectAddress() {
    var range = document.createRange();
    range.selectNodeContents(emailText);
    var sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
    flash('Press Ctrl+C to copy');
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
