const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const web = path.join(__dirname,'../../Apps/iPhoneApp/Features/Assistant/Rendering/Web');
const context = vm.createContext({ Intl, console });
for (const file of ['vendor/marked.js','vendor/remend.js','chat-core.js']) {
  vm.runInContext(fs.readFileSync(path.join(web,file),'utf8'),context,{ filename:file });
}
const core = context.MoMoChatCore;
core.installRecordingSourceLinks(context.marked);
let passed = 0;
function test(name, block) { block(); passed++; console.log('PASS',name); }

const sourceURL = 'momoagent://source/d64b7800-be32-49ed-b6f1-7530ebf8c1be/6b1b8ca7-8855-3eb4-756b-05400adf5599?version=78&generation=0';
test('bare recording citations render as compact links with exact version and punctuation',() => {
  const html = context.marked.parse(`原文。来源：${sourceURL}。\n\n(${sourceURL}), 下一段。`);
  assert.equal((html.match(/class="recording-source"/g) || []).length,2);
  assert.equal((html.match(/查看录音/g) || []).length,2);
  assert.ok(html.includes('version=78&amp;generation=0'));
  assert.ok(html.includes('</a>。') && html.includes('</a>), 下一段。'));
});
test('Markdown citation labels and literal code keep their meaning',() => {
  const html = context.marked.parse(`[14:24 的讨论](${sourceURL})\n\n\`${sourceURL}\`\n\n\`\`\`text\n${sourceURL}\n\`\`\``);
  assert.equal((html.match(/<a /g) || []).length,1);
  assert.ok(html.includes('>14:24 的讨论</a>'));
  assert.equal((html.match(/<code/g) || []).length,2);
  assert.ok(!html.includes('查看录音'));
});
test('malformed, incomplete and out-of-range citations never become source links',() => {
  for (const invalid of [sourceURL+'#fragment',sourceURL+'&extra=1',sourceURL+'/extra',
    sourceURL.replace('version=78','version=078'),sourceURL.replace('version=78','version=0'),
    sourceURL.replace('generation=0','generation=-1'),sourceURL.replace('version=78','version=9223372036854775808'),
    sourceURL.replace('d64b7800','notauuid'),sourceURL.slice(0,-1)]) {
    assert.equal(core.isRecordingSourceURL(invalid),false,invalid);
    assert.ok(!context.marked.parse(invalid).includes('class="recording-source"'),invalid);
  }
  assert.equal(core.isRecordingSourceURL(sourceURL.replace('version=78&generation=0','generation=0&version=78')),true);
});
test('streaming source URLs settle into a link and preserve preceding chunks',() => {
  const document = new core.MarkdownStream(context.marked);
  const first = document.update('前文保留。\n\n来源：',true)[0];
  for (let i=1;i<=sourceURL.length;i++) document.update('前文保留。\n\n来源：'+sourceURL.slice(0,i),true);
  const final = document.update('前文保留。\n\n来源：'+sourceURL,false);
  assert.equal(first.id,final[0].id);
  assert.equal(first.html,final[0].html);
  assert.equal((final.map(c=>c.html).join('').match(/查看录音/g)||[]).length,1);
});

test('grapheme-safe catchup preserves emoji, combining marks and CJK',() => {
  const target = '你好👨‍👩‍👧‍👦e\u0301🇨🇳'.repeat(300);
  let shown = '', rounds = 0;
  const boundaries = new Set([0]); let offset = 0;
  core.graphemes(target).forEach(value => { offset += value.length; boundaries.add(offset); });
  while (shown !== target) {
    const next = core.advance(shown,target);
    assert.equal(next.delay,0);
    assert.ok(boundaries.has(next.text.length));
    assert.ok(next.text.length > shown.length);
    shown = next.text; assert.ok(++rounds < 150);
  }
});
test('new tail never splits a grapheme extended by a later network chunk',() => {
  for (const [previous,next,prefix] of [['e','e\u0301',''],['👨','👨‍👩‍👧‍👦',''],['好👍','好👍🏽','好']]) {
    assert.equal(core.stablePrefix(previous,next),prefix);
    assert.equal(core.advance(previous,next).text,next);
  }
});
test('unfinished Markdown remains literal until the closing delimiter arrives',() => {
  const document = new core.MarkdownStream(context.marked);
  const partial = document.update('确认 **时间',true).map(x=>x.html).join('');
  assert.ok(!partial.includes('<strong>') && partial.includes('**时间'));
  const fence = new core.MarkdownStream(context.marked).update('```swift\nlet value = 1',true).map(x=>x.html).join('');
  assert.ok(!fence.includes('<pre>') && fence.includes('```swift'));
  assert.ok(document.update('确认 **时间**',true).map(x=>x.html).join('').includes('<strong>时间</strong>'));
});
test('content correction replaces the displayed prefix',() => {
  assert.equal(core.advance('旧内容','修订后的内容').text,'修订后的内容');
});
test('scroll intent unpins upward, repins only at the bottom',() => {
  const pin = new core.PinState();
  pin.observe(900,100,1000); assert.equal(pin.pinned,true);
  pin.observe(400,100,1000); assert.equal(pin.pinned,false);
  pin.observe(410,100,1000); assert.equal(pin.pinned,false);
  pin.observe(894,100,1000); assert.equal(pin.pinned,true);
  pin.observe(894,100,1500); assert.equal(pin.pinned,true,'Content growth is not an upward gesture');
  pin.observe(880,100,980); assert.equal(pin.pinned,true,'A layout clamp at the new bottom keeps following');
});
test('a delayed native offset followed by the actual bottom restores following',() => {
  const pin = new core.PinState();
  pin.observe(1825,740,2565);
  pin.observe(0,740,2565); assert.equal(pin.pinned,false);
  pin.observe(500,740,2565); assert.equal(pin.pinned,false,'Returning only partway down is still reading');
  pin.observe(1825,740,2565); assert.equal(pin.pinned,true);
  pin.observe(500,740,2565); assert.equal(pin.pinned,false,'A subsequent upward reading move still wins');
});
test('tool-only rounds become one assistant turn in source order',() => {
  const messages = [
    {id:'u',turnID:'u',role:'user',state:'complete',blocks:[{id:'ut',type:'text',text:'**literal**'}]},
    {id:'a1',turnID:'u',role:'assistant',state:'complete',blocks:[{id:'c',type:'tool',tool:{id:'c',name:'read_transcript',state:'succeeded'}}]},
    {id:'a2',turnID:'u',role:'assistant',state:'streaming',blocks:[{id:'t',type:'text',text:'回复'}]}
  ];
  const turns = core.turns(messages);
  assert.equal(turns.length,2); assert.equal(turns[0].text,'**literal**');
  assert.equal(turns[1].parts[0].type,'process');
  assert.equal(turns[1].parts[1].streaming,true);
  messages[2].state = 'complete';
  assert.equal(core.turns(messages)[1].id,turns[1].id);
});
test('summary distinguishes successful, failed and interrupted calls',() => {
  const steps = ['succeeded','failed','interrupted'].map(state => ({ type:'tool',tool:{state,name:'read_transcript'} }));
  assert.equal(core.processSummary(steps,false),'已完成 1 项操作 · 1 项失败 · 1 项已中断');
  assert.equal(core.processSummary([{type:'tool',tool:{state:'running',name:'read_transcript'}}],false),'1 项未确认完成');
});
test('memory tool presentation distinguishes reading from a confirmed update',() => {
  assert.equal(core.toolLabel({name:'memory',input:'{"action":"read"}',state:'running'}),'查看记忆');
  assert.equal(core.toolLabel({name:'memory',input:'{"action":"read"}',state:'succeeded'}),'已查看记忆');
  assert.equal(core.toolLabel({name:'memory',input:'{"action":"add"}',state:'running'}),'更新记忆');
  assert.equal(core.toolLabel({name:'memory',input:'{"operations":[{"action":"remove","old_text":"旧值"}]}',state:'succeeded'}),'已更新记忆');
});
test('reply completion distinguishes model round boundaries from the final answer',() => {
  const reply = (state,parts) => ({state,parts});
  const tools = [{type:'process',steps:[]}], text = [...tools,{type:'text',text:'回答完成。'}];
  assert.equal(core.replyFinished(reply('complete',tools),true),false);
  assert.equal(core.replyFinished(reply('streaming',text),true),false);
  assert.equal(core.replyFinished(reply('complete',text),true),true);
  assert.equal(core.replyFinished(reply('complete',tools),false),true);
  for (const state of ['failed','stopped','truncated'])
    assert.equal(core.replyFinished(reply(state,tools),true),true);
});
test('adjacent text blocks preserve exact text and one stable prose identity',() => {
  const turns = core.turns([{ id:'a',turnID:'u',role:'assistant',state:'streaming',blocks:[
    {id:'first',type:'text',text:'你好'}, {id:'space',type:'text',text:' '}, {id:'second',type:'text',text:'世界。'}
  ] }]);
  assert.equal(turns[0].text,'你好 世界。');
  assert.equal(turns[0].parts.length,1);
  assert.equal(turns[0].parts[0].id,'first');
  assert.equal(turns[0].parts[0].streaming,true);
});
test('stable Markdown chunks are reused as the tail grows',() => {
  const document = new core.MarkdownStream(context.marked);
  const first = document.update('第一段。\n\n第二段',true);
  const second = document.update('第一段。\n\n第二段越来越长。\n\n- 列表',true);
  assert.equal(first[0],second[0]);
  const final = document.update('第一段。\n\n第二段越来越长。\n\n- 列表',false);
  assert.ok(final.map(chunk=>chunk.html).join('').includes('<li>列表</li>'));
});
test('open fences, tables, reference links and incomplete links settle correctly',() => {
  for (const source of ['```swift\nlet x = 1','| a | b |\n| --- | --- |\n| x | y |',
    '[来源](momoagent://source/unfinished','确认 **时间']) {
    const document = new core.MarkdownStream(context.marked);
    for (let i=1;i<=source.length;i++) document.update(source.slice(0,i),true);
    assert.ok(document.update(source,false).length > 0);
  }
  const reference = '[资料][id]\n\n[id]: https://example.com';
  const document = new core.MarkdownStream(context.marked);
  document.update('[资料][id]\n\n',true);
  assert.ok(document.update(reference,false).map(x=>x.html).join('').includes('href="https://example.com"'));
});
test('stopped rendering flushes exact received content and can restart',() => {
  const document = new core.MarkdownStream(context.marked);
  document.update('原文\n\n**正在',true);
  const stopped = document.update('原文\n\n**正在',false);
  assert.ok(stopped.map(x=>x.html).join('').includes('正在'));
  assert.equal(document.update('另一个会话',false).length,1);
});
test('system receipt state controls the visible outcome even when tool transport succeeded',() => {
  const actionID = '4BC82BC1-9EF7-4AF4-BEAE-44BF62F24731';
  const tool = state => ({name:'create_calendar_event',input:'{}',state:'succeeded',output:JSON.stringify({actionID,state})});
  assert.equal(core.toolLabel(tool('outcome_unknown')),'结果待核对');
  assert.equal(core.processSummary([{type:'tool',tool:tool('outcome_unknown')}],false),'1 项结果待核对');
  assert.equal(core.processSummary([{type:'tool',tool:tool('conflict')}],false),'1 项系统内容已变化');
  assert.equal(core.processSummary([{type:'tool',tool:tool('succeeded')}],false),'已完成 1 项操作');
  assert.equal(core.actionReceipt({...tool('succeeded'),name:'search_transcripts'}),null,'Only native write results can become action cards');
  assert.equal(core.actionReceipt({...tool('succeeded'),output:'{"actionID":"invalid","state":"succeeded"}'}),null);
});
test('response activity follows the current reply through waiting, reasoning, tool execution and writing',() => {
  const user = {id:'u',role:'user',parts:[]};
  const reply = (parts,state='streaming') => ({id:'a',role:'assistant',state,parts});
  const thinking = {type:'process',steps:[{id:'r',type:'reasoning',text:'核对资料'}]};
  const call = state => ({type:'process',steps:[{type:'tool',tool:{name:'read_transcript',state}}]});
  assert.equal(core.responseActivity([user],true),'waiting');
  assert.equal(core.responseActivity([user,reply([thinking])],true),'thinking');
  assert.equal(core.responseActivity([user,reply([thinking,call('running')])],true),'tool');
  assert.equal(core.responseActivity([user,reply([call('succeeded')],'complete')],true),'waiting');
  assert.equal(core.responseActivity([user,reply([{type:'text',text:'开始回答',streaming:true}])],true),'writing');
  assert.equal(core.responseActivity([user,reply([{type:'text',text:'完整回答',streaming:false}],'complete')],true),'idle');
  assert.equal(core.responseActivity([user],false),'idle');
  assert.equal(core.responseActivity([user,reply([],'failed')],true),'idle');
});
test('compaction has its own real phases and gives way to resumed streaming',() => {
  const user = {id:'u',role:'user',parts:[]};
  const reply = {id:'a',role:'assistant',state:'streaming',parts:[{type:'text',text:'The full reply',streaming:true}]};
  assert.equal(core.responseActivity([user],true,'compacting'),'compacting');
  assert.equal(core.responseActivity([user,reply],true,'compacting'),'compacting');
  assert.equal(core.responseActivity([user],true,'compacted'),'compacted');
  assert.equal(core.responseActivity([user,reply],true,'compacted'),'writing');
  assert.equal(core.responseActivity([user],false,'compacting'),'idle');
  assert.equal(core.responseActivity([user],false,'failed'),'contextFailed');
  assert.equal(core.responseActivity([user],true,'idle'),'waiting');
  assert(core.contextActivityLabel('compacting').includes('整理较早的对话'));
  assert(core.contextActivityLabel('compacted').includes('继续回复'));
  assert(core.contextActivityLabel('contextFailed').includes('聊天记录已保留'));
  assert.equal(core.contextActivityLabel('writing'),null);
});
test('an old tool cannot keep a completed new reply busy',() => {
  const old = {id:'old',role:'assistant',parts:[{type:'process',steps:[{type:'tool',tool:{state:'running'}}]}]};
  const current = {id:'new',role:'assistant',state:'complete',parts:[{type:'text',text:'新回答',streaming:false}]};
  assert.equal(core.responseActivity([old,{role:'user',id:'u',parts:[]},current],true),'idle');
});
test('tool result presentation preserves exact passages and page boundaries',() => {
  const output = JSON.stringify({passages:[{text:'原文第一段。'},{text:'原文第二段。'}],hasMore:true});
  const outcome = core.toolOutcome({name:'read_transcript',output});
  assert.equal(outcome.summary,'本次返回 2 段原文');
  assert.equal(outcome.text,'原文第一段。\n\n原文第二段。');
  assert.equal(outcome.more,true);
  assert.equal(core.toolOutcome({name:'read_transcript',output:'未返回 JSON'}),null);
  assert.equal(core.toolOutcome({name:'read_transcript',output:'null'}),null);
  assert.equal(core.toolOutcome({name:'read_transcript',output:'{"passages":[null]}'}),null);
  assert.equal(core.toolOutcome({name:'search_transcripts',output:'{"passages":[]}'}).summary,'本次没有找到相关原文');
});
test('failed run notices remain system rows beside later successful replies', () => {
  const message = (id, turnID, role, text) => ({id, turnID, role, state:'complete', blocks:[{id:id + ':text',type:'text',text}]});
  const earlier = [message('user-1','run-1','user','First request'), message('ack-1','run-1','assistant','Working on it'),
    message('run-status-run-1','run-1','system','Request failed')];
  const first = core.turns(earlier);
  const later = core.turns([...earlier, message('user-2','run-2','user','Another request'), message('answer-2','run-2','assistant','Done')]);
  assert.equal(first[2].role,'system'); assert.equal(first[2].id,'run-status-run-1');
  assert.equal(later[2].id,first[2].id); assert.equal(later[2].text,'Request failed');
  assert.equal(later[1].text,'Working on it'); assert.equal(later[4].text,'Done');
});
test('interleaved replies from one task keep separate stable rows and exact read IDs', () => {
  const message = (id, run, role) => ({id,turnID:run,role,state:'complete',blocks:[{id:id+':text',type:'text',text:id}]});
  const history = [message('u1','run1','user'),message('ack1','run1','assistant'),
    message('u2','run2','user'),message('ack2','run2','assistant'),
    message('final1','run1','assistant'),message('more1','run1','assistant'),message('final2','run2','assistant')];
  const rows = core.turns(history);
  assert.equal(rows.length,6);
  assert.equal(new Set(rows.map(row=>row.id)).size,rows.length);
  assert.deepEqual(Array.from(rows[1].messageIDs),['ack1']);
  assert.deepEqual(Array.from(rows[4].messageIDs),['final1','more1']);
  assert.notEqual(rows[1].id,rows[4].id);
  assert.deepEqual(core.turns(history.concat(message('u3','run3','user'))).slice(0,6).map(row=>row.id),rows.map(row=>row.id));
});
test('Dots timestamp markers group within 30 minutes, split across calendar days, and ignore system rows', () => {
  const day1Late = new Date(2026, 10, 2, 23, 50, 0).getTime();
  const day1Soon = new Date(2026, 10, 2, 23, 58, 0).getTime();
  const day2Early = new Date(2026, 10, 3, 0, 5, 0).getTime();
  const day2Under30 = new Date(2026, 10, 3, 0, 34, 59).getTime();
  const day2At30 = new Date(2026, 10, 3, 0, 35, 0).getTime();
  assert.equal(core.shouldShowTimestampMarker(null, day1Late), true);
  assert.equal(core.shouldShowTimestampMarker(day1Late, day1Soon), false);
  assert.equal(core.shouldShowTimestampMarker(day1Late, day2Early), true, 'Cross-midnight within 30m still emits a date divider');
  assert.equal(core.shouldShowTimestampMarker(day2Early, day2Under30), false);
  assert.equal(core.shouldShowTimestampMarker(day2Early, day2At30), true);
  assert.equal(core.shouldShowTimestampMarker(day2Early, null), false);

  const now = new Date(2026, 10, 3, 15, 30, 0).getTime();
  const todayLabel = core.formatTimestampMarker(new Date(2026, 10, 3, 14, 5, 0).getTime(), now);
  const yesterdayLabel = core.formatTimestampMarker(new Date(2026, 10, 2, 9, 20, 0).getTime(), now);
  const sameYearLabel = core.formatTimestampMarker(new Date(2026, 9, 15, 11, 45, 0).getTime(), now);
  const priorYearLabel = core.formatTimestampMarker(new Date(2025, 4, 8, 16, 10, 0).getTime(), now);
  assert.ok(todayLabel.startsWith('今天 ') && todayLabel.includes('05'), todayLabel);
  assert.ok(yesterdayLabel.startsWith('昨天 ') && yesterdayLabel.includes('20'), yesterdayLabel);
  assert.ok(!sameYearLabel.includes('2026') && sameYearLabel.includes('15'), sameYearLabel);
  assert.ok(priorYearLabel.includes('2025'), priorYearLabel);

  const grouped = core.turns([
    { id: 'u1', turnID: 'r1', role: 'user', state: 'complete', sentAtMs: day1Late, blocks: [{ id: 'b1', type: 'text', text: 'Q' }] },
    { id: 'a1', turnID: 'r1', role: 'assistant', state: 'complete', sentAtMs: day2Early, blocks: [{ id: 'b2', type: 'tool', tool: { id: 't1', name: 'read_transcript', state: 'succeeded' } }] },
    { id: 'a2', turnID: 'r1', role: 'assistant', state: 'complete', sentAtMs: day2At30, blocks: [{ id: 'b3', type: 'text', text: 'A' }] },
    { id: 'sys', turnID: 'sys', role: 'system', state: 'complete', sentAtMs: day2At30, blocks: [{ id: 'b4', type: 'text', text: 'status' }] }
  ]);
  assert.equal(grouped[0].sentAtMs, day1Late);
  assert.equal(grouped[1].sentAtMs, day2Early, 'Multi-round assistant turn preserves its initial timestamp');
  assert.equal(grouped[2].sentAtMs, null, 'System rows never carry turn timestamps');
});
console.log(`${passed} renderer core tests passed`);
