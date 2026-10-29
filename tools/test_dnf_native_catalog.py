import unittest
from build_dnf_native_catalog import compile_item, quest_plan, LISTS


class NativeCompiler(unittest.TestCase):
    def item(self, fields):
        return compile_item(1, LISTS['stackable'], 'stackable/test.stk', 'sha',
                            {'[icon]':['Item/test.img',0], '[field image]':['Item/test.img',0], **fields}, {'[name]':'测试物品'})

    def test_recovery_percent_remains_percent_until_use(self):
        item, _, recovery, reasons = self.item({'[stackable type]':['[waste]',0], '[hp recovery]':['%',30,1000,'myself']})
        self.assertFalse(reasons)
        self.assertEqual(recovery['effect'], {'kind':'restore','hp':0,'mp':0,'hp_percent':30,'mp_percent':0,'duration_ms':1000})

    def test_party_and_inconsistent_timing_are_not_silently_flattened(self):
        for fields in [{'[hp recovery]':['+',50,1000,'party']},
                       {'[hp recovery]':['+',50,1000,'myself'],'[mp recovery]':['+',50,5000,'myself']}]:
            self.assertTrue(self.item({'[stackable type]':['[waste]',0], **fields})[3])

    def test_recipe_is_never_promoted_to_equipment_or_passive_material(self):
        self.assertIn('item_type:[recipe]', self.item({'[stackable type]':['[recipe]',1]})[3])

    def test_unknown_effect_blocks_only_execution(self):
        self.assertIn('field:[unknown effect]', self.item({'[stackable type]':['[material]',0], '[unknown effect]':[10]})[3])

    def test_multi_target_collect_is_not_truncated(self):
        plan, reasons = quest_plan({'[type]':['[seeking]'],'[sub type]':[-1],'[int data]':[100,2,200,3]})
        self.assertFalse(reasons);self.assertEqual([p['amount'] for p in plan],[2,3])

    def test_clear_subtypes_do_not_become_plain_victory(self):
        for sub in [1,7]:
            self.assertTrue(quest_plan({'[type]':['[condition under clear]'],'[sub type]':[sub],'[int data]':[6,1,90]})[1])

    def test_hunt_monster_uses_verified_four_value_tuple(self):
        plan, reasons = quest_plan({'[type]':['[hunt monster]'],'[sub type]':[-1],'[int data]':[6,-1,5004,2]})
        self.assertFalse(reasons);self.assertEqual(plan[0]['monster'],5004)

    def test_hunt_enemy_is_not_misread_as_hunt_monster(self):
        self.assertTrue(quest_plan({'[type]':['[hunt enemy]'],'[sub type]':[-1],'[int data]':[6,-1,608,2,1]})[1])


if __name__ == '__main__':unittest.main()
