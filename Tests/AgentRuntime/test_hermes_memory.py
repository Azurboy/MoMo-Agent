"""UI reads and edits the native Hermes store, without a parallel memory engine."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'Apps/MacApp/Context'), str(ROOT/'Vendor/HermesAgent')]
from hermes_memory import HermesMemory
from context_store import Conflict


class HermesMemoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home/'config.yaml').write_text(json.dumps({'memory':{'memory_enabled':True,'user_profile_enabled':True}}))
        self.memory = HermesMemory(self.home)

    def test_native_writes_appear_in_ui_and_ui_delete_updates_native_store(self):
        with self.memory.store() as store:
            self.assertTrue(store.add('memory', '周五给小林发方案。')['success'])
            self.assertTrue(store.add('user', '喜欢清淡的食物。')['success'])
        items = self.memory.list()['items']; item = next(i for i in items if i['kind']=='memory')
        self.assertEqual('hermes', item['basis']); self.assertEqual([],item['evidence'])
        self.memory.forget(item['id']); self.memory.forget(item['id'])
        with self.memory.store() as store:
            self.assertEqual([],store.memory_entries); self.assertEqual(['喜欢清淡的食物。'],store.user_entries)

    def test_stale_identity_never_removes_newer_native_entry(self):
        with self.memory.store() as store: store.add('memory','周五交方案。')
        old = self.memory.list()['items'][0]
        with self.memory.store() as store: store.patch('memory','周五','周一')
        self.memory.forget(old['id'])
        self.assertEqual('周一交方案。',self.memory.list()['items'][0]['text'])
        with self.assertRaises(Conflict): self.memory.forget('old-momo-fact-id')

    def test_bounded_native_store_keeps_limits_and_changed_page_is_rejected(self):
        with self.memory.store() as store:
            store.add('memory','第一条。')
            self.assertFalse(store.add('memory','内容'*2000)['success'])
        page = self.memory.list()
        with self.memory.store() as store: store.add('memory','第二条。')
        with self.assertRaises(Conflict): self.memory.list(expected_revision=page['revision'])

    def test_other_home_is_not_read_or_modified(self):
        other = self.home/'other'; other.mkdir()
        with self.memory.store() as store: store.add('user','当前实例的用户。')
        with HermesMemory(other).store() as store: self.assertEqual([], store.user_entries)
        self.assertEqual(1,len(self.memory.list()['items']))

    def test_markdown_notebook_briefing_journal_person_and_topic_roundtrip(self):
        # Reject raw JSON dumps; notebook files must be pure Markdown.
        bad = self.memory.write_notebook('topic', '{"not": "markdown"}', slug='bad-json')
        self.assertFalse(bad['success'])

        b_res = self.memory.write_notebook(
            'briefing',
            '# 晨间简报 · 2026-11-10\n\n## 今日脉络\n今天继续推进 Dream 闲时整合。\n\n## 卡片：梳理人物声纹与脉络\n- 纹样：关系交汇\n- 语境：承接昨日工作室讨论\n\n请帮我把最近录音里小林相关的讨论和待办整理出来。',
        )
        self.assertTrue(b_res['success'])
        p_res = self.memory.write_notebook('person', '协作伙伴，负责后端接口联调。', slug='小林', title='小林 · 协作脉络')
        self.assertTrue(p_res['success'])
        j_res = self.memory.write_notebook('journal', '# 2026-11-10 · 架构与地图优化\n\n- 上午完成了地图轨迹原生渲染。', slug='2026-11-10')
        self.assertTrue(j_res['success'])
        t_res = self.memory.write_notebook('topic', '# Dream 闲时记忆架构\n\n## 当前共识\n采用纯 Markdown 活页笔记本。', slug='dream-notebook')
        self.assertTrue(t_res['success'])

        notes = self.memory.list_notebook()
        self.assertEqual({'briefing', 'journal', 'person', 'topic'}, {n['category'] for n in notes})

        items = self.memory.list()['items']
        kinds = {i['kind'] for i in items}
        self.assertEqual({'briefing', 'journal', 'person', 'topic'}, kinds)
        person_item = next(i for i in items if i['kind'] == 'person')
        self.assertIn('# 小林 · 协作脉络', person_item['text'])
        self.assertEqual('dream', person_item['basis'])

        # Deleting a Markdown notebook item via forget() removes the underlying .md file
        # and records a tombstone so Dream will not recreate the deleted person/topic/project.
        self.memory.forget(person_item['id'])
        self.assertFalse((self.home / 'memories/people/小林.md').exists())
        recreate = self.memory.write_notebook('person', '重新创建的说话人', slug='小林', title='小林')
        self.assertFalse(recreate['success'])


