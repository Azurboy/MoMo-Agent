(() => {
  'use strict';
  const root = document.querySelector('#document-root');
  const post = (type, value) => window.webkit?.messageHandlers?.doc?.postMessage({ type, value });
  const escape = text => String(text ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));

  function renderMath(token) {
    return katex.renderToString(token.text, {
      displayMode: token.display,
      throwOnError: false,
      trust: false,
      maxExpand: 1000,
      maxSize: 20,
      output: 'htmlAndMathml',
      strict: 'ignore'
    });
  }

  marked.use({
    gfm: true,
    breaks: false,
    renderer: {
      html(token) { return escape(token.text); },
      checkbox(token) {
        return `<span role="img" aria-label="${token.checked ? '已完成' : '未完成'}">${token.checked ? '☑' : '☐'}</span> `;
      }
    },
    extensions: [{
      name: 'mathBlock',
      level: 'block',
      start: source => source.indexOf('$$'),
      tokenizer(source) {
        const match = /^\$\$\s*\n?([\s\S]+?)\$\$(?:\n|$)/.exec(source);
        return match ? { type: 'mathBlock', raw: match[0], text: match[1], display: true } : undefined;
      },
      renderer: renderMath
    }, {
      name: 'mathInline',
      level: 'inline',
      start: source => source.indexOf('$'),
      tokenizer(source) {
        const match = /^\$([^$\n]+?)\$(?!\$)/.exec(source);
        return match && !/^\s|\s$/.test(match[1]) ? { type: 'mathInline', raw: match[0], text: match[1], display: false } : undefined;
      },
      renderer: renderMath
    }]
  });

  function render(payload) {
    if (!payload || typeof payload !== 'object') return;
    document.documentElement.dataset.dark = String(Boolean(payload.dark));
    const markdown = String(payload.markdown ?? '');
    const rawHTML = marked.parse(markdown);
    const template = document.createElement('template');
    template.innerHTML = DOMPurify.sanitize(rawHTML, {
      USE_PROFILES: { html: true, mathMl: true },
      FORBID_TAGS: ['iframe', 'form', 'input', 'object', 'embed', 'video', 'audio', 'style', 'script'],
      FORBID_ATTR: ['id', 'name'],
      ALLOWED_URI_REGEXP: /^(?:https?:\/\/|mailto:|momoagent:\/\/source\/|data:image\/(?:png|jpeg|gif|webp);base64,)/i
    });

    template.content.querySelectorAll('table').forEach(table => {
      const wrapper = document.createElement('div');
      wrapper.className = 'table-scroll';
      wrapper.tabIndex = 0;
      table.replaceWith(wrapper);
      wrapper.append(table);
    });

    template.content.querySelectorAll('pre').forEach(pre => {
      const wrapper = document.createElement('div');
      wrapper.className = 'code-wrap';
      const header = document.createElement('div');
      header.className = 'code-head';
      const code = pre.querySelector('code');
      const language = (code?.className || '').replace(/^language-/, '') || 'text';
      if (code && globalThis.hljs && hljs.getLanguage(language)) {
        code.innerHTML = DOMPurify.sanitize(
          hljs.highlight(code.textContent, { language, ignoreIllegals: true }).value,
          { USE_PROFILES: { html: true } }
        );
      }
      const langSpan = document.createElement('span');
      langSpan.textContent = language;
      header.append(langSpan);
      pre.replaceWith(wrapper);
      wrapper.append(header, pre);
    });

    template.content.querySelectorAll('a').forEach(link => {
      link.rel = 'noopener noreferrer';
    });

    root.replaceChildren(template.content);
  }

  document.addEventListener('click', event => {
    const anchor = event.target.closest('a');
    if (!anchor) return;
    event.preventDefault();
    const href = anchor.getAttribute('href');
    if (href) post('link', href);
  });

  window.MoMoMarkdownDocument = { render };
  post('ready', true);
})();
