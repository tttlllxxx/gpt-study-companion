// ChatGPT's web UI has no stable upload API; keep the file-input selectors here.
const composer = window.studyChatComposer.find();
if (!composer) return 'not-ready';

const findFileInput = () => Array.from(document.querySelectorAll('input[type="file"]')).find(input => {
  const accept = input.accept.toLowerCase();
  return !input.disabled && (!accept || accept.includes('.md') || accept.includes('.markdown')
    || accept.includes('.txt') || accept.includes('text/') || accept.includes('application/')
    || accept.includes('*/*'));
});

let input = findFileInput();
if (!input) {
  const addButton = document.querySelector('button[data-testid="composer-plus-btn"]');
  if (addButton) {
    addButton.click();
    await new Promise(resolve => setTimeout(resolve, 150));
    input = findFileInput();
  }
}
if (!input) return 'no-file-input';

const existingDraft = window.studyChatComposer.read(composer);
const message = existingDraft.trim()
  ? existingDraft + '\n\n附件学习背景：\n' + studyPrompt
  : studyPrompt;
window.studyChatComposer.selectContents(composer);
if (composer.tagName === 'TEXTAREA') {
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(composer, message);
  composer.dispatchEvent(new Event('input', { bubbles: true }));
} else {
  if (!document.execCommand('insertText', false, message)) return 'prompt-failed';
}

const transfer = new DataTransfer();
transfer.items.add(new File([content], filename, { type: 'text/markdown' }));
input.files = transfer.files;
input.dispatchEvent(new Event('input', { bubbles: true }));
input.dispatchEvent(new Event('change', { bubbles: true }));
composer.focus();
return 'queued';
