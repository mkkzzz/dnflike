"""Audit source identities, native images, original reciprocal maze routes and town exits."""
import hashlib
import json
from pathlib import Path
import unittest
from PIL import Image
from dnf_asset_store import ROOT,cache_home
from dnf_asset_reader import decode,parse
from dnf_pvf import Library,first_values

class GranAssets(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base=ROOT/'game_dnf/assets_local/flow_v1/gran_v1'
        cls.art=json.loads((cls.base/'manifest.json').read_text(encoding='utf-8'))
        cls.world=json.loads((ROOT/'game_dnf/data/towns.json').read_text(encoding='utf-8'))
        cls.routes=json.loads((ROOT/'game_dnf/data/dungeons.json').read_text(encoding='utf-8'))['dungeons']
        cls.quests=json.loads((ROOT/'game_dnf/data/quests.json').read_text(encoding='utf-8'))['quests']
        cls.source=Library()

    @classmethod
    def tearDownClass(cls):cls.source.close()

    def test_source_quest_fields_not_guessed_from_filename(self):
        for q in [q for q in self.quests if q['id'].startswith('gran.')]:
            s=self.source.script(q['source']['path']);f=s['fields']
            self.assertEqual(q['source']['sha256'],s['sha256'])
            self.assertEqual(q['min_level'],first_values(f,'[level]')[0])
            self.assertEqual(q['source']['raw_objective'],first_values(f,'[int data]'))
            self.assertEqual(q['source']['raw_reward'],first_values(f,'[reward int data]'))
        self.assertEqual(len([q for q in self.quests if q['id'].startswith('gran.')]),3)

    def test_source_start_boss_and_every_reciprocal_gate(self):
        for key in ['mirkwood','mirkwood_deep']:
            d=json.loads((self.base/key/'map_export.json').read_text(encoding='utf-8'))['dungeon']
            self.assertEqual(self.routes[key]['monster_level'],first_values(self.source.script(self.routes[key]['source']['path'])['fields'],'[basis level]')[0])
            route=self.routes[key]['rooms'];placements={p['id']:p for p in d['placements']}
            start=d['start_map_raw'];boss=d['boss_map_raw']
            self.assertIn(placements[route[0]['placement']]['cell'],[start[i:i+2] for i in range(0,len(start),2)])
            self.assertIn(placements[route[-1]['placement']]['cell'],[boss[i:i+2] for i in range(0,len(boss),2)])
            opposite={'left':'right','right':'left','up':'down','down':'up'}
            for a,b in zip(route,route[1:]):
                p,n=placements[a['placement']],placements[b['placement']]
                self.assertTrue(any(g['direction']==a['next'] and g['target_cell']==n['cell'] and g['anchor'] for g in p['gates']))
                self.assertTrue(any(g['direction']==opposite[a['next']] and g['target_cell']==p['cell'] and g['anchor'] for g in n['gates']))

    def test_no_spawn_disappears_and_boss_is_the_original_identity(self):
        mobs=json.loads((ROOT/'game_dnf/data/combat.json').read_text(encoding='utf-8'))['monsters']
        supported={m['mob'] for m in mobs.values()}
        for key,expected in [('mirkwood',12),('mirkwood_deep',5002)]:
            d=json.loads((self.base/key/'map_export.json').read_text(encoding='utf-8'))['dungeon']
            placements={p['id']:p for p in d['placements']}
            for entry in self.routes[key]['rooms']:
                room=d['rooms'][placements[entry['placement']]['map']]
                self.assertLessEqual({m['mob'] for m in room['monsters']},supported)
            self.assertIn(expected,[m['id'] for m in room['monsters']])

    def test_town_source_exit_pairs_and_shylock_anchor(self):
        paths={'hendon_main':'map/hendonmyre/(r)hendon.map','hendon_auction':'map/hendonmyre/hendon_auction.map',
               'hendon_forest_gate':'map/hendonmyre/d_hendon.map','hendon_alley':'map/hendonmyre/hendon_ura.map'}
        for id in ['main_to_forest_gate','forest_gate_to_main','auction_to_alley','alley_to_auction']:
            p=self.world['portals'][id];raw=first_values(self.source.script(paths[p['from']])['fields'],'[town movable area]')
            self.assertIn(p['source_raw'],[raw[i:i+6] for i in range(0,len(raw),6)])
        self.assertEqual(self.art['npcs']['shylock']['anchor'],[619,193,0])
        self.assertEqual(self.world['locations']['hendon_alley']['npcs']['shylock'],[619,193])

    def test_required_art_has_no_unresolved_errors(self):
        for folder,name in [(self.base,'manifest.json')]+[(self.base/k,'map_export.json') for k in ['mirkwood','mirkwood_deep']]:
            d=json.loads((folder/name).read_text(encoding='utf-8'))
            self.assertFalse([x for x in d['diagnostics'] if x['level']=='error'])
            for info in d['images'].values():
                with Image.open(folder/info['file']) as im:self.assertEqual(list(im.size),info['size'])

    def test_new_native_PNGs_equal_source_IMG(self):
        import sqlite3
        db=sqlite3.connect(f'file:{self.source.path/"catalog.sqlite"}?mode=ro',uri=True)
        from functools import lru_cache
        @lru_cache(None)
        def image(sha):
            row=db.execute('select local_path from assets where sha256=?',(sha,)).fetchone()
            raw=(self.source.path/row[0]).read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(),sha)
            return raw,parse(raw)
        try:
            for folder,name in [(self.base,'manifest.json')]+[(self.base/k,'map_export.json') for k in ['mirkwood','mirkwood_deep']]:
                for info in json.loads((folder/name).read_text(encoding='utf-8'))['images'].values():
                    raw,parsed=image(info['img_sha256']);expected,_=decode(raw,parsed,info['frame'])
                    with Image.open(folder/info['file']) as actual:
                        self.assertEqual(actual.convert('RGBA').tobytes(),expected.tobytes())
        finally:db.close()

    def test_new_monster_atlas_frames_equal_original_trimmed_pixels(self):
        from build_dnf_combat_assets import Source,cropped
        src=Source(self.source.path)
        base=ROOT/'game_dnf/assets_local/combat'
        data=json.loads((base/'manifest.json').read_text(encoding='utf-8'))
        try:
            for key in ['tau_beast','lugaru','kurogaru','goblin_ice','goblin_fire','goblin_taskmaster','goblin_thrower_taskmaster']:
                bank=data['monsters'][key];atlas=bank['atlas']
                texture=ROOT/'game_dnf'/atlas['texture'].removeprefix('res://')
                with Image.open(texture) as im:
                    for index,item in atlas['items'].items():
                        expected,meta=src.frame(bank['body_image'],int(index));expected,offset=cropped(expected,meta)
                        x,y,w,h=item['rect'];actual=im.crop((x,y,x+w,y+h)).convert('RGBA')
                        self.assertEqual(actual.tobytes(),expected.tobytes())
                        self.assertEqual(item['offset'],offset)
        finally:src.lib.close();src.cat.close()

if __name__=='__main__':unittest.main()
