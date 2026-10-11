(() => {
  function find() {
    const root = document.getElementById('prompt-textarea');
    const candidates = [
      root,
      ...(root ? root.querySelectorAll('textarea, [contenteditable="true"]') : []),
      ...document.querySelectorAll('#composer-text-input [contenteditable="true"], form textarea, form [contenteditable="true"], textarea[placeholder*="ChatGPT"], [contenteditable="true"][data-placeholder*="ChatGPT"], [role="textbox"][aria-label*="ChatGPT"]')
    ];
    return candidates.find(element => {
      if (!element || !element.getClientRects().length || element.disabled || element.readOnly) return false;
      if (element.closest('[hidden], [aria-hidden="true"]') || getComputedStyle(element).visibility === 'hidden') return false;
      if (element.closest('pre, code, [data-message-author-role], .cm-editor, .monaco-editor, [aria-label="编辑代码"], [aria-label="Edit code"]')) return false;
      return element.tagName === 'TEXTAREA' || element.isContentEditable;
    });
  }

  function read(element) {
    return element.tagName === 'TEXTAREA' ? element.value : element.innerText;
  }

  function selectContents(element) {
    element.focus();
    if (element.tagName === 'TEXTAREA') {
      element.select();
    } else {
      const range = document.createRange();
      range.selectNodeContents(element);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
  }

  window.studyChatComposer = { find, read, selectContents };
})();
