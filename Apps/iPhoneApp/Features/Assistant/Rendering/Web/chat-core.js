/* Presentation rules only: no provider, persistence, tools, networking or SDK access. */
(() => {
  'use strict';
  const t = (key, ...args) => globalThis.MoMoChatLocalization ? MoMoChatLocalization.text(key, ...args) : key.replace(/\{(\d+)\}/g, (_, i) => String(args[Number(i)] ?? ''));
  let currentLocale = 'zh-Hans';
  let segmenter = new Intl.Segmenter('zh', { granularity: 'grapheme' });
  const graphemes = text => [...segmenter.segment(text)].map(item => item.segment);
  const TIMESTAMP_GROUP_WINDOW_MS = 30 * 60 * 1000;

  function sameCalendarDay(first, second) {
    return first.getFullYear() === second.getFullYear() &&
      first.getMonth() === second.getMonth() &&
      first.getDate() === second.getDate();
  }
  function shouldShowTimestampMarker(previousMarkerSentAtMs, sentAtMs) {
    if (!Number.isFinite(sentAtMs)) return false;
    if (!Number.isFinite(previousMarkerSentAtMs)) return true;
    const previous = new Date(previousMarkerSentAtMs), current = new Date(sentAtMs);
    if (!Number.isFinite(previous.getTime()) || !Number.isFinite(current.getTime())) return false;
    if (!sameCalendarDay(previous, current)) return true;
    return sentAtMs - previousMarkerSentAtMs >= TIMESTAMP_GROUP_WINDOW_MS;
  }
  function formatTimestampMarker(sentAtMs, nowMs = Date.now()) {
    if (!Number.isFinite(sentAtMs)) return null;
    const date = new Date(sentAtMs);
    if (!Number.isFinite(date.getTime())) return null;
    const now = Number.isFinite(nowMs) ? new Date(nowMs) : new Date();
    const activeLocale = globalThis.MoMoChatLocalization?.locale || currentLocale;
    const intlLocale = ({ 'zh-Hans': 'zh-CN', en: 'en-US', ja: 'ja-JP', ko: 'ko-KR' })[activeLocale] || 'en-US';
    const targetDay = Date.UTC(date.getFullYear(), date.getMonth(), date.getDate());
    const today = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
    const dayOffset = Math.round((targetDay - today) / 86_400_000);
    if (dayOffset === 0 || dayOffset === -1) {
      const time = new Intl.DateTimeFormat(intlLocale, { hour: 'numeric', minute: '2-digit' }).format(date);
      return dayOffset === 0 ? t("今天 {0}", time) : t("昨天 {0}", time);
    }
    const sameYear = date.getFullYear() === now.getFullYear();
    return new Intl.DateTimeFormat(intlLocale, {
      year: sameYear ? undefined : 'numeric',
      month: 'short',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit'
    }).format(date);
  }

  // Recognize only complete recording references. Native archive validation still decides
  // whether the cited version/span exists; presentation must never retarget a citation.
  const sourceUUID = '[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}';
  const sourceURLPattern = new RegExp(`^momoagent://source/${sourceUUID}/${sourceUUID}\\?(?:version=([1-9][0-9]*)&generation=(0|[1-9][0-9]*)|generation=(0|[1-9][0-9]*)&version=([1-9][0-9]*))$`, 'i');
  function isRecordingSourceURL(value) {
    const match = sourceURLPattern.exec(value);
    return Boolean(match && match.slice(1).filter(Boolean).every(number =>
      number.length < 19 || (number.length === 19 && number <= '9223372036854775807')));
  }
  function installRecordingSourceLinks(parser) {
    parser.use({ extensions: [{
      name: 'recordingSource', level: 'inline',
      start: source => source.toLowerCase().indexOf('momoagent://source/'),
      tokenizer(source) {
        // Keep surrounding prose punctuation outside the link. Code blocks/spans and
        // explicit Markdown links retain their own tokenizer and semantics.
        if (this.lexer.state.inLink) return;
        const candidate = /^momoagent:\/\/source\/[^\s<>"'`，。；！？、（）【】\[\]()]+/i.exec(source);
        const href = candidate?.[0].replace(/[.,;:!?]+$/, '');
        return href && isRecordingSourceURL(href) ? { type: 'recordingSource', raw: href, href } : undefined;
      },
      renderer(token) {
        return `<a href="${token.href.replace(/&/g, '&amp;')}" class="recording-source">${t("查看录音")}</a>`;
      }
    }] });
  }

  // Text is never queued: only the newly received tail fades for 100 ms in the DOM.
  function advance(shown, target) { return { text: target, delay: 0 }; }
  function stablePrefix(previous, next) {
    if (!next.startsWith(previous)) return '';
    let end = 0;
    for (const item of segmenter.segment(next)) {
      const boundary = item.index + item.segment.length;
      if (boundary > previous.length) break;
      end = boundary;
    }
    return next.slice(0, end);
  }

  class PinState {
    pinned = true;
    top = 0;
    observe(top, viewport, height) {
      const near = Math.ceil(top + viewport) >= Math.floor(height - 8);
      if (top > this.top && near) this.pinned = true;
      if (top < this.top && !near) this.pinned = false;
      this.top = top;
      return this.pinned;
    }
    reset() { this.pinned = true; this.top = 0; }
  }

  const labels = {
    get_context_status: ['核对资料范围', '已核对资料范围', 'document.text.magnifyingglass'],
    list_recordings: ['查找录音', '已查找录音', 'waveform'],
    search_transcripts: ['搜索录音内容', '已搜索录音内容', 'search'],
    read_transcript: ['读取录音原文', '已读取录音原文', 'document'],
    memory: ['更新记忆', '已更新记忆', 'document']
  };
  function baseToolName(name) {
    return String(name || '').replace(/^mcp_momo_(?:pim|context|recordings|computer)_/, '');
  }
  const systemWrites = new Set(['create_calendar_event','update_calendar_event','delete_calendar_event','create_reminder','update_reminder','complete_reminder','delete_reminder','create_note','update_note','delete_note','schedule_alarm','reschedule_alarm','cancel_alarm']);
  const actionStates = new Set(['executing','succeeded','failed','needs_clarification','needs_permission','conflict','outcome_unknown','cancelled']);
  function actionReceipt(tool) {
    const tName = baseToolName(tool.name);
    if (!systemWrites.has(tName) || tool.output == null) return null;
    try {
      const value = JSON.parse(tool.output);
      return typeof value.actionID === 'string' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value.actionID) && actionStates.has(value.state) ? value : null;
    } catch { return null; }
  }
  function actionCard(tool, receipt) {
    const tName = baseToolName(tool.name);
    const fields = receipt.resource?.fields || {};
    const kinds = {schedule_alarm:'alarm',reschedule_alarm:'alarm',cancel_alarm:'alarm',create_reminder:'reminder',update_reminder:'reminder',complete_reminder:'reminder',delete_reminder:'reminder',create_calendar_event:'event',update_calendar_event:'event',delete_calendar_event:'event',create_note:'note',update_note:'note',delete_note:'note'};
    const kind = receipt.resource?.kind || kinds[tName] || 'event';
    const names = {alarm:t("闹钟"),reminder:t("待办"),event:t("日程"),note:t("备忘录")};
    const states = {executing:t("正在处理"),succeeded:t("操作已确认"),failed:t("未完成"),needs_clarification:t("需要补充信息"),needs_permission:t("需要连接权限"),conflict:t("系统内容已变化"),outcome_unknown:t("结果待核对"),cancelled:t("已取消")};
    const successes = {schedule_alarm:t("已设定"),reschedule_alarm:t("已更新"),cancel_alarm:t("已取消"),create_reminder:t("已添加"),update_reminder:t("已更新"),complete_reminder:t("已完成"),delete_reminder:t("已删除"),create_calendar_event:t("已添加"),update_calendar_event:t("已更新"),delete_calendar_event:t("已删除"),create_note:t("已添加"),update_note:t("已更新"),delete_note:t("已删除")};
    let time = null, detail = null;
    const weekly = fields.weeklySchedule;
    if (kind === 'note') {
      detail = typeof fields.folder === 'string' && fields.folder ? fields.folder : t("备忘录");
    } else if (kind === 'alarm' && weekly) {
      if (Number.isInteger(weekly.hour) && Number.isInteger(weekly.minute)) time = [weekly.hour,weekly.minute].map(v => String(v).padStart(2,'0')).join(':');
      const weekdays = [t("周一"),t("周二"),t("周三"),t("周四"),t("周五"),t("周六"),t("周日")];
      const locale = globalThis.MoMoChatLocalization?.locale || 'zh-CN';
      const items = [...(weekly.weekdays || [])].sort((a,b) => a-b).map(v => weekdays[v-1]).filter(Boolean);
      detail = locale.startsWith('zh') ? items.join('、') : new Intl.ListFormat(locale, { type: 'unit', style: 'short' }).format(items);
      if (detail) detail += t(" · 跟随设备时区");
    } else {
      const raw = kind === 'alarm' ? fields.fireAt : kind === 'reminder' ? fields.dueAt || fields.dueDate : fields.start;
      if (typeof raw === 'string') {
        const dateOnly = /^\d{4}-\d{2}-\d{2}$/.test(raw), date = new Date(dateOnly ? raw+'T12:00:00Z' : raw);
        if (Number.isFinite(date.getTime())) {
          const timeZone = dateOnly ? 'UTC' : fields.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone;
          try {
            detail = new Intl.DateTimeFormat(globalThis.MoMoChatLocalization?.locale || 'zh-CN',{timeZone,month:'long',day:'numeric',weekday:'short'}).format(date);
            if (!dateOnly) time = new Intl.DateTimeFormat(globalThis.MoMoChatLocalization?.locale || 'zh-CN',{timeZone,hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).format(date);
          } catch { detail = t("时间信息待核对"); }
        } else detail = t("时间信息待核对");
      } else detail = kind === 'reminder' ? t("未设截止日期") : t("时间待核对");
    }
    if (kind === 'reminder' && fields.completed === true) detail = detail ? t("已完成 · ")+detail : t("已完成");
    return {kind,kindLabel:names[kind] || t("系统事项"),title:typeof fields.title === 'string' && fields.title ? fields.title : names[kind] || t("系统事项"),
      time,detail,status:receipt.state === 'succeeded' ? successes[tName] || states.succeeded : states[receipt.state],state:receipt.state};
  }
  function toolDisplayState(tool) {
    const receipt = actionReceipt(tool);
    if (!receipt) return tool.state;
    if (receipt.state === 'succeeded') return 'succeeded';
    if (receipt.state === 'executing') return 'running';
    return receipt.state === 'cancelled' ? 'interrupted' : receipt.state;
  }
  Object.assign(labels, {
    web_search:['搜索网页','已搜索网页'],web_fetch:['读取网页','已读取网页'],
    list_calendars:['查看日历','已查看日历'],search_calendar_events:['查找日程','已查找日程'],read_calendar_event:['读取日程','已读取日程'],
    create_calendar_event:['添加日程','已添加日程'],update_calendar_event:['修改日程','已修改日程'],delete_calendar_event:['删除日程','已删除日程'],
    list_reminder_lists:['查看提醒事项列表','已查看提醒事项列表'],search_reminders:['查找待办','已查找待办'],read_reminder:['读取待办','已读取待办'],
    create_reminder:['添加待办','已添加待办'],update_reminder:['修改待办','已修改待办'],complete_reminder:['更新完成状态','已更新完成状态'],delete_reminder:['删除待办','已删除待办'],
    list_note_folders:['查看备忘录文件夹','已查看备忘录文件夹'],search_notes:['查找备忘录','已查找备忘录'],read_note:['读取备忘录','已读取备忘录'],
    create_note:['添加备忘录','已添加备忘录'],update_note:['修改备忘录','已修改备忘录'],delete_note:['删除备忘录','已删除备忘录'],
    list_alarms:['查看闹钟','已查看闹钟'],schedule_alarm:['设置闹钟','已设置闹钟'],reschedule_alarm:['调整闹钟','已调整闹钟'],cancel_alarm:['取消闹钟','已取消闹钟'],
    query_life_timeline:['查看生活事件','已查看生活事件'],get_health_summary:['查看健康摘要','已查看健康摘要'],get_system_capabilities:['检查系统连接','已检查系统连接'],
    get_mail_connection:['检查邮箱连接','已检查邮箱连接'],search_mail:['查找邮件','已查找邮件'],read_mail_thread:['读取邮件','已读取邮件'],create_mail_draft:['保存邮件草稿','已保存草稿'],send_mail:['发送邮件','已发送邮件'],reply_mail:['回复邮件','已回复邮件']
  });
  function toolLabel(tool) {
    const tName = baseToolName(tool.name);
    if (tName === 'memory') {
      try {
        if (JSON.parse(tool.input).action === 'read')
          return tool.state === 'succeeded' ? t("已查看记忆") : t("查看记忆");
      } catch { /* Malformed input still has an execution state to display. */ }
    }
    const receipt = actionReceipt(tool);
    if (receipt && receipt.state !== 'succeeded') return ({executing:t("正在处理"),failed:t("操作未完成"),needs_clarification:t("需要补充信息"),needs_permission:t("需要连接权限"),conflict:t("系统内容已变化"),outcome_unknown:t("结果待核对"),cancelled:t("已取消")})[receipt.state];
    const pair = labels[tName];
    if (!pair) return tool.state === 'succeeded' ? t("操作已完成") : t("处理请求");
    return t(pair[tool.state === 'succeeded' ? 1 : 0]);
  }
  function toolPreview(tool) {
    try {
      const input = JSON.parse(tool.input);
      return String(input.query ?? input.title ?? input.url ?? '').slice(0, 180);
    } catch { return ''; }
  }
  function toolOutcome(tool) {
    if (tool.output == null) return null;
    let value;
    try { value = JSON.parse(tool.output); } catch { return null; }
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
    if (tool.name === 'web_search' && Array.isArray(value.results))
      return {summary:t("本次找到 {0} 个网页", value.results.length), text:value.results.map(result => `${result.title || ''}\n${result.url || ''}\n${result.snippet || ''}`).join('\n\n')};
    if (tool.name === 'web_fetch' && typeof value.content === 'string')
      return {summary:t("已读取网页正文"),text:value.content,more:value.nextOffset != null};
    if (['search_transcripts','read_transcript'].includes(tool.name) && Array.isArray(value.passages)) {
      if (!value.passages.every(passage => passage && typeof passage.text === 'string')) return null;
      const passages = value.passages;
      return { summary: passages.length ? t("本次返回 {0} 段原文", passages.length) : t("本次没有找到相关原文"),
        text: passages.map(passage => passage.text).join('\n\n'),
        more: value.hasMore === true || value.nextCursor != null };
    }
    if (tool.name === 'list_recordings' && Array.isArray(value.items))
      return { summary:t("本次返回 {0} 条录音", value.items.length), more:value.nextCursor != null };
    if (tool.name === 'get_context_status' && Number.isInteger(value.recordingCount) && Number.isInteger(value.pendingAnalysisCount))
      return { summary:t("{0} 条录音，{1} 条待处理", value.recordingCount, value.pendingAnalysisCount) };
    return null;
  }

  // Claude's loading/tool/writing split, applied only to the current reply.
  function responseActivity(items, busy, contextState = 'idle') {
    if (contextState === 'failed') return 'contextFailed';
    if (!busy) return 'idle';
    if (contextState === 'compacting') return 'compacting';
    const waiting = contextState === 'compacted' ? 'compacted' : 'waiting';
    const last = items.at(-1);
    if (!last || last.role === 'user') return waiting;
    const steps = last.parts.flatMap(part => part.type === 'process' ? part.steps : []);
    if (steps.some(step => step.tool && ['pending','running'].includes(toolDisplayState(step.tool)))) return 'tool';
    const tail = last.parts.at(-1);
    if (tail?.type === 'text' && tail.text) return tail.streaming ? 'writing' : last.state === 'streaming' ? waiting : 'idle';
    if (last.state === 'failed' || last.state === 'stopped' || last.state === 'truncated') return 'idle';
    if (tail?.steps.at(-1)?.type === 'reasoning' && last.state === 'streaming') return 'thinking';
    return waiting;
  }
  function contextActivityLabel(activity) {
    return { compacting:t("正在整理较早的对话，以便继续聊天…"), compacted:t("较早的对话已整理，正在继续回复…"),
      contextFailed:t("整理对话未完成，聊天记录已保留，请重试。") }[activity] || null;
  }
  function processSummary(steps, busy) {
    const tools = steps.filter(step => step.type === 'tool').map(step => step.tool);
    const running = tools.find(tool => tool.state === 'running' || tool.state === 'pending');
    if (busy && running) return toolLabel(running);
    const failed = tools.filter(tool => toolDisplayState(tool) === 'failed').length;
    const interrupted = tools.filter(tool => toolDisplayState(tool) === 'interrupted').length;
    const done = tools.filter(tool => toolDisplayState(tool) === 'succeeded').length;
    const unfinished = tools.filter(tool => ['pending','running'].includes(toolDisplayState(tool))).length;
    const pending = ['outcome_unknown','needs_permission','needs_clarification','conflict'].map(state => {
      const count = tools.filter(tool => toolDisplayState(tool) === state).length;
      const label = {outcome_unknown:t("结果待核对"),needs_permission:t("需要连接权限"),needs_clarification:t("需要补充信息"),conflict:t("系统内容已变化")}[state];
      return count ? t("{0} 项{1}", count, label) : '';
    });
    if (!tools.length) return busy ? t("正在思考") : t("思考过程");
    return [done ? t("已完成 {0} 项操作", done) : '', failed ? t("{0} 项失败", failed) : '',
      interrupted ? t("{0} 项已中断", interrupted) : '', unfinished ? t("{0} 项未确认完成", unfinished) : '', ...pending].filter(Boolean).join(' · ') || t("等待执行");
  }

  function replyFinished(turn, busy) {
    if (['failed','stopped','truncated'].includes(turn.state)) return true;
    // A complete tool-only message can still be between model rounds.
    return turn.state === 'complete' && (!busy || turn.parts.at(-1)?.type === 'text');
  }

  function turns(messages) {
    const result = [];
    for (const message of messages) {
      let turn = result.at(-1);
      if (message.role !== 'assistant' || !turn || turn.role !== 'assistant' || turn.turnID !== message.turnID) {
        // A task may speak again after other tasks. Its run ID is not a unique UI row.
        turn = { id: message.role !== 'assistant' ? message.id : `${message.id}:reply`,
          turnID: message.turnID, role: message.role, state: message.state, sentAtMs: null,
          parts: [], text: '', attachments: [], messageIDs: [] };
        result.push(turn);
      }
      if (message.role !== 'system' && turn.sentAtMs == null && Number.isFinite(message.sentAtMs)) {
        turn.sentAtMs = message.sentAtMs;
      }
      turn.messageIDs.push(message.id);
      turn.state = message.state; turn.messageID = message.id;
      turn.delivery = message.delivery; turn.deliveryError = message.deliveryError;
      let messageText = '';
      message.blocks.forEach((block, index) => {
        if (block.type === 'text') {
          if (!block.text) return;
          const streaming = message.state === 'streaming' && index === message.blocks.length - 1;
          const previous = turn.parts.at(-1);
          if (previous?.type === 'text' && previous.messageID === message.id) {
            previous.text += block.text; previous.streaming = streaming;
          } else turn.parts.push({ ...block, messageID:message.id, streaming });
          messageText += block.text;
        } else if (block.type === 'attachment' && (message.role === 'user' || message.role === 'assistant')) {
          if (!block.attachmentID || !turn.attachments.some(item => item.attachmentID === block.attachmentID)) {
            turn.attachments.push(block);
          }
        } else {
          let process = turn.parts.at(-1);
          if (process?.type !== 'process') {
            process = { id: `${block.id}:process`, type: 'process', steps: [] };
            turn.parts.push(process);
          }
          process.steps.push(block);
        }
      });
      if (messageText) turn.text += (turn.text ? '\n\n' : '') + messageText;
    }
    for (const turn of result) turn.parts = turn.parts.filter(part => part.type !== 'text' || part.text.trim());
    return result;
  }

  class MarkdownStream {
    source = '';
    committed = [];
    offset = 0;
    links = {};
    constructor(parser) { this.parser = parser; }
    update(source, streaming) {
      if (!source.startsWith(this.source) || !streaming) {
        this.committed = []; this.offset = 0; this.links = {};
      }
      const tokens = this.parser.lexer(source.slice(this.offset));
      Object.assign(this.links, tokens.links);
      const render = (token, offset, tail) => {
        const raw = token.raw;
        const normalized = tail && streaming ? globalThis.remend(raw) : raw;
        // Unfinished syntax remains literal until it closes; never invent a delimiter or link target.
        const fence = /^ {0,3}(`{3,}|~{3,})[^\n]*\n/.exec(raw);
        const openFence = fence && !new RegExp('\\n {0,3}' + fence[1][0] + '{' + fence[1].length + ',}[ \t]*\\n?$').test(raw);
        if (tail && streaming && (normalized !== raw || openFence)) {
          const escaped = raw.replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
          return { id:String(offset), raw, html:`<p class="unfinished">${escaped}</p>`, tail };
        }
        const parsed = [token];
        parsed.links = { ...this.links, ...parsed.links };
        return { id: String(offset), raw, html: this.parser.parser(parsed), tail };
      };
      const remaining = [];
      let cursor = this.offset;
      tokens.forEach((token, index) => {
        const tail = streaming && index === tokens.length - 1;
        const piece = token.type === 'space' || token.type === 'def' ? null : render(token, cursor, tail);
        cursor += token.raw.length;
        if (tail) { if (piece) remaining.push(piece); }
        else { if (piece) this.committed.push(piece); this.offset = cursor; }
      });
      this.source = source;
      return [...this.committed, ...remaining];
    }
  }

  function setLocale(locale) {
    globalThis.MoMoChatLocalization?.setLocale(locale);
    const language = String(locale || 'en').toLowerCase().split(/[-_]/)[0];
    currentLocale = globalThis.MoMoChatLocalization?.locale ||
      (language === 'zh' ? 'zh-Hans' : ['en', 'ja', 'ko'].includes(language) ? language : 'en');
    segmenter = new Intl.Segmenter(locale || 'en', {granularity:'grapheme'});
  }
  globalThis.MoMoChatCore = { setLocale, advance, stablePrefix, graphemes, PinState, turns, shouldShowTimestampMarker, formatTimestampMarker, toolLabel, toolPreview, toolOutcome, responseActivity, contextActivityLabel, actionReceipt, actionCard, toolDisplayState, processSummary, replyFinished, MarkdownStream, isRecordingSourceURL, installRecordingSourceLinks };
})();
