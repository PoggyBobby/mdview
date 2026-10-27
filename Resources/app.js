/* MDView page runtime. Shared by the macOS and Linux apps.
   Host -> page: MDV.boot / render / find / findNext / findPrev / toggleTOC / scrollToHeading / exportData / start
   Page -> host: window.webkit.messageHandlers.mdv.postMessage({type, ...}) with types
     scroll, toc, wikilink, copy, edit, title, open, openPanel, rendered */
(function () {
  'use strict';
  const $ = id => document.getElementById(id);
  const content = $('content'), toc = $('toc'), findbar = $('findbar'), findInput = $('find-input'), findCount = $('find-count');
  const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const post = (type, body) => { try { window.webkit.messageHandlers.mdv.postMessage(Object.assign({ type }, body || {})); } catch (e) { } };
  const isDark = () => window.matchMedia('(prefers-color-scheme: dark)').matches;
  const HIGHLIGHT_LIMIT = 40000;   // characters per code block; larger blocks are shown plain for speed

  // ---------- front matter ----------
  function splitFrontMatter(md) {
    const m = /^---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(md);
    return m ? { fm: m[1], body: md.slice(m[0].length) } : { fm: null, body: md };
  }
  const unquote = s => String(s).trim().replace(/^(['"])(.*)\1$/, '$2');
  function parseFrontMatter(yaml) {           // small YAML subset: key: scalar | key: [a, b] | key:\n  - a
    const out = {}; let key = null;
    for (const line of yaml.split(/\r?\n/)) {
      const kv = /^([A-Za-z0-9_.-]+)\s*:\s*(.*)$/.exec(line);
      if (kv) { key = kv[1]; const v = kv[2].trim(); out[key] = v === '' ? [] : v; continue; }
      const li = /^\s+-\s*(.*)$/.exec(line);
      if (li && key !== null) { if (!Array.isArray(out[key])) out[key] = out[key] ? [out[key]] : []; out[key].push(li[1].trim()); }
    }
    return out;
  }
  function listValue(v) {
    if (v === undefined || v === null) return [];
    if (Array.isArray(v)) return v.map(unquote).filter(Boolean);
    v = String(v).trim();
    if (/^\[.*\]$/.test(v)) return v.slice(1, -1).split(',').map(unquote).filter(Boolean);
    return v ? v.split(/[,\s]+/).map(unquote).filter(Boolean) : [];
  }

  // ---------- marked configuration ----------
  const slugCounts = Object.create(null);
  function slug(html) {
    let s = html.replace(/<[^>]+>/g, '').replace(/&[a-z#0-9]+;/gi, ' ').toLowerCase()
      .replace(/[^\p{L}\p{N}\s_-]/gu, '').trim().replace(/[\s_]+/g, '-');
    if (!s) s = 'section';
    const n = slugCounts[s] || 0; slugCounts[s] = n + 1;
    return n ? `${s}-${n}` : s;
  }
  const safeId = s => String(s).replace(/[^\w-]/g, '_');
  const renderer = {
    heading({ tokens, depth }) {
      const html = this.parser.parseInline(tokens);
      const id = slug(html);
      return `<h${depth} id="${id}"><a class="anchor" href="#${id}" aria-hidden="true">#</a>${html}</h${depth}>\n`;
    },
    code({ text, lang }) {
      const l = (lang || '').trim().split(/\s+/)[0].toLowerCase();
      if (l === 'mermaid') return `<div class="mermaid" data-src="${esc(text)}"></div>\n`;
      let body, cls = 'hljs';
      if (l && text.length <= HIGHLIGHT_LIMIT && hljs.getLanguage(l)) {
        body = hljs.highlight(text, { language: l, ignoreIllegals: true }).value; cls += ' language-' + esc(l);
      } else body = esc(text);
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
  function tex(src, display) {
    if (!window.katex) return `<code>${esc(src)}</code>`;
    try { return katex.renderToString(src, { displayMode: display, throwOnError: false, output: 'htmlAndMathml' }); }
    catch (e) { return `<span class="math-error">${esc(src)}</span>`; }
  }
  const mathBlock = {
    name: 'mathBlock', level: 'block',
    start(src) { return src.indexOf('$$'); },
    tokenizer(src) {
      const m = /^\$\$\n?([\s\S]+?)\n?\$\$[ \t]*(?:\n+|$)/.exec(src);
      if (m) return { type: 'mathBlock', raw: m[0], text: m[1].trim() };
    },
    renderer(t) { return `<div class="math-block">${tex(t.text, true)}</div>\n`; }
  };
  const mathInline = {
    name: 'mathInline', level: 'inline',
    start(src) { return src.indexOf('$'); },
    tokenizer(src) {
      let m = /^\$\$([^$\n]+?)\$\$/.exec(src);
      if (m) return { type: 'mathInline', raw: m[0], text: m[1].trim(), display: true };
      m = /^\$(?!\s)((?:\\\$|[^$\n])+?)\$(?!\d)/.exec(src);
      if (m && !/\s$/.test(m[1])) return { type: 'mathInline', raw: m[0], text: m[1], display: false };
    },
    renderer(t) { return tex(t.text, t.display); }
  };
  const fn = { defs: {}, order: [] };
  const footnoteDef = {
    name: 'footnoteDef', level: 'block',
    start(src) { const m = /^\[\^[^\]\n]+\]:/m.exec(src); return m ? m.index : -1; },
    tokenizer(src) {
      const m = /^\[\^([^\]\n]+)\]:[ \t]*([^\n]*(?:\n[ \t]{2,}[^\n]*)*)(?:\n|$)/.exec(src);
      if (!m) return;
      fn.defs[m[1].trim()] = m[2].replace(/\n[ \t]+/g, ' ').trim();
      return { type: 'footnoteDef', raw: m[0] };
    },
    renderer() { return ''; }
  };
  const footnoteRef = {
    name: 'footnoteRef', level: 'inline',
    start(src) { return src.indexOf('[^'); },
    tokenizer(src) {
      const m = /^\[\^([^\]\n]+)\](?!:)/.exec(src);
      if (!m) return;
      const id = m[1].trim();
      if (!fn.order.includes(id)) fn.order.push(id);
      return { type: 'footnoteRef', raw: m[0], id };
    },
    renderer(t) {
      const n = fn.order.indexOf(t.id) + 1, id = safeId(t.id);
      return `<sup class="fn-ref" id="fnref-${id}"><a href="#fn-${id}" title="${esc(t.id)}">${n}</a></sup>`;
    }
  };
  const inlineOnly = new marked.Marked({ gfm: true, extensions: [wikilink, highlight, mathInline] });
  const hooks = {
    preprocess(md) { fn.defs = {}; fn.order = []; return md; },
    postprocess(html) {
      if (!fn.order.length) return html;
      const items = fn.order.map(id => {
        const body = fn.defs[id] !== undefined ? inlineOnly.parseInline(fn.defs[id]) : '<em>Missing footnote</em>';
        return `<li id="fn-${safeId(id)}">${body}<a class="fn-back" href="#fnref-${safeId(id)}" title="Back">↩</a></li>`;
      });
      return html + `<section class="footnotes"><hr><ol>${items.join('')}</ol></section>\n`;
    }
  };
  marked.use({ gfm: true, breaks: false, renderer, hooks, extensions: [footnoteDef, footnoteRef, wikilink, highlight, mathBlock, mathInline] });

  function sanitize(root) {
    root.querySelectorAll('script,iframe,object,embed,link,meta,base,form,frame').forEach(e => e.remove());
    root.querySelectorAll('*').forEach(el => {
      for (const a of Array.from(el.attributes)) {
        const n = a.name.toLowerCase();
        if (n.startsWith('on') || ((n === 'href' || n === 'src' || n === 'xlink:href' || n === 'action') && /^\s*(javascript|vbscript|data:text\/html)/i.test(a.value))) el.removeAttribute(a.name);
      }
    });
  }

  // ---------- mermaid (loaded on first use) ----------
  let mermaidLoad = null, mermaidSeq = 0;
  function loadMermaid() {
    if (window.mermaid) return Promise.resolve();
    if (!mermaidLoad) mermaidLoad = new Promise((res, rej) => {
      const s = document.createElement('script'); s.src = 'mdview://app/vendor/mermaid.min.js';
      s.onload = res; s.onerror = () => { mermaidLoad = null; rej(new Error('mermaid.min.js failed to load')); };
      document.head.appendChild(s);
    });
    return mermaidLoad;
  }
  async function renderMermaid(generation) {
    const nodes = Array.from(content.querySelectorAll('.mermaid[data-src]'));
    if (!nodes.length) return;
    try { await loadMermaid(); } catch (e) { nodes.forEach(n => { n.classList.add('error'); n.innerHTML = `<pre>${esc(e.message)}</pre>`; }); return; }
    if (generation !== renderGen) return;        // document re-rendered meanwhile
    mermaid.initialize({ startOnLoad: false, theme: isDark() ? 'dark' : 'neutral', securityLevel: 'strict', suppressErrorRendering: true });
    for (const n of nodes) {
      const src = n.dataset.src; delete n.dataset.src;
      try { const { svg } = await mermaid.render('mmd' + (++mermaidSeq), src); if (generation === renderGen) n.innerHTML = svg; }
      catch (e) { n.classList.add('error'); n.innerHTML = `<pre>${esc(String(e && e.message || e))}</pre>`; }
    }
  }
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (lastMarkdown !== null && content.querySelector('.mermaid')) MDV.render(lastMarkdown); });

  // ---------- outline with scroll-spy ----------
  let headings = [], tocItems = new Map(), spyPending = false;
  function buildTOC() {
    headings = Array.from(content.querySelectorAll('h1,h2,h3,h4')); tocItems = new Map();
    const frag = document.createDocumentFragment();
    const h6 = document.createElement('h6'); h6.textContent = 'Outline'; frag.appendChild(h6);
    if (!headings.length) { const p = document.createElement('p'); p.className = 'toc-empty'; p.textContent = 'No headings'; frag.appendChild(p); }
    else {
      const ul = document.createElement('ul');
      headings.forEach(h => {
        const c = h.cloneNode(true); c.querySelectorAll('a.anchor').forEach(a => a.remove());
        const li = document.createElement('li'); li.className = 'toc-' + h.tagName.toLowerCase();
        const a = document.createElement('a'); a.href = '#' + h.id; a.textContent = c.textContent.trim(); a.title = a.textContent;
        li.appendChild(a); ul.appendChild(li); tocItems.set(h.id, li);
      });
      frag.appendChild(ul);
    }
    toc.replaceChildren(frag);
    spy();
  }
  function spy() {
    if (!headings.length || !document.body.classList.contains('toc-open')) return;
    let active = headings[0];
    for (const h of headings) { if (h.getBoundingClientRect().top <= 90) active = h; else break; }
    const li = tocItems.get(active.id);
    if (!li || li.classList.contains('active')) return;
    toc.querySelectorAll('li.active').forEach(x => x.classList.remove('active'));
    li.classList.add('active');
    li.scrollIntoView({ block: 'nearest' });
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
  $('find-next').addEventListener('click', () => go(1));
  $('find-prev').addEventListener('click', () => go(-1));
  $('find-close').addEventListener('click', closeFind);
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && !findbar.hidden) closeFind(); });

  // ---------- clicks ----------
  function scrollToId(id) {
    let el = document.getElementById(id);
    if (!el) { const want = id.toLowerCase(); el = Array.from(content.querySelectorAll('h1,h2,h3,h4,h5,h6')).find(h => h.id.replace(/-\d+$/, '') === want || h.textContent.replace(/^#/, '').trim().toLowerCase() === want) || null; }
    if (el) { el.scrollIntoView({ block: 'start' }); return true; }
    return false;
  }
  document.addEventListener('click', e => {
    const btn = e.target.closest('button.copy');
    if (btn) {
      const code = btn.parentNode.querySelector('code'); const text = code ? code.innerText : '';
      const done = () => { btn.textContent = 'Copied'; btn.classList.add('done'); setTimeout(() => { btn.textContent = 'Copy'; btn.classList.remove('done'); }, 1200); };
      const viaApp = () => { post('copy', { text }); done(); };
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, viaApp); else viaApp();
      return;
    }
    const a = e.target.closest('a'); if (!a) return;
    if (a.dataset.path) { e.preventDefault(); post('open', { path: a.dataset.path }); return; }
    const href = a.getAttribute('href') || '';
    if (href.startsWith('#')) { e.preventDefault(); scrollToId(decodeURIComponent(href.slice(1))); return; }
    if (href.startsWith('wiki:')) {
      e.preventDefault();
      const [t, anchor] = href.slice(5).split('#');
      post('wikilink', { target: decodeURIComponent(t), anchor: anchor ? decodeURIComponent(anchor) : '' });
    }
  });
  document.addEventListener('dblclick', e => {
    if (document.body.classList.contains('start')) return;
    if (e.target.closest('a, button, input, summary, pre, code, svg')) return;
    if (!window.getSelection().toString()) post('edit', {});
  });
  $('start-open').addEventListener('click', () => post('openPanel', {}));

  // ---------- scroll memory + spy ----------
  let scrollTimer = null;
  window.addEventListener('scroll', () => {
    clearTimeout(scrollTimer); scrollTimer = setTimeout(() => post('scroll', { y: Math.round(window.scrollY) }), 300);
    if (!spyPending) { spyPending = true; requestAnimationFrame(() => { spyPending = false; spy(); }); }
  }, { passive: true });

  // ---------- public API ----------
  let first = true, lastMarkdown = null, renderGen = 0;
  window.MDV = {
    render(md) {
      const t0 = performance.now(), y = window.scrollY, gen = ++renderGen;
      lastMarkdown = md;
      for (const k in slugCounts) delete slugCounts[k];
      hits = []; cur = -1;
      const { fm, body } = splitFrontMatter(md);
      const meta = fm !== null ? parseFrontMatter(fm) : {};
      const title = unquote(Array.isArray(meta.title) ? (meta.title[0] || '') : (meta.title || ''));
      const tags = listValue(meta.tags !== undefined ? meta.tags : meta.tag).map(t => t.replace(/^#/, ''));
      let html = '';
      if (title || tags.length) {
        html += '<div class="doc-head">';
        if (title && !/^\s*#\s/.test(body)) html += `<h1 class="fm-title">${esc(title)}</h1>`;
        if (tags.length) html += `<div class="chips">${tags.map(t => `<span class="chip">#${esc(t)}</span>`).join('')}</div>`;
        html += '</div>';
      }
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
      if (title) document.title = title;
      post('title', { title });
      post('rendered', { ms: Math.round(performance.now() - t0), chars: md.length });
      renderMermaid(gen);
    },
    boot(md, scrollY, extra) {
      extra = extra || {};
      if (md === null || md === undefined) { this.start(extra.recents || []); first = false; return; }
      this.render(md);
      first = false;
      if (scrollY > 0) requestAnimationFrame(() => window.scrollTo(0, scrollY));
    },
    start(recents) {
      document.body.classList.add('start');
      const box = $('start-recent'); box.replaceChildren();
      if (!recents || !recents.length) return;
      const h6 = document.createElement('h6'); h6.textContent = 'Recent'; box.appendChild(h6);
      const ul = document.createElement('ul');
      for (const r of recents) {
        const li = document.createElement('li'), a = document.createElement('a'), name = document.createElement('strong'), dir = document.createElement('span');
        a.href = '#'; a.dataset.path = r.path; name.textContent = r.name; dir.textContent = r.dir;
        a.append(name, dir); li.appendChild(a); ul.appendChild(li);
      }
      box.appendChild(ul);
    },
    scrollToHeading(name) { return scrollToId(name); },
    toggleTOC() { const open = document.body.classList.toggle('toc-open'); post('toc', { open }); if (open) spy(); return open; },
    find: openFind,
    findNext() { if (findbar.hidden) openFind(); else go(1); },
    findPrev() { if (findbar.hidden) openFind(); else go(-1); },
    exportData() {
      const clone = content.cloneNode(true);
      clone.querySelectorAll('mark.hit').forEach(m => m.replaceWith(document.createTextNode(m.textContent)));
      clone.querySelectorAll('button.copy').forEach(b => b.remove());
      return { html: clone.innerHTML, title: document.title, math: !!clone.querySelector('.katex'), dark: isDark() };
    }
  };
})();
