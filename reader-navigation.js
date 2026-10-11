const content = document.getElementById('content');
const headings = Array.from(content.querySelectorAll('h1,h2,h3,h4,h5,h6'));
const outline = document.getElementById('document-outline');
const root = { level: 0, children: [] };
const stack = [root];

for (const heading of headings) {
  if (!heading.id) {
    const base = heading.textContent.trim().toLowerCase()
      .replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s+/g, '-') || 'section';
    let id = base;
    let suffix = 2;
    while (document.getElementById(id)) id = base + '-' + suffix++;
    heading.id = id;
  }
  const node = { id: heading.id, title: heading.textContent.trim(), level: Number(heading.tagName.slice(1)), children: [] };
  while (stack[stack.length - 1].level >= node.level) stack.pop();
  stack[stack.length - 1].children.push(node);
  stack.push(node);
}

function headingTop(heading) {
  return heading.getBoundingClientRect().top + window.scrollY;
}

function getPosition() {
  let active = headings[0];
  for (const heading of headings) {
    if (headingTop(heading) > window.scrollY + 28) break;
    active = heading;
  }
  return {
    documentPath: window.readerDocumentPath,
    headingID: active ? active.id : '',
    headingOffset: active ? window.scrollY - headingTop(active) : 0,
    scrollY: window.scrollY
  };
}

function publishPosition() {
  const position = getPosition();
  let activeLink;
  for (const link of outline.querySelectorAll('a[data-heading]')) {
    const active = link.dataset.heading === position.headingID;
    link.classList.toggle('is-active', active);
    if (active) {
      link.setAttribute('aria-current', 'location');
      activeLink = link;
    }
    else link.removeAttribute('aria-current');
  }
  if (activeLink && !outline.hidden) {
    for (let group = activeLink.closest('details'); group; group = group.parentElement.closest('details')) {
      group.open = true;
    }
    const panelRect = outline.getBoundingClientRect();
    const linkRect = activeLink.getBoundingClientRect();
    const topInset = title.offsetHeight + 16;
    if (linkRect.top < panelRect.top + topInset || linkRect.bottom > panelRect.bottom - 12) {
      outline.scrollTop += linkRect.top - panelRect.top - (outline.clientHeight + topInset - linkRect.height) / 2;
    }
  }
  window.webkit?.messageHandlers?.readingPosition?.postMessage(position);
  return position;
}

function jumpToHeading(id) {
  const heading = document.getElementById(id);
  if (!heading || !content.contains(heading)) return false;
  window.scrollTo({ top: Math.max(0, headingTop(heading) - 24), behavior: 'instant' });
  publishPosition();
  return true;
}

function renderOutline(nodes) {
  const list = document.createElement('ol');
  for (const node of nodes) {
    const item = document.createElement('li');
    const link = document.createElement('a');
    link.textContent = node.title || '未命名标题';
    link.title = node.title;
    link.href = '#' + encodeURIComponent(node.id);
    link.dataset.heading = node.id;
    link.addEventListener('click', event => {
      event.preventDefault();
      event.stopPropagation();
      jumpToHeading(node.id);
    });
    if (node.children.length) {
      const group = document.createElement('details');
      group.open = true;
      const summary = document.createElement('summary');
      summary.append(link);
      group.append(summary, renderOutline(node.children));
      item.append(group);
    } else {
      item.classList.add('outline-leaf');
      item.append(link);
    }
    list.append(item);
  }
  return list;
}

const title = document.createElement('div');
title.className = 'outline-title';
title.textContent = '文档大纲';
outline.append(title, renderOutline(root.children));
if (!headings.length) {
  const empty = document.createElement('p');
  empty.className = 'outline-empty';
  empty.textContent = '此文档暂无标题';
  outline.append(empty);
}

function setOutlineVisible(visible) {
  outline.hidden = !visible;
  publishPosition();
  return visible;
}

function restorePosition(position) {
  if (!position) return;
  const heading = document.getElementById(position.headingID);
  const top = heading && content.contains(heading)
    ? headingTop(heading) + position.headingOffset
    : position.scrollY;
  window.scrollTo({ top: Math.max(0, top || 0), behavior: 'instant' });
  publishPosition();
}

window.readerNavigation = { jumpToHeading, getPosition, restorePosition, setOutlineVisible };
setOutlineVisible(window.readerOutlineVisible);
window.addEventListener('scroll', publishPosition, { passive: true });
window.addEventListener('pagehide', publishPosition);
restorePosition(window.readerSavedPosition);
publishPosition();
