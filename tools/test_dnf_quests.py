"""Original chapter asset and source-route checks, separate from GUI tests."""
import json
from pathlib import Path
import unittest
from PIL import Image
from dnf_asset_store import ROOT, cache_home
from dnf_asset_reader import parse, decode
from export_dnf_map import Library


class QuestAssets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = ROOT/'game_dnf/assets_local/flow_v1/early_quests'
        cls.art = json.loads((cls.base/'manifest.json').read_text(encoding='utf-8'))
        cls.routes = json.loads((ROOT/'game_dnf/data/dungeons.json').read_text(encoding='utf-8'))['dungeons']
        cls.pack = json.loads((ROOT/'game_dnf/assets_local/content/combat_content.json').read_text(encoding='utf-8'))
        cls.combat = json.loads((ROOT/'game_dnf/assets_local/combat/manifest.json').read_text(encoding='utf-8'))

    def test_original_chinese_lorien_cards_and_large_portrait(self):
        for key in self.art['ui']['dungeons'].values():
            info = self.art['images'][key]
            self.assertEqual(info['source_path'].lower(),'sprite/worldmap/selectdungeonslot/elvengard.img')
            self.assertEqual(info['size'],[168,80])
        self.assertEqual(self.art['images'][self.art['ui']['seria_portrait']]['size'],[199,247])

    def test_source_rooms_keep_dungeon_identity(self):
        for key in ['lorien','lorien_inside']:
            export = json.loads((ROOT/'game_dnf'/self.routes[key]['map_export'].removeprefix('res://')).read_text(encoding='utf-8'))
            expected = 'dungeon/act1/'+('lorieninside' if key=='lorien_inside' else key)+'.dgn'
            self.assertEqual(export['dungeon']['path'],expected)
            places = {p['id']:p for p in export['dungeon']['placements']}
            route = self.routes[key]['rooms']
            for i, room in enumerate(route):
                p = places[room['placement']]
                for monster in export['dungeon']['rooms'][p['map']]['monsters']:
                    self.assertIn(monster['mob'], self.pack['records'])
                    self.assertTrue(any(m['mob']==monster['mob'] for m in self.combat['monsters'].values()))
                if i+1<len(route):
                    target=places[route[i+1]['placement']]['cell']
                    self.assertTrue(any(g['direction']==room['next'] and g['target_cell']==target for g in p['gates']))
            boss=places[route[-1]['placement']]['cell']
            self.assertTrue(any([c['x'],c['y']]==boss and c['boss_candidate'] for c in export['dungeon']['cells']))

    def test_tau_is_real_mob_and_native_animation_bank(self):
        tau=self.combat['monsters']['tau_army']
        self.assertEqual(tau['mob'],'monster/tau/tauarmy.mob')
        self.assertTrue(tau['clips']['attack1']['frames'])
        self.assertTrue(self.pack['records'][tau['mob']]['source']['sha256'])

    def test_new_frames_equal_source_pixels(self):
        library=cache_home()/'dnf-native-assets-v1-20261022/library_v1'
        if not (library/'catalog.sqlite').is_file():self.skipTest('full library required for source pixel audit')
        lib=Library(library,ROOT/'temp/quest_pixel_audit')
        try:
            for info in self.art['images'].values():
                row=lib.catalog.execute('select local_path from assets where sha256=?',(info['img_sha256'],)).fetchone()
                raw=(lib.root/row[0]).read_bytes()
                expected,_=decode(raw,parse(raw),info['frame'])
                actual=Image.open(self.base/info['file']).convert('RGBA')
                self.assertEqual(actual.size,expected.size)
                self.assertEqual(actual.tobytes(),expected.tobytes())
        finally:lib.close()


if __name__=='__main__':unittest.main()
