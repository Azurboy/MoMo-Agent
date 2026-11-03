const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const web = path.join(__dirname, '../../Apps/iPhoneApp/Features/Assistant/Rendering/Web');
const context = vm.createContext({Intl, console});
for (const file of ['chat-localization.js', 'chat-core.js']) {
  vm.runInContext(fs.readFileSync(path.join(web, file), 'utf8'), context, {filename: file});
}
const core = context.MoMoChatCore, l10n = context.MoMoChatLocalization;
for (const [locale, thinking, read, reminder, todayPrefix, yesterdayPrefix] of [
  ['zh-Hans', '正在思考', '已读取录音原文', '待办', '今天 ', '昨天 '],
  ['en', 'Thinking', null, 'To-do', 'Today, ', 'Yesterday, '],
  ['ja', '考え中', null, 'リマインダー', '今日 ', '昨日 '],
  ['ko', '생각 중', null, '할 일', '오늘 ', '어제 ']
]) {
  core.setLocale(locale);
  assert.equal(core.processSummary([], true), thinking);
  const label = core.toolLabel({name:'read_transcript',state:'succeeded'});
  if (read) assert.equal(label, read);
  else assert.notEqual(label, '已读取录音原文');
  const receipt = {state:'succeeded',resource:{kind:'reminder',fields:{title:'Meet 山田 / 김민수',dueDate:'2026-10-20'}}};
  const card = core.actionCard({name:'create_reminder'},receipt);
  assert.equal(card.title, 'Meet 山田 / 김민수', 'User titles must not be translated.');
  assert.equal(card.kindLabel,reminder);
  assert.equal(l10n.text('仍在等待回复 · {0} 秒', 12).includes('12'),true);
  assert.equal(/\{\d+\}/.test(l10n.text('仍在等待回复 · {0} 秒',12)),false);
  const nowMs = new Date(2026, 10, 3, 15, 0, 0).getTime();
  const todayLabel = core.formatTimestampMarker(new Date(2026, 10, 3, 14, 30, 0).getTime(), nowMs);
  const yesterdayLabel = core.formatTimestampMarker(new Date(2026, 10, 2, 9, 15, 0).getTime(), nowMs);
  assert.ok(todayLabel.startsWith(todayPrefix) && todayLabel.includes('30'), `${locale}: ${todayLabel}`);
  assert.ok(yesterdayLabel.startsWith(yesterdayPrefix) && yesterdayLabel.includes('15'), `${locale}: ${yesterdayLabel}`);
  assert.equal(core.graphemes('Hello你好こんにちは안녕👨‍👩‍👧‍👦').at(-1),'👨‍👩‍👧‍👦');
}
core.setLocale('de-DE');
assert.equal(l10n.locale,'en');
assert.equal(l10n.text('正在思考'),'Thinking');
console.log('PASS four-language chat labels, tool states, action cards, placeholders, dates and unchanged user content');
