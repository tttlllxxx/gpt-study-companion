const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { listDocuments, readDocument, saveDocument } = require('../files.cjs');

test('a library includes nested Markdown and excludes other files and hidden folders', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(),'study-files-'));
  t.after(() => fs.rm(root,{recursive:true,force:true}));
  await fs.mkdir(path.join(root,'课程'));
  await fs.mkdir(path.join(root,'.hidden'));
  await fs.writeFile(path.join(root,'第一课.md'),'# 一');
  await fs.writeFile(path.join(root,'课程','第二课.markdown'),'# 二');
  await fs.writeFile(path.join(root,'.hidden','秘密.md'),'hidden');
  await fs.writeFile(path.join(root,'image.png'),'not Markdown');
  assert.equal((await listDocuments(root)).length,2);
});

test('saving targets only the current file; older external revisions and deleted files are never overwritten', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(),'study-save-'));
  t.after(() => fs.rm(root,{recursive:true,force:true}));
  const file = path.join(root,'note.md'); const other = path.join(root,'other.md');
  await fs.writeFile(file,'原文'); await fs.writeFile(other,'另一个文件');
  let document = await readDocument(file);
  document = await saveDocument(document,'中文 😀\n新笔记');
  assert.equal(await fs.readFile(file,'utf8'),'中文 😀\n新笔记');
  assert.equal(await fs.readFile(other,'utf8'),'另一个文件');
  await fs.utimes(file,new Date(),new Date(document.mtime-60000));
  await assert.rejects(saveDocument(document,'错误覆盖'),/其他程序修改/);
  assert.equal(await fs.readFile(file,'utf8'),'中文 😀\n新笔记');
  await fs.rm(file);
  await assert.rejects(saveDocument(document,'错误重建'),/删除/);
  await assert.rejects(fs.access(file));
  assert.equal((await fs.readdir(root)).some(name => name.endsWith('.tmp')),false);
});

test('an external edit preserving the exact mtime is not overwritten', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(),'study-preserved-time-'));
  t.after(() => fs.rm(root,{recursive:true,force:true}));
  const filename = path.join(root,'note.md');
  const stamp = new Date('2020-01-01T00:00:00Z');
  await fs.writeFile(filename,'读取时的原文');
  await fs.utimes(filename,stamp,stamp);
  const document = await readDocument(filename);
  await fs.writeFile(filename,'外部改写的内容');
  await fs.utimes(filename,stamp,stamp);
  await assert.rejects(saveDocument(document,'本地编辑'),/其他程序修改/);
  assert.equal(await fs.readFile(filename,'utf8'),'外部改写的内容');
});
