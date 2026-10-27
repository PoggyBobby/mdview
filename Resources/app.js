/* MDView page runtime — inlined into viewer.html by the app. */
(function () {
  'use strict';
  const content = document.getElementById('content');
  const toc = document.getElementById('toc');
  const findbar = document.getElementById('findbar');
  const findInput = document.getElementById('find-input');
  const findCount = document.getElementById('find-count');
  const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const post = (type, body) => { try { window.webkit.messageHandlers.mdv.postMessage(Object.assign({ type }, body || {})); } catch (e) { } };

  // ---------- marked configuration ----------
  const slugCounts = Object.create(null);
  function slug(html) {
    let s = html.replace(/<[^>]+>/g, '').replace(/&[a-z#0-9]+;/gi, ' ').toLowerCase()
      .replace(/[^\p{L}\p{N}\s_-]/gu, '').trim().replace(/[\s_]+/g, '-');
    if (!s) s = 'section';
    const n = slugCounts[s] || 0; slugCounts[s] = n + 1;
    return n ? `${s}-${n}` : s;
  }
  const renderer = {
    heading({ tokens, depth }) {
      const html = this.parser.parseInline(tokens);
      const id = slug(html);
      return `<h${depth} id="${id}"><a class="anchor" href="#${id}" aria-hidden="true">#</a>${html}</h${depth}>\n`;
    },
    code({ text, lang }) {
      const l = (lang || '').trim().split(/\s+/)[0].toLowerCase();
      let body, cls = 'hljs';
      if (l && hljs.getLanguage(l)) { body = hljs.highlight(text, { language: l, ignoreIllegals: true }).value; cls += ' language-' + esc(l); }
      else body = esc(text);
      return `<div class="codeblock">${l ? `<span class="lang">${esc(l)}</span>` : ''}<button class="copy" type="button">Copy</button><pre><code class="${cls}">${body}</code></pre></div>\n`;
    },
    blockquote({ tokens }) {
      let html = this.parser.parse(tokens);
      const m = /^<p>\[!([A-Za-z]+)\]([+-]?)[ \t]*([^\n<]*)(?:\n|<br>)?/.exec(html);
      if (m) {
        const type = m[1].toLowerCase();
        const title = m[3].trim() || type.charAt(0).toUpperCase() + type.slice(1);
        html = html.slice(m[0].length);
        html = html.startsWith('</p>') ? html.slice(4) : '<p>' + html;
        return `<div class="callout callout-${esc(type)}"><div class="callout-title">${esc(title)}</div><div class="callout-body">${html}</div></div>\n`;
      }
      return `<blockquote>\n${html}</blockquote>\n`;
    }
  };
  const wikilink = {
    name: 'wikilink', level: 'inline',
    start(src) { return src.indexOf('[['); },
    tokenizer(src) {
      const m = /^(!?)\[\[([^\]|#]+?)(?:#([^\]|]*))?(?:\|([^\]]*))?\]\]/.exec(src);
      if (!m) return;
      return { type: 'wikilink', raw: m[0], embed: !!m[1], target: m[2].trim(), anchor: (m[3] || '').trim(), text: (m[4] || m[2]).trim() };
    },
    renderer(t) {
      if (t.embed) {
        if (/\.(png|jpe?g|gif|svg|webp|bmp|avif|heic|tiff?)$/i.test(t.target)) {
          const w = /^\d+$/.test(t.text) ? ` width="${t.text}"` : '';
          return `<img src="${esc(t.target)}" alt="${esc(t.target)}"${w}>`;
        }
        return `<span class="embed">[[${esc(t.target)}]]</span>`;
      }
      return `<a class="wikilink" href="wiki:${encodeURIComponent(t.target)}${t.anchor ? '#' + encodeURIComponent(t.anchor) : ''}">${esc(t.text)}</a>`;
    }
  };
  const highlight = {
    name: 'mark', level: 'inline',
    start(src) { return src.indexOf('=='); },
    tokenizer(src) {
      const m = /^==([^=\n](?:[^\n]*?[^=\n])?)==/.exec(src);
      if (m) return { type: 'mark', raw: m[0], tokens: this.lexer.inlineTokens(m[1]) };
    },
    renderer(t) { return `<mark>${this.parser.parseInline(t.tokens)}</mark>`; }
  };
  marked.use({ gfm: true, breaks: false, renderer, extensions: [wikilink, highlight] });

  function splitFrontMatter(md) {
    const m = /^---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(md);
    return m ? { fm: m[1], body: md.slice(m[0].length) } : { fm: null, body: md };
  }
  function sanitize(root) {
    root.querySelectorAll('script,iframe,object,embed,link,meta,base,form,frame').forEach(e => e.remove());
    root.querySelectorAll('*').forEach(el => {
      for (const a of Array.from(el.attributes)) {
        const n = a.name.toLowerCase();
        if (n.startsWith('on') || ((n === 'href' || n === 'src' || n === 'xlink:href' || n === 'action') && /^\s*(javascript|vbscript|data:text\/html)/i.test(a.value))) el.removeAttribute(a.name);
      }
    });
  }

  // ---------- outline ----------
  function buildTOC() {
    const hs = content.querySelectorAll('h1,h2,h3,h4');
    const frag = document.createDocumentFragment();
    const h6 = document.createElement('h6'); h6.textContent = 'Outline'; frag.appendChild(h6);
    if (!hs.length) { const p = document.createElement('p'); p.className = 'toc-empty'; p.textContent = 'No headings'; frag.appendChild(p); }
    else {
      const ul = document.createElement('ul');
      hs.forEach(h => {
        const c = h.cloneNode(true); c.querySelectorAll('a.anchor').forEach(a => a.remove());
        const li = document.createElement('li'); li.className = 'toc-' + h.tagName.toLowerCase();
        const a = document.createElement('a'); a.href = '#' + h.id; a.textContent = c.textContent.trim(); a.title = a.textContent;
        li.appendChild(a); ul.appendChild(li);
      });
      frag.appendChild(ul);
    }
    toc.replaceChildren(frag);
  }

  // ---------- find ----------
  let hits = [], cur = -1, query = '';
  function clearHits() {
    for (const m of hits) { const p = m.parentNode; if (!p) continue; p.replaceChild(document.createTextNode(m.textContent), m); p.normalize(); }
    hits = []; cur = -1;
  }
  function markHits(q) {
    clearHits(); query = q;
    if (!q) { findCount.textContent = ''; return; }
    const ql = q.toLowerCase();
    const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
    const nodes = []; let n; while ((n = walker.nextNode())) if (n.nodeValue.toLowerCase().includes(ql)) nodes.push(n);
    for (const node of nodes) {
      const text = node.nodeValue, lower = text.toLowerCase();
      const frag = document.createDocumentFragment(); let last = 0, idx = lower.indexOf(ql);
      while (idx >= 0) {
        frag.appendChild(document.createTextNode(text.slice(last, idx)));
        const m = document.createElement('mark'); m.className = 'hit'; m.textContent = text.slice(idx, idx + q.length);
        frag.appendChild(m); hits.push(m); last = idx + q.length; idx = lower.indexOf(ql, last);
      }
      frag.appendChild(document.createTextNode(text.slice(last)));
      node.parentNode.replaceChild(frag, node);
    }
    updateCount();
  }
  function updateCount() { findCount.textContent = query ? (hits.length ? `${cur + 1}/${hits.length}` : 'No matches') : ''; }
  function go(delta) {
    if (!hits.length) { updateCount(); return; }
    if (cur >= 0) hits[cur].classList.remove('current');
    cur = (cur + delta + hits.length) % hits.length;
    hits[cur].classList.add('current');
    hits[cur].scrollIntoView({ block: 'center' });
    updateCount();
  }
  function openFind() { findbar.hidden = false; findInput.focus(); findInput.select(); if (findInput.value && !hits.length) { markHits(findInput.value); go(1); } }
  function closeFind() { findbar.hidden = true; clearHits(); query = ''; findCount.textContent = ''; findInput.blur(); }
  findInput.addEventListener('input', () => { markHits(findInput.value); go(1); });
  findInput.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); go(e.shiftKey ? -1 : 1); }
    else if (e.key === 'Escape') { e.preventDefault(); closeFind(); }
  });
  document.getElementById('find-next').addEventListener('click', () => go(1));
  document.getElementById('find-prev').addEventListener('click', () => go(-1));
  document.getElementById('find-close').addEventListener('click', closeFind);
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && !findbar.hidden) closeFind(); });

  // ---------- clicks ----------
  function scrollToId(id) {
    let el = document.getElementById(id);
    if (!el) { const want = id.toLowerCase(); el = Array.from(content.querySelectorAll('h1,h2,h3,h4,h5,h6')).find(h => h.id.replace(/-\d+$/, '') === want || h.textContent.trim().toLowerCase() === want) || null; }
    if (el) { el.scrollIntoView({ block: 'start' }); return true; }
    return false;
  }
  document.addEventListener('click', e => {
    const btn = e.target.closest('button.copy');
    if (btn) {
      const code = btn.parentNode.querySelector('code'); const text = code ? code.innerText : '';
      const done = () => { btn.textContent = 'Copied'; btn.classList.add('done'); setTimeout(() => { btn.textContent = 'Copy'; btn.classList.remove('done'); }, 1200); };
      const viaApp = () => { post('copy', { text }); done(); };
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, viaApp);
      else viaApp();
      return;
    }
    const a = e.target.closest('a'); if (!a) return;
    const href = a.getAttribute('href') || '';
    if (href.startsWith('#')) { e.preventDefault(); scrollToId(decodeURIComponent(href.slice(1))); return; }
    if (href.startsWith('wiki:')) {
      e.preventDefault();
      const [t, anchor] = href.slice(5).split('#');
      post('wikilink', { target: decodeURIComponent(t), anchor: anchor ? decodeURIComponent(anchor) : '' });
    }
  });
  document.addEventListener('dblclick', e => {
    if (e.target.closest('a, button, input, summary, pre, code')) return;
    if (!window.getSelection().toString()) post('edit', {});
  });

  // ---------- scroll memory ----------
  let scrollTimer = null;
  window.addEventListener('scroll', () => { clearTimeout(scrollTimer); scrollTimer = setTimeout(() => post('scroll', { y: Math.round(window.scrollY) }), 300); }, { passive: true });

  // ---------- public API ----------
  let first = true;
  window.MDV = {
    render(md) {
      const y = window.scrollY;
      for (const k in slugCounts) delete slugCounts[k];
      hits = []; cur = -1;
      const { fm, body } = splitFrontMatter(md);
      let html = '';
      if (fm !== null) {
        const yaml = hljs.getLanguage('yaml') ? hljs.highlight(fm, { language: 'yaml', ignoreIllegals: true }).value : esc(fm);
        html += `<details class="frontmatter"><summary>Properties</summary><pre><code class="hljs language-yaml">${yaml}</code></pre></details>`;
      }
      html += marked.parse(body);
      const t = document.createElement('template'); t.innerHTML = html; sanitize(t.content);
      content.replaceChildren(t.content);
      buildTOC();
      if (query) { markHits(query); if (hits.length) go(1); }
      if (!first) window.scrollTo(0, y);
    },
    boot(md, scrollY) {
      this.render(md);
      first = false;
      if (scrollY > 0) requestAnimationFrame(() => window.scrollTo(0, scrollY));
    },
    scrollToHeading(name) { return scrollToId(name); },
    toggleTOC() { const open = document.body.classList.toggle('toc-open'); post('toc', { open }); return open; },
    find: openFind,
    findNext() { if (findbar.hidden) openFind(); else go(1); },
    findPrev() { if (findbar.hidden) openFind(); else go(-1); }
  };
})();
