"""Semantic boundaries of original quest tuples; no client installation required."""
import unittest
import gzip,hashlib,json,tempfile
from pathlib import Path
from unittest.mock import patch
import build_dnf_quest_rules as compiler
from build_dnf_native_catalog import quest_plan,compile_quest
from build_dnf_quest_rules import build,load,OUT,AUDIT,stale_outputs,sync_catalog

def plan(kind,sub,values):return quest_plan({'[type]':[kind],'[sub type]':[sub],'[int data]':values})
class QuestRules(unittest.TestCase):
    def test_plain_clear_is_subtype_six(self):
        self.assertEqual(plan('[condition under clear]',6,[6,1])[0][0]['conditions'],{})
        self.assertTrue(plan('[condition under clear]',0,[6,1])[1])
    def test_seconds_and_hits_are_distinct(self):
        self.assertEqual(plan('[condition under clear]',0,[27,-1,570])[0][0]['conditions'],{'max_elapsed_ms':570000})
        self.assertEqual(plan('[condition under clear]',1,[15,-1,22])[0][0]['conditions'],{'max_hits_taken':22})
    def test_other_clear_conditions_are_not_plain_clear(self):
        self.assertEqual(plan('[condition under clear]',4,[34,2])[0][0]['conditions'],{'max_revives':0})
        self.assertEqual(plan('[condition under clear]',5,[1501,2,2])[0][0]['conditions'],{'min_party_size':2})
        for sub in [7,8,9,10,11,13,14,15,16]:self.assertTrue(plan('[condition under clear]',sub,[15,-1,22])[1])
    def test_enemy_kind_is_not_a_monster_identifier(self):
        p,r=plan('[hunt enemy]',-1,[62,-1,61809,1,2,6,1,109,1,3]);self.assertFalse(r);self.assertEqual([v['amount'] for v in p],[2,3])
        for kind in [2,3,10,-1]:self.assertTrue(plan('[hunt enemy]',-1,[62,-1,61809,kind,2])[1])
    def test_reject_malformed_parameters(self):
        for values in [[1,0,True],[1,0,1.5],[1,0,-1],[1,0]]:self.assertTrue(plan('[condition under clear]',0,values)[1])
        self.assertTrue(plan('[hunt enemy]',-1,[1,0,1,1])[1])
    def test_disassembly_exact_norton_tuple(self):
        self.assertEqual(plan('[disjoint item]',0,[-2,-1,-1,13])[0][0]['npc'],13)
        self.assertTrue(plan('[disjoint item]',0,[-2,-1,-1,17])[1])
    def test_clear_reward_keeps_original_dungeon(self):
        fields = {'[grade]': ['[epic]'], '[npc index]': [4], '[type]': ['[seeking]'],
                  '[sub type]': [-1], '[int data]': [3081, 1],
                  '[clear reward item]': [1000, -1, 3081, 1, 100, 1]}
        words = {'[name]': '暗黑雷鸣废墟', '[condition message]': '取得铁匠锤'}
        quest, _, reasons = compile_quest(203, 'n_quest/example/a.qst', 'x', fields, words, {},
                                          {'original_3081': {}}, {}, dungeon_index={1000: 'sunderland_dark'})
        self.assertEqual(reasons, [])
        self.assertEqual(quest['clear_items'], [{'dungeon': 'sunderland_dark',
            'difficulty': ['normal', 'adventure', 'expert', 'king'],
            'item': 'original_3081', 'amount': 1, 'limit': 1}])
        blocked, _, reasons = compile_quest(203, 'n_quest/example/a.qst', 'x', fields, words, {},
                                            {'original_3081': {}}, {}, dungeon_index={})
        self.assertNotIn('clear_items', blocked)
        self.assertIn('clear_reward_item_unsupported', reasons)
    def test_escort_map_is_blocked_until_survival_is_enforced(self):
        fields = {'[grade]': ['[epic]'], '[npc index]': [7], '[type]': ['[clear map]'],
                  '[sub type]': [0], '[int data]': [1619, 201], '[level]': [16, 99],
                  '[pre required quest]': [4306], '[cant giveup]': [1], '[reward int data]': [0, 5000]}
        words = {'[name]': 'G.S.D亲自出马', '[condition message]': '陪同G.S.D通关'}
        target = {'dungeon': 'draconiantower', 'cell': [0, 2], 'quest_id': 4307, 'companion_id': 201,
                  'difficulty': 'expert'}
        def compile_with_target():
            return compile_quest(4307, 'n_quest/example/a.qst', 'x', fields, words, {}, {}, {},
                                 dungeon_index={11: 'draconiantower'}, map_index={'1619': target})
        _, _, reasons = compile_with_target()
        self.assertIn('clear_map_companion_survival_unavailable', reasons)
        self.assertNotIn('clear_map_unavailable:1619', reasons)
        target['escort_runtime'] = True
        quest, _, reasons = compile_with_target()
        self.assertFalse(reasons)
        self.assertEqual(quest['objectives'], [{
            'id': 'objective_0', 'type': 'clear_map', 'amount': 1, 'target': 'draconiantower:0_2',
            'dungeon': 'draconiantower', 'cell': [0, 2], 'source_map_id': 1619,
            'quest_maze': 'original.quest.4307', 'companion_id': 201, 'difficulty': ['expert'],
        }])
        self.assertEqual(quest['min_level'], 16)
        self.assertEqual(quest['requires'], ['original.quest.4306'])
        self.assertFalse(quest['abandonable'])
        self.assertEqual(quest['reward']['gold'], 5000)
        target['companion_id'] = 202
        _, _, reasons = compile_with_target()
        self.assertIn('clear_map_extra_condition_unavailable', reasons)
    def test_full_reproducible_audit_and_runtime(self):
        runtime,audit=build();catalog,missing=sync_catalog(runtime)
        self.assertFalse(missing);self.assertEqual(stale_outputs(runtime,audit,catalog),[]);self.assertEqual(audit,load(AUDIT))
        self.assertEqual(len(audit['rows']),2824);self.assertEqual(len({r['id'] for r in audit['rows']}),2824)
        admitted={r['id'] for r in audit['rows'] if r['state']=='admitted'}
        self.assertEqual(admitted,{q['source']['id'] for q in runtime['quests']})
        self.assertTrue(all(not r['reasons'] for r in audit['rows'] if r['state']=='admitted'))
        eye_quest = next(q for q in runtime['quests'] if q['source']['id'] == 4306)
        self.assertEqual(eye_quest['requires'], ['original.quest.4305'])
        self.assertEqual(eye_quest['consume'], {'original_3129': 15})
        self.assertEqual(eye_quest['drops'], [
            {'monster': f'monster/draconian/{monster}.mob', 'dungeon': 'draconiantower',
             'difficulty': [mode], 'item': 'original_3129', 'amount': 1, 'chance': chance, 'limit': 15}
            for monster, chance in [('mirkius', 30), ('lakius', 100), ('minius', 30)]
            for mode in ('adventure', 'expert')
        ])
    def test_callbacks_never_become_universal_skill_events(self):
        f={'[type]':['[custom quest]'],'[sub type]':[0],'[int data]':[1,0,1]}
        _,_,reasons=compile_quest(999,'n_quest/example/a.qst','x',f,{}, {}, {}, {},custom_events={211})
        self.assertIn('custom_callback_unverified',reasons)
class StatusPackageChecks(unittest.TestCase):
    def setUp(self):
        self.folder=tempfile.TemporaryDirectory();self.addCleanup(self.folder.cleanup)
        root=Path(self.folder.name)
        for name in ['OUT','AUDIT','CATALOG','STATUS']:
            patcher=patch.object(compiler,name,root/name);patcher.start();self.addCleanup(patcher.stop)
        self.audit={'rows':[{'id':1,'state':'blocked','reasons':['dependency_missing']}]}
        self.runtime={'schema':'fixture','quests':[],'status_sha256':''}
        self.catalog={'quests':[]}
        self.install(compiler.status_bytes(self.audit))
    def install(self,blob):
        compiler.STATUS.write_bytes(blob)
        compiler.write(compiler.OUT,{**self.runtime,'status_sha256':hashlib.sha256(blob).hexdigest()})
        compiler.write(compiler.AUDIT,self.audit);compiler.write(compiler.CATALOG,self.catalog)
    def stale(self):return compiler.stale_outputs(self.runtime,self.audit,self.catalog)
    def test_platform_headers_and_compression_levels_preserve_content(self):
        for level in [1,9]:
            for platform in [3,10,255]:
                blob=bytearray(gzip.compress(compiler.status_payload(self.audit),compresslevel=level,mtime=0));blob[9]=platform
                self.install(bytes(blob));self.assertEqual(self.stale(),[])
    def test_changed_payload_is_rejected_even_with_updated_archive_hash(self):
        changed={'rows':[{'id':1,'state':'admitted','reasons':[]}]}
        self.install(compiler.status_bytes(changed));self.assertIn(compiler.STATUS,self.stale())
    def test_changed_bytes_without_updating_recorded_hash_are_rejected(self):
        blob=bytearray(compiler.STATUS.read_bytes());blob[9]=10;compiler.STATUS.write_bytes(blob)
        self.assertIn(compiler.OUT,self.stale())
    def test_corrupt_or_missing_archive_is_rejected(self):
        compiler.STATUS.write_bytes(b'broken gzip');self.assertIn(compiler.STATUS,self.stale())
        compiler.STATUS.unlink();self.assertIn(compiler.STATUS,self.stale())

if __name__=='__main__':unittest.main()
