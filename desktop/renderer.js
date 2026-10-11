const $ = id => document.getElementById(id);
let current, library = [], directory, settings = {}, css = '', navigation = '', selectedText = '', editing = false;
const positions = {};
const status = text => { $('status').textContent = text; };
const run = async action => { try { return await action(); } catch (error) { status(error.message); window.alert(error.message); } };
const scriptJSON = value => JSON.stringify(value).replace(/</g, '\\u003c');
const frameCommand = (name, value) => $('reader').contentWindow.postMessage({ type: 'command', name, value }, '*');

function updateBounds() {
  const bounds = $('chat-slot').getBoundingClientRect();
  window.desktop.chatBounds({ x: bounds.x, y: bounds.y });
}

function renderReading() {
  const html = DOMPurify.sanitize(marked.parse($('editor').value, { gfm: true }));
  const bookmark = positions[current.path] || settings.positions?.[current.path] || null;
  $('reader').srcdoc = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><base href="${current.baseURL}"><style>${css}</style></head><body><main class="reader-layout"><article id="content">${html}</article><nav id="document-outline" class="outline-panel" aria-label="文档大纲"></nav></main><script>
    window.readerDocumentPath = ${scriptJSON(current.path)};
    window.readerSavedPosition = ${scriptJSON(bookmark)};
    window.readerOutlineVisible = ${settings.outlineVisible !== false};
    window.webkit = { messageHandlers: { readingPosition: { postMessage: position => parent.postMessage({type:'position',position},'*') } } };
    ${navigation}
    document.addEventListener('selectionchange', () => parent.postMessage({type:'selection',documentPath:window.readerDocumentPath,text:window.getSelection().toString()},'*'));
    window.addEventListener('message', event => {
      if(event.source !== parent || event.data.type !== 'command') return;
      const {name,value} = event.data;
      if(name === 'outline') window.readerNavigation.setOutlineVisible(value);
      if(name === 'find') window.find(value,false,false,true,false,true,false);
      if(name === 'position') parent.postMessage({type:'position',position:window.readerNavigation.getPosition()},'*');
    });
    parent.postMessage({type:'reader-ready',documentPath:window.readerDocumentPath},'*');
  </script></body></html>`;
}

function showDocument(result) {
  if (!result) return;
  current = result.document; library = result.library; directory = result.root;
  if (result.position) positions[current.path] = result.position;
  $('document-name').textContent = current.name;
  $('document-path').textContent = current.path;
  $('editor').value = current.content;
  $('editor').readOnly = current.readOnly;
  $('mode').disabled = current.readOnly;
  $('save').disabled = current.readOnly;
  selectedText = '';
  renderFiles(); renderReading();
  status(result.warning || '已打开 ' + current.name);
}

function renderFiles() {
  $('library-name').textContent = directory ? directory.split(/[\\/]/).filter(Boolean).at(-1) : '文档库';
  const tree = {};
  for (const filename of library) {
    const relative = directory && filename.startsWith(directory) ? filename.slice(directory.length + 1) : filename.split(/[\\/]/).at(-1);
    const parts = relative.split(/[\\/]/); let branch = tree;
    for (const part of parts.slice(0,-1)) branch = (branch[part] ||= {});
    branch[parts.at(-1)] = filename;
  }
  const build = branch => {
    const fragment = document.createDocumentFragment();
    for (const [name, entry] of Object.entries(branch).sort(([a, av], [b, bv]) => (typeof av === 'string') - (typeof bv === 'string') || a.localeCompare(b,'zh-CN',{numeric:true}))) {
      if (typeof entry === 'string') {
        const button = document.createElement('button'); button.textContent = '▤ ' + name.replace(/\.(md|markdown)$/i,''); button.title = entry;
        button.classList.toggle('active', entry === current.path);
        button.onclick = () => run(async () => showDocument(await window.desktop.open(entry)));
        fragment.append(button);
      } else {
        const group = document.createElement('details'); const summary = document.createElement('summary'); summary.textContent = name;
        group.open = current.path.includes(name + '\\') || current.path.includes(name + '/');
        const children = document.createElement('div'); children.className = 'children'; children.append(build(entry));
        group.append(summary,children); fragment.append(group);
      }
    }
    return fragment;
  };
  $('files').replaceChildren(build(tree));
}

window.addEventListener('message', event => {
  if (event.source !== $('reader').contentWindow) return;
  const data = event.data;
  if (data.type === 'reader-ready' && data.documentPath === current?.path) {
    window.studyReady = true;
    window.dispatchEvent(new Event('study-ready'));
  }
  if (data.type === 'position' && data.position.documentPath === current?.path) {
    positions[current.path] = data.position;
    window.desktop.settings({ position: data.position });
  }
  if (data.type === 'selection' && data.documentPath === current?.path) selectedText = data.text;
});
$('editor').oninput = () => window.desktop.draft($('editor').value);
$('editor').onselect = () => { if (editing) selectedText = $('editor').value.slice($('editor').selectionStart, $('editor').selectionEnd); };
const chooseFolder = () => run(async () => showDocument(await window.desktop.chooseFolder()));
$('open-folder').onclick = chooseFolder; $('open-folder-ribbon').onclick = chooseFolder;
$('open-file').onclick = () => run(async () => showDocument(await window.desktop.chooseFile()));
$('refresh-files').onclick = () => run(async () => { library = await window.desktop.refresh(); renderFiles(); });
$('collapse-files').onclick = () => $('files').querySelectorAll('details').forEach(group => { group.open = false; });
const toggleSidebar = () => {
  settings.sidebarHidden = !document.body.classList.contains('sidebar-hidden');
  document.body.classList.toggle('sidebar-hidden', settings.sidebarHidden);
  window.desktop.settings({ sidebarHidden: settings.sidebarHidden }); updateBounds();
};
$('sidebar-toggle').onclick = toggleSidebar; $('hide-sidebar').onclick = toggleSidebar;
$('mode').onclick = () => {
  editing = !editing;
  $('mode').textContent = editing ? '阅读' : '编辑';
  $('reader').hidden = editing; $('editor').hidden = !editing;
  if (!editing) renderReading(); else $('editor').focus();
};
$('outline').onclick = () => { settings.outlineVisible = settings.outlineVisible === false; frameCommand('outline',settings.outlineVisible); window.desktop.settings({ outlineVisible: settings.outlineVisible }); };
const toggleSearch = () => { $('search-row').hidden = !$('search-row').hidden; if (!$('search-row').hidden) $('search').focus(); updateBounds(); };
$('search-toggle').onclick = toggleSearch; $('search-close').onclick = toggleSearch;
$('find-next').onclick = () => {
  const query = $('search').value;
  if (!query) return;
  if (!editing) frameCommand('find',query);
  else {
    const source = $('editor').value; let index = source.indexOf(query,$('editor').selectionEnd); if (index < 0) index = source.indexOf(query);
    if (index >= 0) { $('editor').focus(); $('editor').setSelectionRange(index,index+query.length); }
  }
};
$('search').onkeydown = event => { if (event.key === 'Enter') $('find-next').click(); };
$('save').onclick = () => run(async () => { current = { ...current, ...await window.desktop.save($('editor').value) }; });
$('reload').onclick = () => run(async () => showDocument(await window.desktop.reload()));
$('ask').onclick = () => run(async () => {
  const text = editing ? $('editor').value.slice($('editor').selectionStart,$('editor').selectionEnd) : selectedText;
  if (!text.trim()) throw new Error('请先在文档中选中一段文字');
  const question = $('question').value.trim() || '请解释下面这段内容，说明核心概念并给出例子。';
  await window.desktop.question(question + '\n\n文档片段：\n' + text);
  $('question').value = '';
});
$('question').onkeydown = event => { if (event.key === 'Enter') $('ask').click(); };
$('attach').onclick = () => run(() => window.desktop.attach($('editor').value));
$('refresh-chat').onclick = () => run(() => window.desktop.refreshChat());
$('insert').onclick = () => run(async () => {
  if (!editing || current.readOnly) throw new Error('请先切换到编辑模式并放置光标');
  const answer = (await window.desktop.answer()).trim();
  if (!answer) throw new Error('请先选中或复制右侧回答');
  $('editor').setRangeText('\n\n' + answer + '\n\n', $('editor').selectionStart,$('editor').selectionEnd,'end');
  window.desktop.draft($('editor').value);
  current = { ...current, ...await window.desktop.save($('editor').value) };
});

function installDivider(id, resize) {
  $(id).onpointerdown = event => {
    event.preventDefault(); $(id).setPointerCapture(event.pointerId); $(id).classList.add('dragging');
    $(id).onpointermove = move => { resize(move.clientX); updateBounds(); };
    $(id).onpointerup = () => { $(id).onpointermove = null; $(id).classList.remove('dragging'); window.desktop.settings({ sidebarWidth: settings.sidebarWidth, chatFraction: settings.chatFraction }); };
  };
}
installDivider('sidebar-divider', x => { settings.sidebarWidth = Math.max(150,Math.min(420,x-44)); document.documentElement.style.setProperty('--sidebar',settings.sidebarWidth+'px'); });
installDivider('chat-divider', x => { settings.chatFraction = Math.max(.23, Math.min(.55,(innerWidth-x)/innerWidth)); document.documentElement.style.setProperty('--chat',(settings.chatFraction*100)+'%'); });
window.addEventListener('resize',updateBounds);
window.addEventListener('keydown', event => {
  if (!(event.ctrlKey || event.metaKey)) return;
  if (event.key.toLowerCase() === 's') { event.preventDefault(); $('save').click(); }
  if (event.key.toLowerCase() === 'f') { event.preventDefault(); if ($('search-row').hidden) toggleSearch(); else $('search').focus(); }
  if (event.key === '\\') { event.preventDefault(); toggleSidebar(); }
});
window.desktop.onStatus(status);
run(async () => {
  const result = await window.desktop.initialize();
  settings = result.settings; css = result.css; navigation = result.navigation;
  document.body.classList.toggle('sidebar-hidden',Boolean(settings.sidebarHidden));
  if (settings.sidebarWidth) document.documentElement.style.setProperty('--sidebar',settings.sidebarWidth+'px');
  if (settings.chatFraction) document.documentElement.style.setProperty('--chat',(settings.chatFraction*100)+'%');
  showDocument(result); updateBounds();
});
