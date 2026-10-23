"""Audit shared Hendon source pixels, native extended floor and town graph evidence."""
import hashlib
import json
from pathlib import Path
import unittest
from PIL import Image
from dnf_asset_store import ROOT,cache_home
from dnf_asset_reader import decode,parse
from export_dnf_map import Library,span_values

class HendonAssets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base=ROOT/'game_dnf/assets_local/flow_v1/hendon_v1'
        cls.art=json.loads((cls.base/'manifest.json').read_text(encoding='utf-8'))
        cls.world=json.loads((ROOT/'game_dnf/data/towns.json').read_text(encoding='utf-8'))

    def test_required_native_rooms_and_npc_anchors(self):
        self.assertEqual(set(self.art['npcs']),{'hendon_city','hendon_main','hendon_auction'})
        for place in self.art['dungeon']['placements']:
            location=self.world['locations'][place['id']]
            for npc in self.art['npcs'][place['id']]:
                self.assertEqual(location['npcs'][npc['id']],npc['anchor'][:2])
        self.assertEqual(self.world['locations']['hendon_main']['npcs']['pungjin'],[838,210])
        self.assertEqual(self.world['locations']['hendon_auction']['npcs']['gsd'],[1496,208])

    def test_original_extended_floor_is_not_upscaled(self):
        room=self.art['dungeon']['rooms']['map/hendonmyre/(r)hendon.map']
        tiles=[t for t in room['tiles'] if t.get('extended')]
        self.assertEqual(len(tiles),11)
        for tile in tiles:
            self.assertEqual(self.art['images'][tile['image']]['size'],[224,120])
            self.assertEqual(tile['offset'][1],480)

    def test_source_diagnostics_have_no_silent_errors(self):
        self.assertFalse([d for d in self.art['diagnostics'] if d['level']=='error'])
        self.assertIn('(r)hendon',self.art['source']['selection'])
        self.assertEqual(len(self.art['ui']['portraits']),8)
        self.assertLessEqual(self.art['ui']['portraits'].keys(),self.world['npcs'].keys())

    def test_new_pngs_equal_original_IMG_pixels(self):
        library=cache_home()/'dnf-native-assets-v1-20261022/library_v1'
        if not (library/'catalog.sqlite').is_file():self.skipTest('source pixel audit needs full library')
        lib=Library(library,ROOT/'temp/hendon_pixel_audit')
        try:
            for info in self.art['images'].values():
                row=lib.catalog.execute('select local_path from assets where sha256=?',(info['img_sha256'],)).fetchone()
                raw=(lib.root/row[0]).read_bytes()
                self.assertEqual(hashlib.sha256(raw).hexdigest(),info['img_sha256'])
                expected,_=decode(raw,parse(raw),info['frame'])
                actual=Image.open(self.base/info['file']).convert('RGBA')
                self.assertEqual(actual.size,expected.size)
                self.assertEqual(actual.tobytes(),expected.tobytes())
        finally:lib.close()

    def test_raw_portal_groups_still_reference_original_MAP_fields(self):
        library=cache_home()/'dnf-native-assets-v1-20261022/library_v1'
        if not (library/'pvf_config.sqlite').is_file():self.skipTest('source portal audit needs full library')
        lib=Library(library,ROOT/'temp/hendon_pixel_audit')
        paths={'elvengard':'map/elvengard/elvengard.map','hendon_city':'map/hendonmyre/hendon_city.map',
               'hendon_main':'map/hendonmyre/(r)hendon.map','hendon_auction':'map/hendonmyre/hendon_auction.map'}
        try:
            for portal in self.world['portals'].values():
                if not portal['source_raw']:continue
                if portal['from'] not in paths:continue # New region has its own source audit.
                raw=span_values(lib.script(paths[portal['from']])['spans'],'[town movable area]')
                self.assertIn(portal['source_raw'],[raw[i:i+6] for i in range(0,len(raw),6)])
        finally:lib.close()

if __name__=='__main__':unittest.main()
