const { contextBridge, ipcRenderer } = require('electron');
const invoke = async (name, ...args) => {
  const result = await ipcRenderer.invoke('study:' + name, ...args);
  if (!result.ok) throw new Error(result.error);
  return result.value;
};
contextBridge.exposeInMainWorld('desktop', {
  initialize: () => invoke('initialize'),
  chooseFile: () => invoke('choose-file'),
  chooseFolder: () => invoke('choose-folder'),
  open: filename => invoke('open', filename),
  reload: () => invoke('reload'),
  refresh: () => invoke('refresh'),
  save: content => invoke('save', content),
  draft: content => ipcRenderer.send('study:draft', content),
  settings: update => ipcRenderer.send('study:settings', update),
  chatBounds: bounds => ipcRenderer.send('study:chat-bounds', bounds),
  question: text => invoke('question', text),
  attach: content => invoke('attach', content),
  answer: () => invoke('answer'),
  refreshChat: () => invoke('refresh-chat'),
  onStatus: callback => ipcRenderer.on('study:status', (_event, text) => callback(text))
});
