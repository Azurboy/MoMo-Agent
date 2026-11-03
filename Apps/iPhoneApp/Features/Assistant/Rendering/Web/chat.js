(() => {
  'use strict';
  const t = (key, ...args) => globalThis.MoMoChatLocalization ? MoMoChatLocalization.text(key, ...args) : key.replace(/\{(\d+)\}/g, (_, i) => String(args[Number(i)] ?? ''));
  const core = MoMoChatCore, root = document.querySelector('#transcript');
  const working = document.querySelector('#working');
  const responseSlot = document.querySelector('#response-slot');
  const activityMark = working.querySelector('.activity-mark');
  const brandMotion = MoMoCreateBrandMotion(activityMark);
  const motionPreference = window.matchMedia('(prefers-reduced-motion: reduce)');
  const pin = new core.PinState(), views = new Map();
  let latest = null, session = null, first = true, frame = null, previousBusy = false, previousStopped = false;
  let waitingKey = null, waitingSince = 0, waitingTimer = null;
  let previousActivity = 'idle';
  let reduced = false, pageSuspended = false, userScrolling = false, wheelScrolling = false, wheelTimer;
  let restoring = null, restoreEpoch = 0, readingTimer = null, lastReading = null;
  let focusedRequest = null;
  let referenceNowMs = Date.now(), previousTurnCount = -1;
  const post = (type, value) => window.webkit?.messageHandlers?.chat?.postMessage({ type, value });
  const escape = text => text.replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
  core.installRecordingSourceLinks(marked);
  marked.use({
    renderer: {
      html(token) { return escape(token.text); },
      image(token) { return escape(token.text || t("图片")); },
      checkbox(token) {
        return `<span role="img" aria-label="${token.checked ? t("已完成") : t("未完成")}">${token.checked ? '☑' : '☐'}</span> `;
      }
    },
    extensions: [{
      name: 'mathBlock', level: 'block', start: source => source.indexOf('$$'),
      tokenizer(source) {
        const match = /^\$\$\s*\n?([\s\S]+?)\$\$(?:\n|$)/.exec(source);
        return match ? { type:'mathBlock', raw:match[0], text:match[1], display:true } : undefined;
      }, renderer: math
    }, {
      name: 'mathInline', level:'inline', start: source => source.indexOf('$'),
      tokenizer(source) {
        const match = /^\$([^$\n]+?)\$(?!\$)/.exec(source);
        return match && !/^\s|\s$/.test(match[1]) ? { type:'mathInline', raw:match[0], text:match[1], display:false } : undefined;
      }, renderer: math
    }]
  });
  function math(token) {
    return katex.renderToString(token.text, { displayMode:token.display, throwOnError:false,
      trust:false, maxExpand:1000, maxSize:20, output:'htmlAndMathml', strict:'ignore' });
  }
  function element(tag, className, text) {
    const result = document.createElement(tag);
    if (className) result.className = className;
    if (text !== undefined) result.textContent = text;
    return result;
  }
  function button(label, text, action) {
    const result = element('button', '', text); result.type = 'button';
    result.setAttribute('aria-label', label); result.dataset.action = action; return result;
  }
  function replyButton(label, action, svg) {
    const result = button(label, '', action);
    // Bundled application icon, never model HTML.
    result.innerHTML = svg;
    return result;
  }
  function syncActivityMotion() {
    const phase = working.dataset.phase;
    const selector = phase === 'thinking' ? '.reasoning-step[data-active=true] > summary' :
      phase === 'tool' ? '.tool-card[data-active=true] > summary' : null;
    const anchor = selector ? [...(root.lastElementChild?.querySelectorAll(selector) || [])].at(-1) : null;
    const target = anchor || working;
    // Reuse the original brand mark across activity phases and incremental snapshots.
    if (activityMark.parentElement !== target) target.prepend(activityMark);
    const visibleActivity = Boolean(anchor) || (!working.hidden && phase !== 'contextFailed');
    const active = visibleActivity && !pageSuspended && !document.hidden && !reduced && !motionPreference.matches;
    working.dataset.animating = String(active && !working.hidden);
    document.documentElement.dataset.activityAnimating = String(active);
    brandMotion.update(visibleActivity && phase !== 'waiting', reduced || motionPreference.matches);
  }
  function sanitized(html) {
    const template = document.createElement('template');
    template.innerHTML = DOMPurify.sanitize(html, {
      USE_PROFILES:{ html:true, mathMl:true },
      FORBID_TAGS:['img','iframe','form','input','object','embed','video','audio','style'],
      FORBID_ATTR:['id','name'],
      ALLOWED_URI_REGEXP:/^(?:https?:\/\/|momoagent:\/\/source\/)/i
    });
    template.content.querySelectorAll('table').forEach(table => {
      const wrapper = element('div','table-scroll'); wrapper.tabIndex = 0;
      wrapper.setAttribute('role','region'); wrapper.setAttribute('aria-label',t("表格，可横向滚动"));
      table.replaceWith(wrapper); wrapper.append(table);
    });
    template.content.querySelectorAll('pre').forEach(pre => {
      const wrapper = element('div','code-wrap'), header = element('div','code-head');
      const code = pre.querySelector('code'), language = code?.className.replace('language-','') || 'text';
      if (code && hljs.getLanguage(language)) {
        code.innerHTML = DOMPurify.sanitize(hljs.highlight(code.textContent,{ language,ignoreIllegals:true }).value,
          { USE_PROFILES:{ html:true } });
      }
      header.append(element('span','',language));
      pre.replaceWith(wrapper); wrapper.append(header,pre);
    });
    template.content.querySelectorAll('a').forEach(link => {
      link.rel = 'noopener noreferrer';
      const href = link.getAttribute('href') || '';
      if (core.isRecordingSourceURL(href)) {
        link.classList.add('recording-source');
        // Autolinks and model-authored links whose label is the raw URL are also compact.
        if (link.textContent.trim() === href) link.textContent = t("查看录音");
      }
    });
    return template.content;
  }
  function selectionIntersects(node) {
    const selection = window.getSelection();
    return selection && !selection.isCollapsed && [...Array(selection.rangeCount).keys()]
      .some(index => selection.getRangeAt(index).intersectsNode(node));
  }
  function unwrapFades(node) {
    node.querySelectorAll('span.delta-fade,span.delta-run').forEach(span => {
      span.replaceWith(...span.childNodes);
    });
    node.normalize();
  }
  function morphChildren(target, incoming, animate) {
    const next = [...incoming.childNodes];
    next.forEach((node, index) => {
      const old = target.childNodes[index];
      if (!old) { target.append(node); if (animate && node.nodeType === 1) node.classList.add('delta-enter'); return; }
      if (old.nodeType !== node.nodeType || old.nodeName !== node.nodeName) { old.replaceWith(node); return; }
      if (node.nodeType === 3) {
        if (old.nodeValue === node.nodeValue) return;
        const text = node.nodeValue || '', prefix = core.stablePrefix(old.nodeValue || '',text);
        if (animate && text.startsWith(prefix) && prefix) {
          const span = element('span','delta-fade',text.slice(prefix.length));
          // A span is flattened before the next patch, so source text never accumulates wrappers.
          const run = element('span','delta-run'); run.append(document.createTextNode(prefix),span);
          old.replaceWith(run);
        } else old.nodeValue = text;
        return;
      }
      for (const attr of [...old.attributes]) if (!node.hasAttribute(attr.name)) old.removeAttribute(attr.name);
      for (const attr of [...node.attributes]) if (old.getAttribute(attr.name) !== attr.value) old.setAttribute(attr.name,attr.value);
      morphChildren(old,node,animate);
    });
    while (target.childNodes.length > next.length) target.lastChild.remove();
  }
  function patchMarkdown(view, text, streaming, animate) {
    if (view.lastText === text && view.lastStreaming === streaming) return;
    if (selectionIntersects(view.node)) return;
    const chunks = view.document.update(text,streaming), kept = new Set();
    chunks.forEach((chunk,index) => {
      kept.add(chunk.id);
      let item = view.chunks.get(chunk.id);
      if (!item) {
        item = { node:element('div','md-chunk'), html:null }; item.node.dataset.chunk = chunk.id;
        view.chunks.set(chunk.id,item);
      }
      if (item.html !== chunk.html) {
        unwrapFades(item.node);
        morphChildren(item.node,sanitized(chunk.html),animate && !reduced);
        item.html = chunk.html;
      }
      const position = view.node.children[index];
      if (position !== item.node) view.node.insertBefore(item.node,position || null);
    });
    for (const [id,item] of view.chunks) if (!kept.has(id)) { item.node.remove(); view.chunks.delete(id); }
    view.lastText = text; view.lastStreaming = streaming;
  }
  function makeProse(part, hydrated) {
    return { node:element('section','prose'), document:new core.MarkdownStream(marked), chunks:new Map(),
      target:part.text, shown:hydrated || !part.streaming ? part.text : '', streaming:part.streaming,
      lastText:null, lastStreaming:null };
  }
  function processView(part) {
    const node = element('div','process-group'), disclosure = element('details','process-disclosure');
    const summary = element('summary'), label = element('span','process-label');
    const body = element('div','process-steps'), receipts = element('div','action-results');
    summary.append(label,element('span','chevron','›'));
    summary.addEventListener('click',() => { stopRestoring(); pin.pinned = false; });
    disclosure.append(summary,body); node.append(disclosure,receipts);
    return { node, disclosure, summary, label, body, receipts, completed:false, cards:new Map(), steps:new Map() };
  }
  function updateProcess(view, part, busy, completed) {
    const finishing = completed && !view.completed;
    view.node.dataset.completed = String(completed);
    view.summary.hidden = !completed;
    if (!completed) view.disclosure.open = true;
    else if (finishing) view.disclosure.open = false;
    const hasTools = part.steps.some(step => step.type === 'tool');
    const hasReasoning = part.steps.some(step => step.type === 'reasoning');
    view.label.textContent = hasTools ? `${hasReasoning ? t("思考与工具") : t("工具调用")} · ${core.processSummary(part.steps,false)}` : t("思考过程");
    const running = part.steps.some(step => step.type === 'tool' && ['pending','running'].includes(step.tool.state));
    const active = busy && (running || part.steps.at(-1)?.type === 'reasoning');
    view.node.dataset.state = active ? 'running' : 'settled';
    const visibleCards = new Set();
    for (const step of part.steps) {
      if (step.type !== 'tool') continue;
      const receipt = core.actionReceipt(step.tool);
      if (!receipt) continue;
      visibleCards.add(receipt.actionID);
      let card = view.cards.get(receipt.actionID);
      const signature = JSON.stringify(receipt);
      if (!card) { card = {node:element('section','system-action-card'),signature:null}; view.cards.set(receipt.actionID,card); view.receipts.append(card.node); }
      if (card.signature === signature) continue;
      const content = core.actionCard(step.tool,receipt);
      card.node.dataset.kind = content.kind; card.node.dataset.state = content.state;
      const button = element('button','action-card-open');
      button.type = 'button'; button.addEventListener('click',() => post('systemAction',{actionID:receipt.actionID,sessionID:latest.sessionID}));
      button.setAttribute('aria-label',t("{0}：{1}，{2}，查看或修改", content.kindLabel, content.title, content.status));
      const head = element('div','action-card-head'), symbol = document.createElementNS('http://www.w3.org/2000/svg','svg');
      symbol.setAttribute('viewBox','0 0 32 32'); symbol.setAttribute('aria-hidden','true');
      const paths = {alarm:['M23 17a7 7 0 1 1-14 0 7 7 0 0 1 14 0Z','M16 13v5l3 2M7 8l-3 3m21-3 3 3M11 25l-2 3m12-3 2 3'],reminder:['M8 6h17v22H7V7M11 3v6m10-6v6','m11 17 3 3 7-7'],event:['M5 8h22v20H5ZM5 13h22M11 4v7m10-7v7','M11 18h3m4 0h3m-10 5h3']};
      for (const d of paths[content.kind] || paths.event) { const path = document.createElementNS(symbol.namespaceURI,'path'); path.setAttribute('d',d); symbol.append(path); }
      const arrow = document.createElementNS(symbol.namespaceURI,'svg'); arrow.setAttribute('viewBox','0 0 32 32'); arrow.setAttribute('aria-hidden','true'); arrow.classList.add('action-card-arrow');
      const arrowPath = document.createElementNS(symbol.namespaceURI,'path'); arrowPath.setAttribute('d','m8 24 16-16M8 8h16v16'); arrow.append(arrowPath);
      head.append(symbol,element('span','action-card-status',content.status),arrow);
      button.append(head);
      if (content.kind === 'alarm' && content.time) button.append(element('div','action-card-time',content.time));
      button.append(element('strong','action-card-title',content.title));
      if (content.kind !== 'alarm' && content.time) button.append(element('div','action-card-when',content.time));
      if (content.detail) button.append(element('p','action-card-detail',content.detail));
      card.node.replaceChildren(button); card.signature = signature;
    }
    for (const [id,card] of view.cards) if (!visibleCards.has(id)) { card.node.remove(); view.cards.delete(id); }
    const ids = new Set();
    part.steps.forEach((step,index) => {
      ids.add(step.id); let item = view.steps.get(step.id);
      if (!item) {
        const reasoning = step.type === 'reasoning';
        const node = element('details',reasoning ? 'process reasoning-step' : 'step tool-card');
        const content = element('div',reasoning ? 'process-body step-content' : 'step-content');
        const summary = element('summary');
        if (reasoning) summary.append(element('span','process-title'),element('span','chevron','›'));
        else summary.append(element('span','step-icon'),element('span','step-label'),element('span','badge'),element('span','chevron','›'));
        node.append(summary);
        summary.addEventListener('click',() => { item.touched = true; pin.pinned = false; });
        node.append(content);
        node.dataset.step = step.id;
        item = { node, content, signature:null, touched:false }; view.steps.set(step.id,item);
      }
      if (step.type === 'reasoning') {
        const thinking = busy && !running && part.steps.at(-1)?.id === step.id;
        item.node.dataset.active = String(thinking);
        const title = item.node.querySelector('.process-title');
        title.textContent = thinking ? t("正在思考") : t("思考过程");
        title.classList.toggle('activity-shimmer',thinking);
        // The completed group's disclosure owns reasoning visibility, so one tap reveals it.
        if (completed) item.node.open = true;
        else if (!item.touched) item.node.open = thinking;
      } else {
        const active = busy && ['pending','running'].includes(core.toolDisplayState(step.tool));
        item.node.dataset.active = String(active);
      }
      const signature = JSON.stringify(step);
      if (item.signature !== signature) {
        if (step.type === 'reasoning') {
          item.content.replaceChildren(element('div','reasoning',step.redacted ? t("此模型未公开思考内容。") : step.text || t("此模型未提供可展示的思考内容。")));
        } else {
          const label = item.node.querySelector('.step-label'), badge = item.node.querySelector('.badge');
          const icon = item.node.querySelector('.step-icon');
          const tool = step.tool, displayState = core.toolDisplayState(tool), working = ['pending','running'].includes(displayState);
          label.replaceChildren(element('span','tool-name',core.toolLabel(tool)));
          const preview = core.toolPreview(tool);
          if (preview) label.append(element('span','step-preview',preview));
          icon.className = working ? 'step-icon loading-dot' : 'step-icon';
          icon.innerHTML = working ? '' : displayState === 'succeeded'
            ? '<svg aria-hidden="true" viewBox="0 0 20 20" fill="none"><path d="m5 10 3.2 3.2L15 6.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>'
            : '<svg aria-hidden="true" viewBox="0 0 20 20" fill="none"><path d="M5 10h10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';
          badge.textContent = { failed:t("失败"), interrupted:t("已中断"), pending:t("等待中"), running:t("进行中"), succeeded:'', outcome_unknown:t("待核对"), needs_permission:t("待连接"), needs_clarification:t("待补充"), conflict:t("已变化") }[displayState];
          badge.className = `badge ${displayState}`;
          item.content.replaceChildren();
          const outcome = core.toolOutcome(tool);
          if (preview) item.content.append(element('p','tool-query',preview));
          if (outcome) {
            item.content.append(element('p','tool-outcome',outcome.summary));
            if (outcome.text) item.content.append(element('div','tool-excerpt',outcome.text));
            if (outcome.more) item.content.append(element('p','tool-more',t("还有更多结果")));
          } else if (tool.output != null) item.content.append(element('pre','tool-output',pretty(tool.output)));
          else if (tool.state === 'interrupted') item.content.append(element('p','',t("执行已中断，没有确认完成结果。")));
          else item.content.append(element('p','tool-outcome',working ? t("正在执行，结果会显示在这里。") : t("未返回结果。")));
        }
        item.signature = signature;
      }
      item.node.querySelector('.tool-name')?.classList.toggle('activity-shimmer',item.node.dataset.active === 'true');
      if (finishing && step.type === 'tool') item.node.open = false;
      if (view.body.children[index] !== item.node) view.body.insertBefore(item.node,view.body.children[index] || null);
    });
    for (const [id,item] of view.steps) if (!ids.has(id)) { item.node.remove(); view.steps.delete(id); }
    view.completed = completed;
    return finishing;
  }
  function pretty(text) {
    let result = text;
    try { result = JSON.stringify(JSON.parse(text),null,2); } catch { /* Plain tool output is valid. */ }
    return result.length > 24000 ? result.slice(0,24000) + t("\n…显示已截短；原始执行结果仍保存在会话中。") : result;
  }
  function renderTurns(hydrated) {
    const items = core.turns(latest.messages), kept = new Set();
    if (hydrated || items.length !== previousTurnCount || Number.isFinite(latest.nowMs)) {
      referenceNowMs = Number.isFinite(latest.nowMs) ? latest.nowMs : Date.now();
      previousTurnCount = items.length;
    }
    let previousMarkerSentAtMs = null;
    const receiptIndex = items.findLastIndex(turn => turn.role === 'user');
    const finishing = items.some((turn,index) => core.replyFinished(turn,latest.busy && index === items.length - 1) &&
      [...(views.get(turn.id)?.pieces.values() || [])].some(piece => piece.type === 'process' && !piece.completed));
    const anchor = finishing && !pin.pinned && !restoring && !userScrolling && !wheelScrolling ?
      [...root.querySelectorAll('.md-chunk,.user-bubble,.system-action-card')].find(node => {
        const rect = node.getBoundingClientRect(); return rect.height > 0 && rect.bottom > headerInset() && rect.top < innerHeight;
      }) : null;
    const anchorTop = anchor?.getBoundingClientRect().top;
    let collapsed = false;
    const replacingOutgoing = [...views.keys()].some(id => id.startsWith('outgoing-'));
    items.forEach((turn,index) => {
      kept.add(turn.id); let view = views.get(turn.id);
      if (!view) {
        const node = element('article',`turn ${turn.role}`), parts = element('div','parts');
        if (!hydrated && turn.role === 'assistant') node.classList.add('assistant-enter');
        node.dataset.message = turn.id;
        if (turn.role !== 'system') node.setAttribute('aria-label',turn.role === 'user' ? t("你") : t("助理"));
        node.append(parts); view = { node, parts, pieces:new Map(), actions:null, timestamp:null, sentAtMs:null }; views.set(turn.id,view);
      }
      if (view.sentAtMs == null && Number.isFinite(turn.sentAtMs)) view.sentAtMs = turn.sentAtMs;
      let marker = null;
      if (turn.role !== 'system' && Number.isFinite(view.sentAtMs)) {
        if (core.shouldShowTimestampMarker(previousMarkerSentAtMs, view.sentAtMs)) {
          marker = {
            iso: new Date(view.sentAtMs).toISOString(),
            label: core.formatTimestampMarker(view.sentAtMs, referenceNowMs)
          };
          previousMarkerSentAtMs = view.sentAtMs;
        }
      }
      view.node.dataset.hasTimestamp = String(Boolean(marker));
      if (marker) {
        if (!view.timestamp) {
          const wrap = element('div','turn-timestamp'), time = element('time');
          wrap.setAttribute('data-markdown-copy','exclude');
          wrap.append(time);
          view.node.insertBefore(wrap,view.parts);
          view.timestamp = { wrap, time, iso:null, label:null };
        }
        if (view.timestamp.iso !== marker.iso) {
          view.timestamp.time.setAttribute('datetime',marker.iso);
          view.timestamp.iso = marker.iso;
        }
        if (view.timestamp.label !== marker.label) {
          view.timestamp.time.textContent = marker.label;
          view.timestamp.label = marker.label;
        }
      } else if (view.timestamp) {
        view.timestamp.wrap.remove();
        view.timestamp = null;
      }
      // Capture IDs from the snapshot actually rendered into this DOM node.
      view.node.dataset.sourceIds = JSON.stringify(turn.messageIDs);
      const currentBusy = latest.busy && index === items.length - 1;
      const completed = core.replyFinished(turn,currentBusy);
      const busy = currentBusy && !completed;
      if (turn.role === 'user') {
        const showReceipt = ['delivered','read'].includes(turn.delivery) && index === receiptIndex && !items.slice(index + 1).some(item => item.role === 'assistant');
        const signature = JSON.stringify([turn.text, turn.attachments.map(item => [item.attachmentID,item.name,item.preview,item.format,item.size])]);
        if (view.userSignature !== signature) {
          const firstBubble = view.userSignature === undefined;
          view.userSignature = signature;
          const nodes = [];
          if (turn.attachments.length) {
            const attachments = element('div','message-attachments');
            for (const item of turn.attachments) {
              const card = element('button','message-attachment');
              card.type = 'button'; card.setAttribute('aria-label',t("预览{0}", item.name || t("附件")));
              card.addEventListener('click',() => post('attachment',{attachmentID:item.attachmentID,sessionID:latest.sessionID}));
              if (typeof item.preview === 'string' && /^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(item.preview)) {
                card.classList.add('is-image');
                const image = element('img','attachment-preview'); image.src = item.preview; image.alt = ''; image.decoding = 'async'; card.append(image);
              } else {
                card.append(element('span','attachment-name',item.name || t("附件")),
                  element('span','attachment-size',item.size || ''),element('span','attachment-format',item.format || t("文件")));
              }
              attachments.append(card);
            }
            nodes.push(attachments);
          }
          const bubble = element('div','user-bubble',turn.text);
          if (!hydrated && firstBubble && !replacingOutgoing) bubble.classList.add('user-enter');
          if (turn.text) {
            const row = element('div','user-message-row'); row.append(bubble);
            view.userRow = row;
            nodes.push(row);
          }
          view.parts.replaceChildren(...nodes);
        }
        // Delivery metadata patches the existing bubble; it must never restart its entrance animation.
        let retry = view.userRow?.querySelector('.delivery-retry');
        if (turn.delivery === 'failed' && view.userRow) {
          if (!retry) {
            retry = element('button','delivery-retry'); retry.type = 'button'; retry.append(element('span','delivery-symbol','!'));
            retry.setAttribute('aria-label',t('发送失败，点击重试'));
            retry.addEventListener('click',() => post('retryMessage',{turnID:retry.dataset.turn,sessionID:latest.sessionID}));
            view.userRow.append(retry);
          }
          retry.dataset.turn = turn.turnID; retry.title = turn.deliveryError || t('发送失败');
        } else { retry?.remove(); }
        // Dots keeps the receipt independent of the outgoing bubble and animates
        // only its opacity (initial:false). Its reserved space must not reflow history.
        let receipt = view.parts.querySelector('.read-receipt');
        const receiptLabel = t(turn.delivery === 'read' ? '已读' : '已送达');
        if (!receipt) {
          receipt = element('div','read-receipt',receiptLabel);
          receipt.setAttribute('role','status');
          receipt.setAttribute('data-markdown-copy','exclude');
          view.parts.append(receipt);
        }
        if (receipt.textContent !== receiptLabel) receipt.firstChild.nodeValue = receiptLabel;
        receipt.setAttribute('aria-hidden',String(!showReceipt || (!turn.text && !turn.attachments.length)));
      } else if (turn.role === 'system') {
        if (view.statusText !== turn.text) {
          view.statusText = turn.text;
          view.parts.replaceChildren(element('div','run-status',turn.text));
        }
      } else {
        const ids = new Set();
        turn.parts.forEach((part,position) => {
          ids.add(part.id); let piece = view.pieces.get(part.id);
          if (!piece) {
            piece = part.type === 'text' ? makeProse(part,hydrated) : processView(part);
            piece.node.dataset.part = part.id; piece.type = part.type; view.pieces.set(part.id,piece);
          }
          if (part.type === 'text') {
            piece.target = part.text; piece.streaming = part.streaming;
            piece.shown = piece.target;
            patchMarkdown(piece,piece.shown,piece.streaming,!hydrated);
          } else {
            const toolStillRunning = part.steps.some(step => step.tool && ['running','pending'].includes(step.tool.state));
            collapsed = updateProcess(piece,part,busy && (position === turn.parts.length - 1 || toolStillRunning),completed) || collapsed;
          }
          if (view.parts.children[position] !== piece.node) view.parts.insertBefore(piece.node,view.parts.children[position] || null);
          piece.node.dataset.sourceMessage = part.messageID || '';
        });
        for (const [id,piece] of view.pieces) if (!ids.has(id)) { piece.node.remove(); view.pieces.delete(id); }
        if (turn.attachments.length) {
          const attachmentSignature = JSON.stringify(turn.attachments.map(item => [item.attachmentID,item.name,item.preview,item.format,item.size]));
          if (view.attachmentSignature !== attachmentSignature) {
            view.attachmentSignature = attachmentSignature;
            if (!view.assistantAttachments) {
              view.assistantAttachments = element('div','assistant-attachments');
              view.assistantAttachments.setAttribute('data-markdown-copy','exclude');
              view.node.insertBefore(view.assistantAttachments, view.actions || null);
            }
            const cards = [];
            for (const item of turn.attachments) {
              const card = element('button','assistant-attachment');
              card.type = 'button';
              const nameText = item.name || t("附件");
              const fmtRaw = String(item.format || '').trim();
              const fmtLower = fmtRaw.toLowerCase();
              if (fmtLower) card.dataset.format = fmtLower;
              card.setAttribute('aria-label',t("预览{0}", nameText));
              card.addEventListener('click',() => post('attachment',{attachmentID:item.attachmentID,sessionID:latest.sessionID}));
              const badge = element('span','assistant-attachment-badge',fmtRaw || t("文件"));
              const info = element('span','assistant-attachment-info');
              info.append(
                element('span','assistant-attachment-name',nameText),
                element('span','assistant-attachment-meta',item.size ? `${item.size} · ${t("点击查看")}` : t("点击查看"))
              );
              const chevron = element('span','assistant-attachment-chevron','›');
              chevron.setAttribute('aria-hidden','true');
              card.append(badge, info, chevron);
              cards.push(card);
            }
            view.assistantAttachments.replaceChildren(...cards);
          }
        } else if (view.assistantAttachments) {
          view.assistantAttachments.remove();
          view.assistantAttachments = null;
          view.attachmentSignature = null;
        }
        if (!view.actions) {
          view.actions = element('div','actions');
          view.actions.append(replyButton(t("重新生成回复"),'regenerate','<svg aria-hidden="true" viewBox="0 0 20 20" fill="none"><path d="M16 7a6.3 6.3 0 1 0 .2 5M16 3.5V7h-3.5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>'),element('span','end-status'));
          view.node.append(view.actions);
        }
        view.actions.hidden = turn.state === 'streaming' || !turn.text || (latest.canRegenerate === false && !['failed','truncated'].includes(turn.state));
        view.actions.querySelector('[data-action=regenerate]').disabled = latest.busy;
        view.actions.querySelector('[data-action=regenerate]').hidden = latest.canRegenerate === false;
        view.actions.dataset.message = turn.messageID;
        view.actions.dataset.text = turn.text;
        view.actions.querySelector('.end-status').textContent = { failed:t("回复中断"), truncated:t("已达到回复长度上限") }[turn.state] || '';
      }
      if (root.children[index] !== view.node) root.insertBefore(view.node,root.children[index] || null);
    });
    for (const [id,view] of views) if (!kept.has(id)) { view.node.remove(); views.delete(id); }
    if (collapsed && anchor?.isConnected) {
      const top = scrollY + anchor.getBoundingClientRect().top - anchorTop;
      window.scrollTo({top:Math.max(0,Math.min(maximumScrollTop(),top)),behavior:'auto'});
      pin.top = scrollY;
    }
    const last = items.at(-1), activity = core.responseActivity(items,latest.busy && !latest.stopped,latest.stopped ? 'idle' : latest.contextState);
    const replyBusy = latest.busy && !latest.stopped && activity !== 'idle';
    const contextLabel = core.contextActivityLabel(activity);
    const waiting = latest.waitingForReply ?? (activity === 'waiting');
    // Reserve the reply slot as soon as the local outgoing message exists.
    // A server receipt reveals dots in that slot without scrolling every bubble.
    responseSlot.dataset.reserved = String(!latest.stopped && last?.role === 'user' && last.delivery !== 'failed');
    working.hidden = !waiting && !contextLabel;
    working.dataset.phase = waiting ? 'waiting' : activity;
    updateWaiting(waiting ? `${session}:${last?.id || 'new'}` : null,last?.role === 'assistant');
    if (contextLabel) working.querySelector('.working-label').textContent = contextLabel;
    working.querySelector('.working-label').classList.toggle('activity-shimmer',activity !== 'contextFailed');
    syncActivityMotion();
    if (latest.stopped && !previousStopped) {
      document.querySelector('#announcer').textContent = t("已停止回复");
    } else if (!latest.stopped && contextLabel && activity !== previousActivity) {
      document.querySelector('#announcer').textContent = contextLabel;
    } else if (!latest.stopped && previousBusy !== replyBusy) {
      document.querySelector('#announcer').textContent = replyBusy ? t("助理正在回复") :
        last?.state === 'failed' ? t("回复中断") : t("回复已完成");
    }
    previousBusy = replyBusy; previousStopped = !!latest.stopped;
    previousActivity = activity;
    follow();
  }
  function updateWaiting(key, afterTool) {
    if (waitingTimer !== null) { clearTimeout(waitingTimer); waitingTimer = null; }
    if (key !== waitingKey) { waitingKey = key; waitingSince = performance.now(); }
    if (key === null) return;
    const seconds = Math.floor((performance.now() - waitingSince) / 1000);
    working.querySelector('.working-label').textContent = seconds >= 10 ? t("仍在等待回复 · {0} 秒", seconds) : afterTool ? t("正在整理回复") : t("正在准备回复");
    if (!document.hidden && !pageSuspended) waitingTimer = setTimeout(() => updateWaiting(key,afterTool),1000);
  }
  function follow() {
    if (frame !== null) return;
    frame = requestAnimationFrame(() => {
      frame = null;
      if (restoring && !userScrolling && !wheelScrolling) {
        restoreReadingPosition();
      } else if (pin.pinned && !userScrolling) {
        window.scrollTo({ top:maximumScrollTop(), behavior:'auto' });
        pin.top = window.scrollY;
      }
      document.querySelector('#jump').hidden = pin.pinned || maximumScrollTop() - scrollY <= 8;
      scheduleReadingPosition();
    });
  }
  function headerInset() { return latest?.appearance?.headerInset || 0; }
  function maximumScrollTop() {
    return Math.max(0,document.documentElement.scrollHeight - window.innerHeight);
  }
  function restoreReadingPosition() {
    if (!restoring) return;
    const anchor = restoring.anchorID && [...root.children].find(node => node.dataset.message === restoring.anchorID);
    const maximum = maximumScrollTop();
    const top = restoring.following ? maximum :
      anchor ? scrollY + anchor.getBoundingClientRect().top - headerInset() - restoring.anchorOffset : restoring.top;
    // WebKit's native scroll update can apply the requested value after the DOM
    // has already clamped it. Never request a position outside this layout.
    window.scrollTo({ top:Math.max(0,Math.min(maximum,top)), behavior:'auto' });
    pin.pinned = restoring.following;
    pin.top = scrollY;
  }
  function stopRestoring() { restoring = null; restoreEpoch++; }
  function focusNotification(target) {
    if (!target || target.requestID === focusedRequest) return;
    const row = [...root.children].find(node => JSON.parse(node.dataset.sourceIds || '[]').includes(target.messageID));
    if (!row) return; // Replay/history may not have reached the requested message yet.
    const anchor = [...row.querySelectorAll('[data-source-message]')].find(node => node.dataset.sourceMessage === target.messageID) || row;
    stopRestoring(); pin.pinned = false;
    window.scrollTo({ top: Math.max(0, Math.min(maximumScrollTop(), scrollY + anchor.getBoundingClientRect().top - headerInset() - 16)), behavior: 'auto' });
    pin.top = scrollY; focusedRequest = target.requestID;
    scheduleReadingPosition();
  }
  function saveReadingPosition() {
    clearTimeout(readingTimer); readingTimer = null;
    if (!latest || session === 'new' || restoring) return;
    const top = scrollY;
    // Preserve the last settled position during native overscroll. Do not turn
    // an out-of-bounds visible offset into a seemingly valid persisted anchor.
    if (top < 0 || top > maximumScrollTop()) { scheduleReadingPosition(); return; }
    const anchor = [...root.children].find(node => node.getBoundingClientRect().bottom > headerInset());
    const visibleMessageIDs = [...root.children].filter(node => {
      const rect = node.getBoundingClientRect();
      return rect.height > 0 && rect.bottom > headerInset() && rect.bottom <= innerHeight;
    }).flatMap(node => JSON.parse(node.dataset.sourceIds || '[]')).slice(-500);
    const value = { sessionID:session, following:pin.pinned, top, visibleMessageIDs,
      anchorID:anchor?.dataset.message || null, anchorOffset:anchor ? anchor.getBoundingClientRect().top - headerInset() : 0 };
    const encoded = JSON.stringify(value);
    if (encoded !== lastReading) { lastReading = encoded; post('readingPosition',value); }
  }
  function scheduleReadingPosition() {
    if (readingTimer === null) readingTimer = setTimeout(saveReadingPosition,150);
  }
  function render(snapshot) {
    if (snapshot.locale && snapshot.locale !== latest?.locale) {
      core.setLocale(snapshot.locale);
      document.documentElement.lang = snapshot.locale;
      document.title = t('聊天');
      root.setAttribute('aria-label', t('聊天记录'));
      document.querySelector('#jump').setAttribute('aria-label', t('回到最新消息'));
      views.clear(); root.replaceChildren();
      previousTurnCount = -1; referenceNowMs = Date.now();
    }
    if (snapshot.sessionID !== session) {
      saveReadingPosition();
      session = snapshot.sessionID; views.clear(); root.replaceChildren(); pin.reset(); first = true; focusedRequest = null;
      previousTurnCount = -1; referenceNowMs = Date.now();
      previousBusy = false; previousStopped = false; previousActivity = 'idle';
      lastReading = null; userScrolling = false; wheelScrolling = false;
      restoring = snapshot.readingPosition?.sessionID === session ? snapshot.readingPosition : null;
      const epoch = ++restoreEpoch;
      if (restoring) {
        pin.pinned = restoring.following;
        // Restore after layout and bundled font settlement; an actual new gesture cancels this intent.
        document.fonts.ready.then(() => requestAnimationFrame(() => requestAnimationFrame(() => {
          if (epoch !== restoreEpoch || !restoring) return;
          restoreReadingPosition(); restoring = null; saveReadingPosition();
        })));
      }
    }
    latest = snapshot; reduced = !!snapshot.appearance.reduceMotion;
    document.documentElement.dataset.dark = String(snapshot.appearance.dark);
    document.documentElement.dataset.reduceMotion = String(reduced);
    document.documentElement.dataset.largeType = String(snapshot.appearance.scale > 1.4);
    const isDesktop = !!snapshot.appearance.desktopHeader;
    document.documentElement.toggleAttribute('data-desktop', isDesktop);
    document.documentElement.toggleAttribute('data-desktop-edge', isDesktop && headerInset() > 0);
    document.documentElement.style.setProperty('--header-inset', headerInset() + 'px');
    document.documentElement.style.setProperty('--scale',Math.max(.8,Math.min(3.2,snapshot.appearance.scale)));
    renderTurns(first); first = false;
    focusNotification(snapshot.focus);
  }
  document.addEventListener('click',event => {
    const anchor = event.target.closest('a');
    if (anchor) { event.preventDefault(); post('link',anchor.getAttribute('href')); return; }
    const action = event.target.closest('button[data-action]');
    if (!action) return;
    if (action.dataset.action === 'regenerate') {
      if (!latest.busy) post('regenerate',{ sessionID:session, messageID:action.closest('.actions')?.dataset.message });
      return;
    }
    const value = action.dataset.action === 'copy-code' ? action.closest('.code-wrap').querySelector('code')?.textContent :
      action.closest('.actions')?.dataset.text;
    if (value != null) {
      post('copy',value); const original = [...action.childNodes].map(node => node.cloneNode(true));
      action.innerHTML = '<svg aria-hidden="true" viewBox="0 0 20 20" fill="none"><path d="m5 10 3.2 3.2L15 6.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
      action.setAttribute('aria-label',t("已复制"));
      setTimeout(() => { if (action.isConnected) { action.replaceChildren(...original); action.setAttribute('aria-label',action.dataset.action === 'copy-code' ? t("复制代码") : t("复制回复")); } },1000);
    }
  });
  function scrollToBottom() { stopRestoring(); pin.pinned = true; follow(); }
  document.querySelector('#jump').addEventListener('click',scrollToBottom);
  window.addEventListener('scroll',() => {
    if (restoring) return;
    // Native scroll updates can return to an older offset before settling at the
    // requested bottom. Observe both directions so reaching that bottom restores
    // following; upward movement away from it still releases the reading position.
    pin.observe(window.scrollY,window.innerHeight,document.documentElement.scrollHeight);
    document.querySelector('#jump').hidden = pin.pinned;
    scheduleReadingPosition();
  },{ passive:true });
  window.addEventListener('scrollend',saveReadingPosition,{ passive:true });
  window.addEventListener('wheel',() => { stopRestoring(); wheelScrolling = true; clearTimeout(wheelTimer); wheelTimer = setTimeout(() => { wheelScrolling = false; },300); },{ passive:true });
  window.addEventListener('touchstart',() => { stopRestoring(); userScrolling = true; },{ passive:true });
  window.addEventListener('keydown',stopRestoring);
  const finishTouch = () => { userScrolling = false; };
  window.addEventListener('touchend',finishTouch,{ passive:true });
  window.addEventListener('touchcancel',finishTouch,{ passive:true });
  document.addEventListener('selectionchange',() => {
    if (window.getSelection()?.isCollapsed && latest) renderTurns(false);
  });
  new ResizeObserver(follow).observe(document.body);
  // A growing native composer/keyboard resizes the viewport, not necessarily the body.
  window.addEventListener('resize',follow);
  window.visualViewport?.addEventListener('resize',follow);
  document.addEventListener('visibilitychange',() => {
    if (document.hidden) saveReadingPosition();
    syncActivityMotion();
    if (!document.hidden && latest) {
      for (const view of views.values()) for (const piece of view.pieces.values()) {
        if (piece.type === 'text') piece.shown = piece.target;
      }
      renderTurns(false);
    }
  });
  motionPreference.addEventListener('change',syncActivityMotion);
  function suspend() {
    pageSuspended = true;
    brandMotion.suspend();
    saveReadingPosition(); working.dataset.animating = 'false';
    document.documentElement.dataset.activityAnimating = 'false';
    if (waitingTimer !== null) { clearTimeout(waitingTimer); waitingTimer = null; }
  }
  window.addEventListener('pagehide',suspend);
  window.addEventListener('pageshow',() => {
    pageSuspended = false; brandMotion.resume();
    if (latest) renderTurns(false); else syncActivityMotion();
  });
  window.MoMoChat = { render, scrollToBottom, saveReadingPosition, suspend };
  post('ready',true);
})();
