"""Semantic boundaries of original quest tuples; no client installation required."""
import unittest
from build_dnf_native_catalog import quest_plan,compile_quest
from build_dnf_quest_rules import build,load,OUT,AUDIT

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
    def test_full_reproducible_audit_and_runtime(self):
        runtime,audit=build();self.assertEqual(runtime,load(OUT));self.assertEqual(audit,load(AUDIT))
        self.assertEqual(len(audit['rows']),2824);self.assertEqual(len({r['id'] for r in audit['rows']}),2824)
        admitted={r['id'] for r in audit['rows'] if r['state']=='admitted'}
        self.assertEqual(admitted,{q['source']['id'] for q in runtime['quests']})
        self.assertTrue(all(not r['reasons'] for r in audit['rows'] if r['state']=='admitted'))
    def test_callbacks_never_become_universal_skill_events(self):
        f={'[type]':['[custom quest]'],'[sub type]':[0],'[int data]':[1,0,1]}
        _,_,reasons=compile_quest(999,'n_quest/example/a.qst','x',f,{}, {}, {}, {},custom_events={211})
        self.assertIn('custom_callback_unverified',reasons)
if __name__=='__main__':unittest.main()
