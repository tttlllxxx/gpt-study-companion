const { app, BrowserWindow, WebContentsView, ipcMain, dialog, clipboard, shell, Menu } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const files = require('./files.cjs');
const root = path.join(__dirname, '..');
const welcome = path.join(root, 'examples', 'Welcome.md');
const selfTest = process.argv.includes('--self-test');
if (selfTest) app.setPath('userData', path.join(app.getPath('temp'), 'gpt-study-desktop-test-' + process.pid));
let win, chat, document, state = {}, settingsFile, saveTimer, saveTail = Promise.resolve(), draft = '', allowClose = false;
let library = [];
const asset = name => fs.readFile(path.join(root, name), 'utf8');
const status = text => win.webContents.send('study:status', text);

function persistSettings() {
  const content = JSON.stringify(state, null, 2);
  saveTail = saveTail.catch(() => {}).then(() => files.atomicWrite(settingsFile, content));
  return saveTail;
}

async function confirmLeaving() {
  if (!document || draft === document.content) return true;
  const { response } = await dialog.showMessageBox(win, {
    type: 'question', message: '当前文档有未保存的修改',
    buttons: ['保存并继续', '放弃修改', '取消'], defaultId: 0, cancelId: 2
  });
  if (response === 2) return false;
  if (response === 0) {
    if (document.readOnly) throw new Error('欢迎文档仅供阅读。');
    document = await files.saveDocument(document, draft);
  }
  return true;
}

async function openDocument(filename, proposedRoot = state.root, proposedLibrary = library) {
  if (!(await confirmLeaving())) return null;
  const next = await files.readDocument(filename);
  next.readOnly = filename === welcome;
  next.baseURL = pathToFileURL(path.dirname(filename) + path.sep).href;
  document = next;
  state.root = proposedRoot;
  library = proposedLibrary;
  draft = next.content;
  state.lastDocument = filename;
  let warning;
  try { await persistSettings(); } catch (error) { warning = '文档已打开，但设置未保存：' + error.message; }
  win.setTitle(next.name + ' — GPT 学习伴侣');
  return { document: next, library, root: state.root, position: state.positions?.[filename] || null, warning };
}

function handle(name, callback) {
  ipcMain.handle('study:' + name, async (event, ...args) => {
    if (event.sender !== win.webContents) return { ok: false, error: '不允许的调用来源' };
    try { return { ok: true, value: await callback(...args) }; }
    catch (error) { return { ok: false, error: error.message }; }
  });
}

async function fillComposer(text) {
  const message = await chat.webContents.executeJavaScript(`(() => {
    const editor = window.studyChatComposer?.find();
    if (!editor) throw new Error('请先登录 ChatGPT 并打开聊天输入框');
    const draft = window.studyChatComposer.read(editor);
    window.studyChatComposer.selectContents(editor);
    return draft.trim() ? draft + '\\n\\n' + ${JSON.stringify(text)} : ${JSON.stringify(text)};
  })()`, true);
  chat.webContents.focus();
  await chat.webContents.insertText(message);
    const actual = await chat.webContents.executeJavaScript(`(async () => {
      await new Promise(resolve => setTimeout(resolve, 0));
      const editor = window.studyChatComposer.find();
      return editor ? window.studyChatComposer.read(editor) : null;
    })()`, true);
    // Chromium can expose an extra blank line between contenteditable paragraphs.
    const normalize = value => value?.replace(/\r\n/g, '\n').replace(/\u00a0/g, ' ').replace(/\n{3,}/g, '\n\n').replace(/\n+$/, '');
    if (normalize(actual) !== normalize(message)) {
      throw new Error('输入框未保留完整内容，请刷新后重试');
    }
  status('已加入 GPT 输入框，请检查后发送');
}

function installIPC() {
  handle('initialize', async () => {
    let filename = state.lastDocument || welcome;
    try { await fs.access(filename); } catch { filename = welcome; }
    try { library = state.root ? await files.listDocuments(state.root) : [welcome]; }
    catch { state.root = null; library = [welcome]; }
    const opened = await openDocument(filename);
    return { ...opened, settings: state, css: await asset('reader.css'), navigation: await asset('reader-navigation.js') };
  });
  handle('choose-file', async () => {
    const result = await dialog.showOpenDialog(win, { properties: ['openFile'], filters: [{ name: 'Markdown', extensions: ['md', 'markdown'] }] });
    if (result.canceled) return null;
    const folder = path.dirname(result.filePaths[0]);
    return openDocument(result.filePaths[0], folder, await files.listDocuments(folder));
  });
  handle('choose-folder', async () => {
    const result = await dialog.showOpenDialog(win, { properties: ['openDirectory'] });
    if (result.canceled) return null;
    const discovered = await files.listDocuments(result.filePaths[0]);
    if (!discovered.length) throw new Error('目录中没有 Markdown 文档');
    return openDocument(discovered.includes(document.path) ? document.path : discovered[0], result.filePaths[0], discovered);
  });
  handle('open', async filename => {
    if (!library.includes(filename)) throw new Error('请选择文档库里的文件');
    return openDocument(filename);
  });
  handle('reload', () => openDocument(document.path));
  handle('refresh', async () => { library = state.root ? await files.listDocuments(state.root) : [welcome]; return library; });
  handle('save', async content => {
    if (document.readOnly) throw new Error('请先打开自己的文档');
    document = await files.saveDocument(document, content);
    draft = content;
    status('已保存当前文档');
    return document;
  });
  handle('question', fillComposer);
  handle('attach', async content => {
    const source = await asset('chat-attachment.js');
    const prompt = `我正在学习附件《${document.name}》。请将它作为本次对话的学习背景，结合章节解释并提供例子，区分原文与补充说明。先简短确认文档主题与章节，再等待我的具体问题。`;
    const result = await chat.webContents.executeJavaScript(`(async (content,filename,studyPrompt) => {${source}\n})(${JSON.stringify(content)},${JSON.stringify(document.name)},${JSON.stringify(prompt)})`, true);
    if (result !== 'queued') throw new Error(result === 'no-file-input' ? '请先展开 ChatGPT 的附件菜单后重试' : '请确认 ChatGPT 输入框已就绪');
    status('附件和学习提示词已加入，上传完成后可发送');
  });
  handle('answer', async () => (await chat.webContents.executeJavaScript('window.getSelection().toString()')).trim() || clipboard.readText());
  handle('refresh-chat', () => chat.webContents.reload());
  ipcMain.on('study:draft', (event, content) => { if (event.sender === win.webContents && typeof content === 'string') draft = content; });
  ipcMain.on('study:settings', (event, update) => {
    if (event.sender !== win.webContents) return;
    if (update.position && document && update.position.documentPath === document.path) {
      state.positions ||= {};
      state.positions[document.path] = update.position;
    }
    for (const key of ['sidebarHidden', 'outlineVisible', 'sidebarWidth', 'chatFraction']) if (key in update) state[key] = update[key];
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => persistSettings().catch(error => status(error.message)), 250);
  });
  ipcMain.on('study:chat-bounds', (event, bounds) => {
    if (event.sender !== win.webContents) return;
    const [width, height] = win.getContentSize();
    const x = Math.max(0, Math.min(width, Math.round(bounds.x)));
    const y = Math.max(0, Math.min(height, Math.round(bounds.y)));
    chat.setBounds({ x, y, width: Math.max(1, width - x), height: Math.max(1, height - y - 24) });
  });
}

app.whenReady().then(async () => {
  settingsFile = path.join(app.getPath('userData'), 'settings.json');
  await fs.mkdir(app.getPath('userData'), { recursive: true });
  try { state = JSON.parse(await fs.readFile(settingsFile, 'utf8')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  win = new BrowserWindow({ width: 1440, height: 900, minWidth: 920, minHeight: 620, icon: path.join(root, 'assets', 'app-icon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, sandbox: true, nodeIntegration: false } });
  chat = new WebContentsView({ webPreferences: { partition: 'persist:chatgpt', contextIsolation: true, sandbox: true, nodeIntegration: false } });
  win.contentView.addChildView(chat);
  chat.webContents.on('dom-ready', async () => {
    try { await chat.webContents.executeJavaScript(await asset('chat-composer.js')); }
    catch (error) { status(error.message); }
  });
  chat.webContents.on('did-navigate-in-page', (_event, url) => {
    const parsed = new URL(url);
    if (parsed.hostname === 'chatgpt.com' && (/^\/c\//.test(parsed.pathname) || parsed.pathname === '/')) { state.chatURL = parsed.origin + parsed.pathname; }
  });
  chat.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) chat.webContents.loadURL(url).catch(error => status(error.message));
    return { action: 'deny' };
  });
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/.test(url)) shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', event => event.preventDefault());
  installIPC();
  Menu.setApplicationMenu(Menu.buildFromTemplate([{ label: '编辑', submenu: [{ role: 'undo' }, { role: 'redo' }, { type: 'separator' }, { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }] }]));
  win.on('close', event => {
    if (allowClose) return;
    event.preventDefault();
    (async () => {
      if (!(await confirmLeaving())) return;
      clearTimeout(saveTimer);
      await persistSettings().catch(error => dialog.showErrorBox('设置未保存', error.message));
      await chat.webContents.session.flushStorageData();
      allowClose = true;
      chat.webContents.close();
      win.close();
    })().catch(error => dialog.showErrorBox('无法关闭', error.message));
  });
  await win.loadFile(path.join(__dirname, 'index.html'));
  if (selfTest) await require('./smoke.cjs')({ win, chat, app, fillComposer });
  else await chat.webContents.loadURL(state.chatURL && /^https:\/\/chatgpt\.com\//.test(state.chatURL) ? state.chatURL : 'https://chatgpt.com').catch(error => status('ChatGPT 加载失败，文档仍可使用：' + error.message));
}).catch(error => { console.error(error); app.exit(1); });
app.on('window-all-closed', () => app.quit());
