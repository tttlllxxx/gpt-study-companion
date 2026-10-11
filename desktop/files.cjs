const fs = require('node:fs/promises');
const path = require('node:path');
const { randomUUID } = require('node:crypto');

async function listDocuments(root) {
  const files = [];
  async function visit(directory) {
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      if (entry.name.startsWith('.') || entry.name === 'node_modules') continue;
      const filename = path.join(directory, entry.name);
      if (entry.isDirectory() && !entry.name.endsWith('.app')) await visit(filename);
      else if (entry.isFile() && /\.(md|markdown)$/i.test(entry.name)) files.push(filename);
    }
  }
  await visit(root);
  return files.sort((a, b) => a.localeCompare(b, 'zh-CN', { numeric: true }));
}

async function readDocument(filename) {
  const [content, stat] = await Promise.all([fs.readFile(filename, 'utf8'), fs.stat(filename)]);
  return { path: filename, name: path.basename(filename), content, mtime: stat.mtimeMs };
}

async function atomicWrite(filename, content, mode) {
  const temporary = path.join(path.dirname(filename), '.' + path.basename(filename) + '.' + randomUUID() + '.tmp');
  try {
    await fs.writeFile(temporary, content, { encoding: 'utf8', mode });
    await fs.rename(temporary, filename);
  } finally {
    await fs.rm(temporary, { force: true });
  }
}

async function saveDocument(document, content) {
  let stat;
  try { stat = await fs.stat(document.path); }
  catch (error) {
    if (error.code === 'ENOENT') throw new Error('文档已被删除，请另存或重新打开；未覆盖文件。');
    throw error;
  }
  if (stat.mtimeMs !== document.mtime) throw new Error('文档已被其他程序修改，请保留当前编辑内容并重新打开。');
  await atomicWrite(document.path, content, stat.mode);
  return readDocument(document.path);
}

module.exports = { listDocuments, readDocument, saveDocument, atomicWrite };
