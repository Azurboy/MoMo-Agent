'use strict';
const el = id => document.getElementById(id);
const svgNamespace = 'http://www.w3.org/2000/svg';
const clock = new Intl.DateTimeFormat('zh-CN', {hour:'2-digit', minute:'2-digit', hour12:false});
const day = new Intl.DateTimeFormat('zh-CN', {year:'numeric', month:'long', day:'numeric'});
const state = {
  session:0, paired:false, status:null, statusError:'', chatError:'', tab:'chat',
  snapshot:null, history:new Map(), canLoadHistory:false, outbox:new Map(), renderKey:'',
  lists:Object.create(null), recordingTab:'recordings',
  avatar:null, receipt:'', recordDetail:null, detailID:0
};
function element(tag, className, value) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (value != null) node.textContent = value;
  return node;
}
function icon(name, className) {
  const svg = document.createElementNS(svgNamespace,'svg');
  if (className) svg.setAttribute('class',className);
  svg.setAttribute('aria-hidden','true');
  const use = document.createElementNS(svgNamespace,'use');
  use.setAttribute('href','/icons.svg#'+name);
  svg.append(use);
  return svg;
}
function action(label, handler, className='outline mini') {
  const button = element('button',className,label);
  button.type = 'button';
  button.addEventListener('click',handler);
  return button;
}
function paragraph(value, className='') { return element('p',className,value); }
function stamp(seconds, format=clock) {
  const value = Number(seconds);
  if (!(value > 0) || !Number.isFinite(value)) return '';
  const date = new Date(value * 1000);
  return Number.isFinite(date.getTime()) ? format.format(date) : '';
}
function interval(seconds) {
  const amount = Math.max(0,Math.floor(Number(seconds)||0));
  const mins = Math.floor(amount/60);
  return mins ? mins+' 分 '+(amount%60)+' 秒' : amount+' 秒';
}
function uuid() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('');
  return [hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join('-');
}
async function api(path, options={}) {
  const {method='GET', body, requiresPair=true} = options;
  const generation = state.session;
  const controller = new AbortController();
  const timeout = setTimeout(()=>controller.abort(),25000);
  try {
    const response = await fetch(path,{
      method, credentials:'same-origin', cache:'no-store', signal:controller.signal,
      headers:body ? {'Content-Type':'application/json','Accept':'application/json'} : {'Accept':'application/json'},
      body:body ? JSON.stringify(body) : undefined
    });
    if (response.status === 401 && requiresPair && generation===state.session) showGate('pair');
    if (!response.ok) {
      let message = '';
      try {
        const detail = await response.json();
        message = typeof detail.error === 'string' ? detail.error : detail.error?.message || detail.message || '';
      } catch { /* Some upstream failures have no JSON body. */ }
      const error = new Error(message || ('Mac 返回了 '+response.status));
      error.status = response.status;
      throw error;
    }
    return response.status===204 ? {} : await response.json();
  } finally { clearTimeout(timeout); }
}
function errorLabel(error) {
  if (error.status===403) return '这台设备暂时没有访问权限。';
  if (error.status===429) return '请求较多，请稍后重试。';
  if (!error.status || error.status>=500) return '暂时连不上 Mac，请检查网络和 Mac 服务。';
  return error.message || '读取失败，请重试。';
}
function emptyState(target, symbol, title, note, retry) {
  const group=element('div','empty');
  group.append(icon(symbol),element('strong','',title));
  if (note) group.append(element('small','',note));
  if (retry) group.append(action('重试',retry));
  target.replaceChildren(group);
}
function markdown(node, value) {
  const text=String(value ?? '');
  if (!window.marked?.parse || !window.DOMPurify?.sanitize) {
    node.textContent=text;
    node.classList.add('plain-record');
    return;
  }
  const safe=DOMPurify.sanitize(marked.parse(text,{gfm:true, breaks:true, async:false}),{
    ALLOWED_TAGS:['a','b','blockquote','br','code','del','em','h1','h2','h3','h4','h5','h6','hr','i','li','ol','p','pre','s','strong','table','tbody','td','th','thead','tr','ul'],
    ALLOWED_ATTR:['href','start'], RETURN_DOM_FRAGMENT:true
  });
  for (const link of safe.querySelectorAll('a')) {
    const href=link.getAttribute('href')||'';
    if (!/^https?:\/\//i.test(href)) { link.replaceWith(...link.childNodes); continue; }
    link.target='_blank'; link.rel='noopener noreferrer';
  }
  node.replaceChildren(safe);
}
function banner() {
  const n=el('network-banner');
  const value=state.statusError || state.chatError || (state.status?.mac?.online===false?'Mac 已连接，Agent 暂未就绪。':'');
  n.textContent=value; n.hidden=!value;
}
function showGate(mode) {
  state.session++;
  state.paired=false; state.status=null; state.statusError=''; state.chatError='';
  state.snapshot=null; state.history.clear(); state.outbox.clear(); state.canLoadHistory=false;
  state.lists=Object.create(null); state.renderKey=''; state.tab='chat'; state.recordingTab='recordings';
  state.receipt='';
  el('chat').classList.remove('has-placement','is-empty');
  el('chat-skeleton').hidden=true; el('retry-chat').hidden=true;
  el('show-recordings').setAttribute('aria-pressed','true'); el('show-sources').setAttribute('aria-pressed','false');
  el('send').disabled=true;
  el('workspace').hidden=true; el('gate').hidden=false;
  el('open-settings').hidden=true; el('top-install').hidden=false;
  el('pair-form').hidden=mode!=='pair'; el('gate-retry').hidden=mode!=='offline';
  el('pair-code').value=''; el('draft').value='';
  for (const id of ['messages','record-list','memory-list','announcement','pair-error']) el(id).replaceChildren();
  el('gate-title').textContent=mode==='pair'?'连接你的 Mac':'暂时连不上 Mac';
  el('gate-description').textContent=mode==='pair'?'输入 Mac 上显示的 8 位网页配对码。':'确认 Mac 已开机、网页版服务正在运行，然后重新连接。';
  if (el('sheet').open) el('sheet').close();
  closeWatch(); syncAvatar();
}
function showWorkspace() {
  state.paired=true;
  el('gate').hidden=true; el('top-install').hidden=true;
  el('open-settings').hidden=false; el('workspace').hidden=false;
  const tab=location.hash.slice(1);
  changeTab(['recordings','memories'].includes(tab)?tab:'chat',false);
}
let statusPending=false;
async function refreshStatus() {
  if (statusPending || document.hidden) return;
  const session=state.session; statusPending=true;
  try {
    const result=await api('/api/status',{requiresPair:false});
    if (session!==state.session) return;
    if (!result.authorized) { showGate('pair'); return; }
    state.status=result; state.statusError='';
    if (!state.paired) showWorkspace();
    displayWatch(); banner();
  } catch(error) {
    if (session!==state.session) return;
    if (error.status===401) {
      if (state.paired || el('pair-form').hidden) showGate('pair');
    } else if (!state.paired) {
      showGate('offline');
    } else {
      state.statusError='与 Mac 的连接已中断，正在等待恢复。'; displayWatch(); banner();
    }
  } finally { statusPending=false; }
}
el('pair-code').addEventListener('input',event=>{
  const input=event.currentTarget;
  input.value=input.value.normalize('NFKC').replace(/\D/g,'').slice(0,8);
});
el('pair-form').addEventListener('submit',async event=>{
  event.preventDefault();
  if (!el('pair-form').reportValidity()) return;
  el('pair-submit').disabled=true; el('pair-error').textContent='';
  try {
    await api('/api/pair',{method:'POST',body:{role:'browser',code:el('pair-code').value.trim()},requiresPair:false});
    el('pair-code').value=''; await refreshStatus();
  } catch(error) {
    el('pair-error').textContent=[400,401,403,404,410].includes(error.status)?'配对码无效或已过期，请在 Mac 上重新获取。':errorLabel(error);
  } finally { el('pair-submit').disabled=false; }
});
el('gate-retry').addEventListener('click',refreshStatus);

function displayWatch() {
  const watch=state.status?.watch;
  const seen=Number(watch?.last_seen)||0;
  const age=Date.now()/1000-seen;
  const stale=Boolean(seen && (age>180 || age< -5 || state.statusError));
  el('watch-button').dataset.state=!seen?'unknown':stale?'stale':watch.recording?'active':'idle';
  const activity=watch?.recording===true?'正在录音':watch?.recording===false?'未在录音':'录音状态未知';
  const description=!seen?'尚未收到手表报告':stale?'上次报告显示手表'+activity:activity;
  el('watch-button').setAttribute('aria-label','手表状态，'+description);
  el('watch-state').textContent=description;
  el('watch-time').textContent=seen?'上次报告　'+stamp(seen,day)+' '+stamp(seen):'请在 Apple Watch 的「更多」中连接 Mac。';
  el('watch-queue').textContent=Number.isInteger(watch?.pending)?'上次报告待确认　'+watch.pending+' 段':'';
}
function closeWatch() { el('watch-pop').hidden=true; el('watch-button').setAttribute('aria-expanded','false'); }
el('watch-button').addEventListener('click',()=>{
  const open=el('watch-pop').hidden;
  el('watch-pop').hidden=!open; el('watch-button').setAttribute('aria-expanded',String(open));
  if (open) { displayWatch(); void refreshStatus(); }
});
el('close-watch').addEventListener('click',()=>{ closeWatch(); el('watch-button').focus(); });
document.addEventListener('click',event=>{if (!event.target.closest('.presence')) closeWatch();});
document.addEventListener('keydown',event=>{
  if (event.key==='Escape' && !el('watch-pop').hidden) { closeWatch(); el('watch-button').focus(); }
});
el('watch-recordings').addEventListener('click',()=>{ closeWatch(); switchRecordings('recordings'); changeTab('recordings'); });
function syncAvatar() {
  if (!state.avatar && state.paired && window.MoMoAvatar) {
    const host=el('avatar');
    host.replaceChildren();
    state.avatar=MoMoAvatar.create(host,{size:'100%'});
    host.querySelector('svg')?.setAttribute('viewBox','-225 -225 450 450');
  }
  if (!state.avatar) return;
  const active=state.paired && state.tab==='chat' && !document.hidden && !reduced.matches;
  state.avatar.setAnimation(state.receipt==='read'?'thinking':el('chat').classList.contains('is-empty')?'home':'listening');
  state.avatar.setActive(active);
  state.avatar.setExpression(state.receipt==='read'?'thinking':'present');
}
const reduced=matchMedia('(prefers-reduced-motion: reduce)');
reduced.addEventListener('change',syncAvatar);
let greetingTimer;
el('greet').addEventListener('click',()=>{
  state.avatar?.setExpression(state.receipt==='read'?'listening':'greeting');
  clearTimeout(greetingTimer); greetingTimer=setTimeout(syncAvatar,800);
});
function changeTab(tab, updateLocation=true) {
  const buttons=[...document.querySelectorAll('.tabs [data-tab]')];
  if (!buttons.some(button=>button.dataset.tab===tab)) return;
  state.tab=tab; closeWatch();
  for (const button of buttons) {
    const selected=button.dataset.tab===tab;
    el(button.dataset.tab).hidden=!selected;
    if (selected) button.setAttribute('aria-current','page'); else button.removeAttribute('aria-current');
  }
  if (updateLocation && location.hash!=='#'+tab) history.replaceState(null,'','#'+tab);
  if (tab==='chat') { renderChat(); void refreshChat(); }
  else { const name=tab==='memories'?tab:state.recordingTab; renderList(name); void loadList(name); }
  syncAvatar();
}
for(const button of document.querySelectorAll('.tabs [data-tab]')) button.addEventListener('click',()=>changeTab(button.dataset.tab));
window.addEventListener('hashchange',()=>{if(state.paired)changeTab(location.hash.slice(1)||'chat',false);});

let chatPending=false;
async function refreshChat() {
  if (!state.paired || state.tab!=='chat' || document.hidden || chatPending) return;
  const generation=state.session; chatPending=true;
  try {
    const snapshot=await api('/api/chat');
    if (generation!==state.session) return;
    const before=state.snapshot;
    if (before && before.conversation_id !== snapshot.conversation_id) {
      state.history.clear(); state.outbox.clear(); state.renderKey=''; state.canLoadHistory=false;
    } else if (state.history.size && before?.messages?.data) {
      for (const message of before.messages.data) state.history.set(message.id,message);
    }
    state.snapshot=snapshot;
    if (!state.history.size) state.canLoadHistory=Boolean(snapshot.messages?.has_more);
    state.chatError='';
    for (const msg of snapshot.messages?.data||[]) if(msg.operation_id) state.outbox.delete(msg.operation_id);
    renderChat(); banner();
  } catch(error) {
    if (generation===state.session) { state.chatError=errorLabel(error); renderChat(); banner(); }
  } finally { chatPending=false; }
}
el('retry-chat').addEventListener('click',()=>void refreshChat());
const readStates=new Set(['running','waiting_for_approval','waiting_for_input','waiting_for_computer','stopping','completed']);
function receiptFor(message,runs) {
  if (!message || message.role!=='user') return '';
  const run=runs.find(r=>(message.run_id && r.run_id===message.run_id) || (message.operation_id && r.operation_id===message.operation_id));
  const delivery=state.snapshot?.message_states?.[message.id] || message.delivery_state;
  if ([delivery,run?.delivery_state,run?.status].includes('not_applied')) return '';
  if (delivery==='applied' || run?.delivery_state==='applied') return 'read';
  if (message.local && !message.accepted) return '';
  if ([delivery,run?.delivery_state].some(v=>v==='pending'||v==='steering')) return 'delivered';
  if (run?.execution_generation!=null || readStates.has(run?.status)) return 'read';
  return 'delivered';
}
function runText(row) {
  const attachments=(row.attachments||[]).map(a=>a.name).filter(Boolean);
  return [row.content,...attachments].filter(Boolean).join('\n');
}
function renderChat() {
  if (!state.paired) return;
  const byID=new Map(state.history);
  for (const msg of state.snapshot?.messages?.data||[]) byID.set(msg.id,msg);
  const rows=[...byID.values()].filter(m=>['assistant','user'].includes(m.role) && runText(m)).sort((a,b)=>a.seq-b.seq);
  for (const item of state.outbox.values()) {
    if (!rows.some(row=>row.operation_id===item.operation_id)) rows.push(item);
  }
  const runs=state.snapshot?.runs||[];
  const last=rows.at(-1);
  const receipt=receiptFor(last,runs);
  const blocked=runs.some(r=>r.run_id===last?.run_id && ['cancelled','failed','not_applied','stopped'].includes(r.status));
  const wait=receipt==='read' && !blocked;
  const restoring=!state.snapshot && !rows.length;
  el('chat-skeleton').hidden=!restoring || Boolean(state.chatError);
  el('retry-chat').hidden=!restoring || !state.chatError;
  const empty=!restoring && !rows.length;
  const previousEmpty=el('chat').classList.contains('is-empty');
  el('chat').classList.toggle('is-empty',empty);
  if (state.snapshot && !el('chat').classList.contains('has-placement')) {
    requestAnimationFrame(()=>requestAnimationFrame(()=>{ if (state.snapshot) el('chat').classList.add('has-placement'); }));
  }
  const key=JSON.stringify([state.canLoadHistory,rows.map(r=>[r.id,r.role,r.content,r.attachments?.map(a=>a.name),r.failed])]);
  if (state.renderKey===key && previousEmpty===empty) {
    renderReceipt(last,receipt,wait);
    return;
  }
  const scroller=el('chat-scroll');
  const pin=scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop < 70;
  const first=!state.renderKey;
  state.renderKey=key;
  el('older').hidden=!state.canLoadHistory;
  const stream=document.createDocumentFragment();
  for (const row of rows) {
    const block=element('article','message '+row.role);
    block.setAttribute('aria-label',row.role==='user'?'你':'MoMo');
    const bubble=element('div','bubble');
    if (row.role==='assistant') { bubble.classList.add('prose'); markdown(bubble,runText(row)); }
    else bubble.textContent=runText(row);
    block.append(bubble);
    if (row.failed) {
      const retry=action('',()=>void deliver(row),'receipt-button');
      retry.setAttribute('aria-label','重试发送这条消息'); retry.title='重试发送'; retry.append(icon('retry')); block.append(retry);
    }
    stream.append(block);
  }
  el('messages').replaceChildren(stream);
  renderReceipt(last,receipt,wait);
  if (first || pin || last?.local) requestAnimationFrame(()=>{scroller.scrollTop=scroller.scrollHeight;});
  syncAvatar();
}
function renderReceipt(last,receipt,wait) {
  const messages=el('messages');
  const latest=messages.querySelector('.message:last-of-type');
  let label=latest?.querySelector('.receipt');
  if (latest && receipt && !last?.failed) {
    const value=receipt==='read'?'已读':'已送达';
    if (!label) { label=element('small','receipt'); label.setAttribute('role','status'); latest.append(label); }
    if (label.textContent!==value) label.textContent=value;
  } else { label?.remove(); }
  const existing=messages.querySelector('.dots');
  if (wait && !existing) {
    const dots=element('span','dots'); dots.setAttribute('aria-label','MoMo 正在处理');
    dots.append(element('i'),element('i'),element('i')); messages.append(dots);
  } else if (!wait) existing?.remove();
  const next=wait?'read':'';
  if (state.receipt!==next) { state.receipt=next; syncAvatar(); }
}
el('older').addEventListener('click',async()=>{
  if (el('older').disabled || !state.paired) return;
  const existing=[...state.history.values(),...(state.snapshot?.messages?.data||[])];
  const before=Math.min(...existing.map(row=>Number(row.seq)).filter(Number.isFinite));
  if (!Number.isFinite(before)) return;
  const generation=state.session, conversation=state.snapshot?.conversation_id; el('older').disabled=true;
  try {
    const page=await api('/api/chat/history?before='+before+'&limit=50');
    if (generation!==state.session || conversation!==state.snapshot?.conversation_id) return;
    const scroller=el('chat-scroll'),oldHeight=scroller.scrollHeight,oldPosition=scroller.scrollTop;
    for(const msg of page.data||[]) state.history.set(msg.id,msg);
    state.canLoadHistory=Boolean(page.has_more);
    renderChat();
    scroller.scrollTop=oldPosition+(scroller.scrollHeight-oldHeight);
  } catch(error) {
    if(generation===state.session){state.chatError=errorLabel(error); banner();}
  } finally { el('older').disabled=false; }
});
function resizeDraft() {
  const draft=el('draft'); draft.style.height=''; draft.style.height=Math.min(108,draft.scrollHeight)+'px';
  el('send').disabled=!draft.value.trim();
}
el('draft').addEventListener('input',resizeDraft);
el('draft').addEventListener('keydown',event=>{
  if (event.key==='Enter' && (event.metaKey||event.ctrlKey) && !event.isComposing) {
    event.preventDefault(); el('composer').requestSubmit();
  }
});
el('composer').addEventListener('submit',event=>{
  event.preventDefault();
  const content=el('draft').value.trim();
  if (!content || !state.paired) return;
  if (new TextEncoder().encode(content).length>16384) { state.chatError='消息太长，请分开发送。'; banner(); return; }
  const id=uuid();
  const row={id:'user-'+id,operation_id:id,role:'user',content,local:true};
  state.outbox.set(id,row); el('draft').value=''; resizeDraft(); void deliver(row);
});
async function deliver(row) {
  if (row.sending || !state.paired) return;
  const generation=state.session;
  row.sending=true; row.failed=false; state.chatError=''; renderChat(); banner();
  try {
    const result=await api('/api/chat',{method:'POST',body:{content:row.content,operation_id:row.operation_id}});
    if (generation!==state.session) return;
    row.accepted=true; row.run_id=result.run_id;
    el('announcement').textContent='消息已送达';
    void refreshChat();
  } catch(error) {
    if (generation===state.session) { row.failed=true; state.chatError=errorLabel(error); banner(); }
  } finally { row.sending=false; if(generation===state.session)renderChat(); }
}

const listPaths={recordings:'/api/recordings',sources:'/api/sources',memories:'/api/memories'};
const audioState={queued:'等待转写',processing:'正在转写',ready:'转写完成',failed:'转写失败'};
const kinds={memory:'共享记忆',user:'关于你',briefing:'简报',person:'人物',project:'项目',journal:'日志',topic:'主题',note:'笔记'};
function listState(name) {
  return state.lists[name] ||= {items:new Map(),cursor:null,loaded:false,loading:false,error:''};
}
function switchRecordings(name) {
  state.recordingTab=name;
  el('show-recordings').setAttribute('aria-pressed',String(name==='recordings'));
  el('show-sources').setAttribute('aria-pressed',String(name==='sources'));
  if (state.paired && state.tab==='recordings') { renderList(name); void loadList(name); }
}
el('show-recordings').addEventListener('click',()=>switchRecordings('recordings'));
el('show-sources').addEventListener('click',()=>switchRecordings('sources'));
el('record-more').addEventListener('click',()=>void loadList(state.recordingTab,true));
el('memory-more').addEventListener('click',()=>void loadList('memories',true));
function isVisibleList(name) {
  return state.paired && (name==='memories'?state.tab==='memories':state.tab==='recordings' && state.recordingTab===name);
}
async function loadList(name,more=false) {
  if (!state.paired) return;
  const list=listState(name);
  if (list.loading || (more&&!list.cursor)) return;
  const generation=state.session;
  list.loading=true; list.error=''; renderList(name);
  const url=new URL(listPaths[name],location.origin);
  if (more) url.searchParams.set(name==='recordings'?'before':'after',list.cursor);
  try {
    let page=await api(url);
    if (generation!==state.session) return;
    const changed=list.loaded && page.revision!=null && page.revision!==list.revision;
    if (changed) {
      list.hasOlder=false;
      if (more) {
        page=await api(listPaths[name]);
        if (generation!==state.session) return;
        more=false;
      }
    }
    list.revision=page.revision;
    const retainedPages=Boolean(list.hasOlder);
    if (!more && !retainedPages) list.items.clear();
    for(const item of page.items??[]) list.items.set(item.id,item);
    if (more || !retainedPages) list.cursor=page.next_cursor;
    if (more) list.hasOlder=true;
    list.loaded=true;
  } catch(error) {
    if (generation===state.session) list.error=errorLabel(error);
  } finally {
    if (generation===state.session) { list.loading=false; renderList(name); }
  }
}
function compact(text,limit=95) {
  const value=String(text??'').trim().replace(/\s+/g,' ');
  return value.length<=limit?value:value.slice(0,limit)+'…';
}
function rowButton(symbol,title,metadata,click,preview='') {
  const row=element('article','row');
  const button=action('',click,'row-button');
  const glyph=element('span','row-icon'); glyph.append(icon(symbol));
  const body=element('span','row-body');
  body.append(element('span','row-name',title));
  if (metadata) body.append(element('span','row-meta',metadata));
  if (preview) body.append(element('span','row-preview',preview));
  button.append(glyph,body,icon('next','chevron')); row.append(button);
  return row;
}
function memoryName(item) {
  const content=String(item.text??item.content??'');
  const heading=/^#\s+(.+)$/m.exec(content)?.[1];
  const path=String(item.path||'').split('/').pop()?.replace(/\.md$/i,'');
  return item.title || heading || path || compact(content,54) || kinds[item.kind] || '记忆';
}
function renderList(name) {
  if (!isVisibleList(name)) return;
  const mem=name==='memories';
  const target=el(mem?'memory-list':'record-list');
  const more=el(mem?'memory-more':'record-more');
  const meta=el(mem?'mem-status':'rec-status');
  const list=listState(name);
  const items=[...list.items.values()];
  more.hidden=!list.cursor; more.disabled=list.loading;
  meta.textContent=list.loading?'读取中…':'';
  if (!items.length) {
    if (list.error) emptyState(target,'retry','暂时无法读取',list.error,()=>void loadList(name));
    else if (!list.loaded || list.loading) target.replaceChildren();
    else if (mem) emptyState(target,'book','还没有记忆','Mac 整理出的笔记会显示在这里。');
    else if(name==='sources') emptyState(target,'file','Mac 上还没有历史转录','此前同步到 Mac 的文字记录会显示在这里。');
    else emptyState(target,'wave','还没有手表录音','Apple Watch 连接 Mac 并上传录音后，就可以在这里回听。');
    return;
  }
  const fragment=document.createDocumentFragment();
  if (list.error) {
    const error=paragraph(list.error,'form-error'); error.append(action('重试',()=>void loadList(name),'text-button'));
    fragment.append(error);
  }
  if (mem) {
    for(const item of items) {
      fragment.append(rowButton('book',memoryName(item),kinds[item.kind] || item.kind || '笔记',()=>openMemory(item)));
    }
  } else {
    let lastDate='';
    for (const item of items.sort((a,b)=>(Number(b.recorded_at)||0)-(Number(a.recorded_at)||0))) {
      const key=stamp(item.recorded_at,day)||'日期待确认';
      if (key!==lastDate) { fragment.append(element('h2','day-title',key)); lastDate=key; }
      const when=stamp(item.recorded_at);
      if (name==='sources') {
        const title=typeof item.summary==='string' && item.summary.trim()?compact(item.summary,38):'转录';
        fragment.append(rowButton('file',title,when || '已同步',()=>openSource(item),compact(item.preview)));
      } else {
        const status=audioState[item.state]||'已接收';
        fragment.append(rowButton('wave',(when?when+' · ':'')+'手表录音',interval(item.duration)+'　'+status,
          ()=>openRecording(item),compact(item.transcript)));
      }
    }
  }
  target.replaceChildren(fragment);
  const detail=state.recordDetail;
  if (detail && !mem && name==='recordings') {
    const record=list.items.get(detail.id);
    if (record) updateRecordingText(record);
  }
}

function sheet(title) {
  state.detailID++; state.recordDetail=null;
  const body=el('sheet-body');
  body.querySelector('audio')?.pause(); body.replaceChildren();
  el('sheet-title').textContent=title;
  const dialog=el('sheet');
  if (!dialog.open) dialog.showModal();
  dialog.scrollTop=0;
  return body;
}
el('sheet-close').addEventListener('click',()=>el('sheet').close());
el('sheet').addEventListener('click',event=>{
  if(event.target!==el('sheet'))return;
  const box=el('sheet').getBoundingClientRect();
  if (event.clientX<box.left || event.clientX>box.right || event.clientY<box.top || event.clientY>box.bottom) el('sheet').close();
});
el('sheet').addEventListener('close',()=>{
  state.detailID++; state.recordDetail=null;
  const body=el('sheet-body'); body.querySelector('audio')?.pause(); body.replaceChildren();
});
function discuss(text) {
  el('sheet').close(); changeTab('chat');
  const draft=el('draft');
  draft.value=draft.value.trim()?draft.value+'\n'+text:text;
  resizeDraft(); draft.focus();
}
function clipQuestion(text) {
  return '关于这段记录：“'+compact(text,650)+'”\n';
}
function updateRecordingText(item) {
  const detail=state.recordDetail;
  if (!detail || detail.id!==item.id) return;
  detail.info.textContent=interval(item.duration)+'　'+(audioState[item.state]||'已接收');
  const noText={failed:'Mac 暂时未能转写，可以先听原音。',ready:'这段录音没有可显示的文字。',processing:'Mac 正在转写这段原音。',queued:'这段原音已保存在 Mac，正在等待转写。'};
  detail.text.textContent=item.transcript || noText[item.state] || '尚无转录文字。';
  detail.ask.hidden=!item.transcript;
  detail.ask.onclick=()=>discuss(clipQuestion(item.transcript));
}
function openRecording(item) {
  const body=sheet((stamp(item.recorded_at,day)+' '+stamp(item.recorded_at)).trim() || '手表录音');
  const info=paragraph('','sheet-note'), copy=paragraph('','plain-record');
  body.append(info);
  if (item.audio_url) {
    let url;
    try { url=new URL(item.audio_url,location.origin); } catch { url=null; }
    if (url?.origin===location.origin && /^https?:$/.test(url.protocol)) {
      const audio=element('audio'); audio.controls=true; audio.preload='none'; audio.src=url.href; audio.setAttribute('aria-label','手表原音');
      const error=paragraph('','form-error');
      audio.addEventListener('error',()=>{error.textContent='原音暂时无法播放，请确认连接后重试。';});
      body.append(audio,error);
    }
  }
  const ask=action('带着这段转录聊天',()=>{},'text-button');
  body.append(copy,ask); state.recordDetail={id:item.id,info,text:copy,ask}; updateRecordingText(item);
}
function openMemory(item) {
  const body=sheet(memoryName(item));
  body.append(paragraph(item.path || kinds[item.kind] || item.kind || '记忆','sheet-note'));
  const prose=element('div','prose');
  const text=item.text ?? item.content ?? '';
  markdown(prose,text); body.append(prose);
  if(text)body.append(action('带着这条记忆聊天',()=>discuss(clipQuestion(text)),'text-button'));
}
function openSource(item) {
  const body=sheet('Mac 已有转录'), detail=state.detailID;
  const text=paragraph('','plain-record'),note=paragraph('读取中…','sheet-note');
  const contents=[];
  let next=0;
  const more=action('继续阅读',()=>void load(),'outline mini'); more.hidden=true;
  const ask=action('带着这段转录聊天',()=>discuss(clipQuestion(contents.join(''))),'text-button'); ask.hidden=true;
  body.append(paragraph([stamp(item.recorded_at,day),stamp(item.recorded_at)].filter(Boolean).join(' '),'sheet-note'),text,note,more,ask);
  async function load() {
    more.disabled=true;
    const query=new URLSearchParams({source_id:item.id,revision:item.revision,offset:String(next)});
    try {
      const result=await api('/api/source?'+query);
      if(detail!==state.detailID)return;
      contents.push(result.text||''); text.textContent=contents.join('');
      next=result.next_offset;
      more.textContent='继续阅读'; more.hidden=next==null;
      ask.hidden=!text.textContent; note.textContent=text.textContent?'':'暂时没有转录文字。';
    } catch(error) {
      if(detail!==state.detailID)return;
      more.textContent='重试'; more.hidden=false; note.textContent=errorLabel(error);
    } finally { more.disabled=false; }
  }
  void load();
}
el('open-settings').addEventListener('click',()=>{
  const body=sheet('连接设置');
  const host=element('div','settings-row');
  host.append(element('span','','Mac 服务'),element('strong','',location.host));
  const agent=element('div','settings-row');
  agent.append(element('span','','Agent'),element('strong','',state.statusError?'连接中断':state.status?.mac?.online?'已就绪':'暂未就绪'));
  body.append(host,agent);
  if (typeof state.status?.asr==='boolean') {
    const asr=element('div','settings-row');
    asr.append(element('span','','Mac 本地转写'),element('strong','',state.status.asr?'已就绪':'等待配置'));
    body.append(asr);
  }
  if (!navigator.standalone && !matchMedia('(display-mode: standalone)').matches) {
    const link=element('a','outline','添加到主屏幕'); link.href='/install'; body.append(link);
  }
  const error=paragraph('','form-error');
  const logout=action('断开此浏览器',async()=>{
    logout.disabled=true;
    try { await api('/api/logout',{method:'POST',body:{}}); showGate('pair'); }
    catch(e){ if(state.paired)error.textContent=errorLabel(e); }
    finally{logout.disabled=false;}
  });
  body.append(logout,error);
});
document.addEventListener('visibilitychange',()=>{
  syncAvatar();
  if (document.hidden) return;
  void refreshStatus();
  if(state.tab==='chat') void refreshChat();
  else if(state.paired) void loadList(state.tab==='memories'?'memories':state.recordingTab);
});
window.addEventListener('online',()=>{ void refreshStatus(); void refreshChat(); });
window.addEventListener('offline',()=>{
  if (state.paired) { state.statusError='网络已断开。'; displayWatch(); banner(); }
});
window.addEventListener('pageshow',event=>{
  if(event.persisted) {
    // Safari may preserve a previous authenticated DOM in its back-forward cache.
    showGate('offline'); void refreshStatus();
  }
});
setInterval(()=>{ void refreshStatus(); },12000);
setInterval(()=>{ if(!document.hidden && state.paired && state.tab==='chat') void refreshChat(); },3000);
setInterval(()=>{ if(!document.hidden && state.paired && state.tab==='recordings' && state.recordingTab==='recordings') void loadList('recordings'); },15000);
if ('serviceWorker' in navigator && window.isSecureContext) navigator.serviceWorker.register('/sw.js').catch(()=>{});
void refreshStatus();
