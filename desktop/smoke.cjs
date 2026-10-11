const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');

module.exports = async ({ win, chat, app, fillComposer }) => {
  const timeout = setTimeout(() => { console.error('Desktop smoke test timed out'); app.exit(1); },60000);
  try {
    await win.webContents.executeJavaScript(`new Promise(resolve => { if(window.studyReady) resolve(); else window.addEventListener('study-ready',resolve,{once:true}); })`);
    const state = await win.webContents.executeJavaScript(`({title:document.getElementById('document-name').textContent,readonly:document.getElementById('editor').readOnly})`);
    assert.equal(state.title,'Welcome.md'); assert.equal(state.readonly,true);
    const frame = win.webContents.mainFrame.frames[0];
    const reader = await frame.executeJavaScript(`({headings:document.querySelectorAll('#content h1,h2').length,outline:document.querySelectorAll('#document-outline a').length})`);
    assert(reader.headings >= 5); assert.equal(reader.headings,reader.outline);
    await win.webContents.executeJavaScript(`document.getElementById('sidebar-toggle').click()`);
    assert.equal(await win.webContents.executeJavaScript(`document.body.classList.contains('sidebar-hidden')`),true);
    await win.webContents.executeJavaScript(`document.getElementById('sidebar-toggle').click()`);
    const constructorFolder = await win.webContents.executeJavaScript(`(() => {
      directory = 'C:/notes';
      library = ['C:/notes/constructor/child.md'];
      current.path = library[0];
      renderFiles();
      return document.getElementById('files').textContent.includes('child');
    })()`);
    assert.equal(constructorFolder,true,'Folders named constructor must remain visible in the file tree');
    await chat.webContents.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(`<div data-message-author-role="assistant"><textarea>print('keep')</textarea></div><form><div contenteditable="true">原有问题</div></form>`));
    await chat.webContents.executeJavaScript(await fs.readFile(path.join(__dirname,'..','chat-composer.js'),'utf8'));
    await fillComposer('文档片段：中文问题 😀');
    const filled = await chat.webContents.executeJavaScript(`({text:window.studyChatComposer.read(window.studyChatComposer.find()),code:document.querySelector('textarea').value})`);
    assert.equal(filled.text.trim().replace(/\n{3,}/g,'\n\n'),'原有问题\n\n文档片段：中文问题 😀'); assert.equal(filled.code,"print('keep')");
    console.log('PASS: desktop startup, read-only welcome, heading outline, sidebar toggling, native chat paste and code editor exclusion');
    clearTimeout(timeout);
    app.exit(0);
  } catch(error) { clearTimeout(timeout); console.error(error); app.exit(1); }
};
