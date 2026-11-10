"""Dependency checks for native state-handler bindings in the combat pack."""
from copy import deepcopy
import hashlib
import json
from pathlib import PurePosixPath
import unittest

from compile_dnf_content import (
    NATIVE_ATTACK_CONTACTS,
    NATIVE_ATTACK_EMISSIONS,
    NATIVE_OUTERWALL_BREAKABLES,
    OUTERWALL_BREAKABLE_ROOT,
    compile_native_attack_contact,
    compile_native_attack_emissions,
    compile_native_attack_selection,
)
from dnf_asset_store import ROOT


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
        with self.assertRaisesRegex(ValueError, 'disagrees with its bound attack slots'):
            compile_native_attack_selection(self.mob, emissions, source)

    def test_attack_policy_rejects_unhandled_target_affiliation(self):
        self.records[self.fire_atk]['decoded']['attack_friend'] = 1
        with self.assertRaisesRegex(ValueError, 'needs hostile-only targeting'):
            self.compile()


class NativeAttackContactTest(unittest.TestCase):
    def setUp(self):
        self.path = 'monster/zealot/bosspope.mob'
        self.obj = 'passiveobject/monster/zealot/popethunderbolt.obj'
        self.bolt_atk = 'passiveobject/monster/zealot/attackinfo/popethunderbolt.atk'
        self.bolt_ani = 'passiveobject/common/animation/thunderbolt.ani'
        spec = NATIVE_ATTACK_CONTACTS[self.path]
        self.spec = spec
        self.records = {
            path: {'id': path, 'source': {'sha256': sha}, 'decoded': {}}
            for path, sha in spec['sha256'].items()
        }
        attack_ani = 'monster/zealot/popeani/attack.ani'
        self.records[self.path]['decoded'] = {
            'attack_motions': [attack_ani],
            'attack_infos': ['monster/zealot/attackinfo/poattack.atk'],
        }
        self.records[self.obj]['decoded'] = {
            'basic_motion': [self.bolt_ani], 'attack_infos': [self.bolt_atk],
        }
        for path in (attack_ani, self.bolt_ani):
            self.records[path]['decoded'] = {'timeline': [{'attack_boxes': [[0, 0, 0, 1, 1, 1]]}]}

    def compile(self, relative_obj='monster/zealot/popethunderbolt.obj'):
        return compile_native_attack_contact(self.records[self.path], 266, self.spec, {30073: relative_obj},
                                             lambda path, _kind, _origin: self.records.get(path))

    def test_contact_binds_the_pinned_attack_slot_and_object(self):
        row = self.compile()
        self.assertEqual((row['slot'], row['target_class'], row['chance_percent']), (0, 0x11, 50))
        self.assertEqual((row['object_id'], row['object_path'], row['object_bank']),
                         (30073, self.obj, 'native_pope_thunderbolt'))

    def test_contact_requires_exact_index_and_attack_dependencies(self):
        with self.assertRaisesRegex(ValueError, 'needs exact source .*other.obj'):
            self.compile('monster/zealot/other.obj')
        self.records[self.bolt_atk]['source']['sha256'] = 'changed'
        with self.assertRaisesRegex(ValueError, 'needs exact source .*popethunderbolt.atk'):
            self.compile()
        self.records[self.bolt_atk]['source']['sha256'] = self.spec['sha256'][self.bolt_atk]
        self.records[self.bolt_ani]['decoded']['timeline'][0]['attack_boxes'].clear()
        with self.assertRaisesRegex(ValueError, 'needs both original attack timelines'):
            self.compile()


class OuterwallProductionContentTest(unittest.TestCase):
    def test_native_breakable_dependencies_are_packaged(self):
        game = ROOT / 'game_dnf'
        assets = game / 'assets_local'
        records = json.loads((assets / 'content/combat_content.json').read_text(encoding='utf8'))['records']
        manifest = json.loads((assets / 'combat/manifest.json').read_text(encoding='utf8'))
        for source_id, hp, boxes, pieces in ((300, 300, 2, 7), (770, 500, 3, 6), (771, 1, 2, 6)):
            with self.subTest(source_id=source_id):
                stem, _, _, obj_sha, ani_sha, ptl_sha = NATIVE_OUTERWALL_BREAKABLES[source_id]
                path = OUTERWALL_BREAKABLE_ROOT + stem + '.obj'
                binding = records[path]['native_breakable']
                motion, particle = binding['motion_ani'], binding['destroy_particle']
                self.assertEqual((binding['object_index'], binding['hp'], binding['stages']), (source_id, hp, 1))
                self.assertEqual((binding['trigger_stage'], binding['destroy_on_final_stage']), (1, True))
                for dependency, digest in ((path, obj_sha), (motion, ani_sha), (particle, ptl_sha)):
                    self.assertEqual(binding['source_hashes'][dependency], digest)
                    self.assertEqual(records[dependency]['source']['sha256'], digest)
                    self.assertEqual(manifest['sources'][dependency], digest)
                self.assertEqual(len(records[motion]['decoded']['timeline'][0]['damage_boxes']), boxes)
                decoded = manifest['particles'][particle]['decoded']
                self.assertEqual(decoded, records[particle]['decoded'])
                self.assertEqual(len(decoded['object_entries']), pieces)
                for row in decoded['object_entries']:
                    animation = row['path']
                    bank = manifest['effects']['native_' + PurePosixPath(animation).stem]
                    self.assertEqual(bank['source'], animation)
                    self.assertEqual(records[animation]['source']['sha256'], binding['source_hashes'][animation])
                    self.assertTrue((game / bank['atlas']['texture'].removeprefix('res://')).is_file())
        hit = manifest['audio']['WOOD_HIT'][0]
        self.assertEqual(hit['source'], 'sounds/effect/wood_hit.ogg')
        self.assertEqual(hashlib.sha256((game / hit['file'].removeprefix('res://')).read_bytes()).hexdigest(), hit['sha256'])

    def test_breakable_with_explicit_destroy_particle_is_packaged(self):
        game = ROOT / 'game_dnf'
        assets = game / 'assets_local'
        records = json.loads((assets / 'content/combat_content.json').read_text(encoding='utf8'))['records']
        manifest = json.loads((assets / 'combat/manifest.json').read_text(encoding='utf8'))
        path = 'passiveobject/mapobject/breakableobject/underfoot_tombstone.obj'
        binding = records[path]['native_breakable']
        self.assertEqual(binding['source']['layout'],
                         'seven-int/six-string with explicit destroy particle reference')
        self.assertEqual(binding['motion_ani'],
                         'passiveobject/mapobject/breakableobject/animation/underfoot_tombstone.ani')
        self.assertEqual(binding['destroy_particle'],
                         'passiveobject/mapobject/breakableobject/particle/underfoot_tombstonedestroy.ptl')
        self.assertEqual((binding['particle_offset'], binding['hp'], binding['trigger_stage'], binding['stages']),
                         ([0, 0, 30], 1, 1, 1))
        self.assertEqual((binding['hit_sound'], binding['destroy_sound']), ('WOOD_HIT', 'WOOD_CRASH'))
        for dependency, digest in binding['source_hashes'].items():
            self.assertEqual(records[dependency]['source']['sha256'], digest)
        self.assertEqual(len(records[binding['motion_ani']]['decoded']['timeline'][0]['damage_boxes']), 1)
        entries = records[binding['destroy_particle']]['decoded']['object_entries']
        self.assertEqual(len(entries), 4)
        for entry in entries:
            animation = entry['path']
            bank = manifest['effects']['ptl_' + PurePosixPath(animation).stem]
            self.assertEqual(bank['source'], animation)
            self.assertEqual(records[animation]['source']['sha256'], binding['source_hashes'][animation])

    def test_source_actors_and_attack_objects_are_packaged(self):
        assets = ROOT / 'game_dnf/assets_local'
        pack = json.loads((assets / 'content/combat_content.json').read_text(encoding='utf8'))
        manifest = json.loads((assets / 'combat/manifest.json').read_text(encoding='utf8'))
        indexes = pack['indexes']
        records = pack['records']
        for mob_id, bank_id, path, attack_frames in (
            (265, 'native_bossfather', 'monster/zealot/bossfather.mob', 4),
            (266, 'native_bosspope', 'monster/zealot/bosspope.mob', 4),
            (270, 'native_catapult', 'monster/vehicle/catapult.mob', 18),
        ):
            with self.subTest(mob=mob_id):
                self.assertEqual(indexes['monsters_goblin'][str(mob_id)], path)
                bank = manifest['monsters'][bank_id]
                self.assertEqual(bank['mob'], path)
                self.assertEqual(len(bank['clips']['attack']['frames']), attack_frames)
                self.assertEqual(manifest['sources'][path], records[path]['source']['sha256'])
                for dependency in records[path]['decoded']['attack_infos']:
                    self.assertEqual(records[dependency]['kind'], 'atk')

        pope = records[indexes['monsters_goblin']['266']]['native_attack_contacts']
        cannon = records[indexes['monsters_goblin']['270']]['native_attack_emissions']
        self.assertEqual([row['object_id'] for row in pope], [30073])
        self.assertEqual([(row['slot'], row['object_id']) for row in cannon], [(0, 30034), (1, 30034)])
        for emission in cannon:
            self.assertEqual(records[emission['ptl_path']]['kind'], 'ptl')
        for object_id, bank_id in ((30034, 'native_cannonball'), (30073, 'native_pope_thunderbolt')):
            path = indexes['passive_objects'][str(object_id)]
            self.assertEqual(records[path]['kind'], 'obj')
            self.assertEqual(manifest['objects'][bank_id]['object'], path)


if __name__ == '__main__':
    unittest.main()
