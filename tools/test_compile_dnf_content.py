"""Dependency checks for native state-handler bindings in the combat pack."""
from copy import deepcopy
import unittest

from compile_dnf_content import NATIVE_ATTACK_EMISSIONS, compile_native_attack_emissions, compile_native_attack_selection


class NativeAttackEmissionTest(unittest.TestCase):
    def setUp(self):
        self.mob_path = 'monster/vehicle/catapult.mob'
        self.object_path = 'passiveobject/monster/vehicle/cannonball.obj'
        self.fire_ani = 'monster/vehicle/catapultani/fire.ani'
        self.fire_atk = 'monster/vehicle/attackinfo/ctfire.atk'
        self.projectile_ani = 'passiveobject/monster/vehicle/ani/cannonball.ani'
        self.projectile_atk = 'passiveobject/monster/vehicle/attackinfo/cannonball.atk'
        self.spec = deepcopy(NATIVE_ATTACK_EMISSIONS[self.mob_path])
        self.records = {
            path: {'id': path, 'source': {'sha256': sha}, 'decoded': {}, 'unsupported': [], 'diagnostics': []}
            for path, sha in self.spec['sha256'].items()
        }
        self.mob = self.records[self.mob_path]
        self.mob['raw'] = []
        self.mob['decoded'] = {
            'int_data': [30034], 'attack_motions': [self.fire_ani, self.fire_ani], 'attack_delay': 1200,
            'attack_infos': [self.fire_atk, self.fire_atk],
            'attack_kind': [20.0, 0.0, 0.0, 1, 200, 0, 0, 0, 40, 0, 40, 0,
                            60.0, 0.0, 0.0, 1, 200, 0, 0, 0, 40, 0, 40, 0] + [0] * 12,
        }
        self.records[self.object_path]['decoded'] = {
            'basic_motion': [self.projectile_ani], 'attack_infos': [self.projectile_atk],
        }
        self.records[self.fire_ani]['decoded'] = {'timeline': [{'frame': 11}]}
        self.records[self.fire_atk]['decoded'] = {'attack_enemy': 1}
        self.records[self.projectile_ani]['decoded'] = {'timeline': [{'attack_boxes': [[-10, -10, -10, 20, 20, 20]]}]}
        for binding in self.spec['slots']:
            self.records[binding['ptl_path']]['decoded'] = {'landing_type': '[vanish]'}
        self.index = {30034: 'monster/vehicle/cannonball.obj'}

    def compile(self):
        return compile_native_attack_emissions(
            self.mob, 270, self.spec, self.index, lambda path, _kind, _origin: self.records.get(path),
        )

    def test_slot_bindings_share_the_original_attack_object(self):
        angle, direct = self.compile()
        self.assertEqual([angle['slot'], direct['slot']], [0, 1])
        self.assertTrue(angle['ptl_path'].endswith('/cannonballangle.ptl'))
        self.assertTrue(direct['ptl_path'].endswith('/cannonballdirect.ptl'))
        for row in (angle, direct):
            self.assertEqual((row['object_id'], row['object_path']), (30034, self.object_path))
            self.assertEqual((row['frame'], row['offset'], row['sound']), (11, [70, 0, 50], 'DRGCANNON_SHOOT'))
        self.assertNotIn('native_attack_emissions', self.mob['decoded'])

    def test_missing_or_changed_dependency_fails_closed(self):
        del self.records[self.projectile_atk]
        with self.assertRaisesRegex(ValueError, 'needs exact source .*cannonball.atk'):
            self.compile()
        self.records[self.projectile_atk] = {'source': {'sha256': 'changed'}}
        with self.assertRaisesRegex(ValueError, 'needs exact source .*cannonball.atk'):
            self.compile()

    def test_lost_slot_or_projectile_box_fails_closed(self):
        self.mob['decoded']['attack_motions'].pop()
        with self.assertRaisesRegex(ValueError, 'invalid or duplicate attack slot 1'):
            self.compile()
        self.mob['decoded']['attack_motions'].append(self.fire_ani)
        self.records[self.projectile_ani]['decoded']['timeline'][0]['attack_boxes'].clear()
        with self.assertRaisesRegex(ValueError, 'no projectile attack boxes'):
            self.compile()

    def test_attack_policy_preserves_the_original_enabled_slot_rows(self):
        emissions = self.compile()
        source = self.spec['selection_source']
        policy = compile_native_attack_selection(self.mob, emissions, source)
        self.assertEqual((policy['initial_ms'], policy['delay_ms'], policy['delay_spread_ms']), (3000, 1200, 240))
        self.assertEqual(policy['down_gate_percent'], 0)
        self.assertEqual([(row['slot'], row['standing_percent'], row['no_target_percent']) for row in policy['slots']],
                         [(0, 20, 0), (1, 60, 0)])
        self.assertEqual([row['area'] for row in policy['slots']], [[200, 0, 0, 0, 40, 0, 40, 0]] * 2)
        self.mob['decoded']['attack_kind'][3] = 0
        with self.assertRaisesRegex(ValueError, 'disagrees with the emitted attack slots'):
            compile_native_attack_selection(self.mob, emissions, source)

    def test_attack_policy_rejects_unhandled_target_affiliation(self):
        self.records[self.fire_atk]['decoded']['attack_friend'] = 1
        with self.assertRaisesRegex(ValueError, 'needs hostile-only targeting'):
            self.compile()


if __name__ == '__main__':
    unittest.main()
