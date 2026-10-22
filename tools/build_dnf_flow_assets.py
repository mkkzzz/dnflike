"""Rebuild native town/UI assets from the shared, hash-checked DNF library.

No painted substitutes or upscaling. Output is ignored; recipes and source hashes
are shared in Git. PVF town coordinates/layers remain inferred, not certified.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from PIL import Image

from dnf_asset_store import ROOT, LOCK, cache_home
from export_dnf_map import (Library, export_map, span_values, resolve, COORDINATES,
                            TILE_W, TILE_H, CELL_W, CELL_H, GRID_COLS, GRID_ROWS, LAYERS)

OUTPUT = ROOT / 'game_dnf/assets_local/flow_v1'


def build(library: Path, output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    lib = Library(library, output)
    try:
        ids = {'objects': lib.listing('passiveobject/passiveobject.lst'),
               'monsters': lib.listing('monster/monster.lst')}
        town_path = 'map/elvengard/elvengard.map'
        town = export_map(lib, town_path, ids)
        npcs = lib.listing('npc/npc.lst')
        raw = span_values(lib.script(town_path)['spans'], '[NPC]')
        npc_sources = []
        for i in range(0, len(raw), 5):
            npc_id, direction, x, y, z = raw[i:i + 5]
            path = 'npc/' + npcs[npc_id].lower()
            script = lib.script(path)
            ani = span_values(script['spans'], '[field animation]')[0]
            sprite = lib.sprite(resolve(path, ani), path)
            if not sprite:
                raise ValueError('Required original NPC missing: ' + path)
            town['animations'].append({'layer': 'normal', 'anchor': [x, y, z],
                                       'space': 'map', 'sprite': sprite})
            npc_sources.append({'id': npc_id, 'path': path, 'sha256': script['sha256'],
                                'direction_raw': direction, 'anchor': [x, y, z]})
        refs = {
            'hud': ('Interface/MainHud.img', [0, 1, 2, 3, 4, 37, 38]),
            'common': ('Interface/WindowCommon.img', list(range(9)) + [12, 13, 14, 15, 66, 67, 68, 69, 147]),
            'inventory': ('Interface/ItemInventoryWindow.img', [0]),
            'shop': ('Interface/StackableShopWindow.img', [0]),
            'portrait': ('Map/Npc/NpcFace01.img', [8, 9]),
            'result': ('Interface/NewResult/Result.img', [3, 6, 7, 8, 12]),
            'select': ('Interface/SelectDungeon02.img', [11, 58, 105]),
            'lorien': ('Map/CutScene/Lorien.img', [0]),
        }
        ui = {name: {str(n): lib.image(ref, n, 'flow/' + name) for n in frames}
              for name, (ref, frames) in refs.items()}
        # Icons are explicitly appearance references; v1 item balance is E-ADAPT.
        potion_script = lib.script('stackable/ptn_hplowest.stk')
        potion_icon = span_values(potion_script['spans'], '[icon]')
        ui['items'] = {
            'iron_sword': lib.image('Item/weapon/swordman/katana.img', 0, 'flow/items'),
            'forest_sword': lib.image('Item/weapon/swordman/katana.img', 1, 'flow/items'),
            'potion': lib.image(potion_icon[0], potion_icon[1], 'flow/items'),
        }
        if any(k is None for group in ui.values() for k in group.values()):
            raise ValueError('Required original UI/icon decode failed: ' + str([d for d in lib.diags if d['level']=='error']))
        # Compose native border fragments without resampling, for tiled NinePatch UI.
        shop_image = Image.open(output / lib.images[ui['shop']['0']]['file']).convert('RGBA')
        # Original shop message surface, an opaque textured patch without text.
        panel = shop_image.crop((108, 30, 148, 65))
        pieces = [Image.open(output / lib.images[ui['common'][str(i)]]['file']) for i in range(9)]
        for i, at in [(0, (0, 0)), (1, (14, 0)), (2, (26, 0)), (3, (0, 11)),
                      (5, (29, 11)), (6, (0, 24)), (7, (11, 24)), (8, (29, 24))]:
            panel.alpha_composite(pieces[i].convert('RGBA'), at)
        panel.save(output / 'panel.png')
        fonts = lib.catalog.execute("select * from assets where lower(original_path)='fonts/msjh.ttf'").fetchall()
        if not fonts:
            raise ValueError('Original Chinese font missing')
        font = fonts[0]
        source = library / font['local_path']
        if hashlib.sha256(source.read_bytes()).hexdigest() != font['sha256']:
            raise ValueError('Original font hash mismatch')
        shutil.copyfile(source, output / 'msjh.ttf')
        result = {
            'schema': 'dnf_native_map/1', 'flow_schema': 'dnf_loop_art/1',
            'source': {'asset_version': json.loads(LOCK.read_text(encoding='utf-8'))['version'],
                       'exporter': 'tools/build_dnf_flow_assets.py',
                       'config_role': '111Script backup; effective original runtime unconfirmed',
                       'pixel_policy': 'IMG native RGBA, no resize or substitute images'},
            'coordinates': COORDINATES,
            'constants': {'tile_width': TILE_W, 'tile_height': TILE_H, 'grid_cols': GRID_COLS,
                          'grid_rows': GRID_ROWS, 'cell_width': CELL_W, 'cell_height': CELL_H,
                          'screen_y_offset': 120, 'viewport': [640, 480], 'layers': LAYERS},
            'dungeon': {'rooms': {town_path: town}, 'placements': [
                {'id': 'elvengard', 'map': town_path, 'gates': []}], 'gate_objects': {}},
            'npcs': npc_sources, 'ui': ui, 'font': {'file': 'msjh.ttf', 'sha256': font['sha256'],
                                                  'source': font['original_path']},
            'images': lib.images, 'diagnostics': lib.diags,
            'panel': {'file': 'panel.png', 'size': [40, 35], 'sources': [ui['shop']['0']] + [ui['common'][str(i)] for i in range(9)],
                      'center_crop': [108, 30, 40, 35],
                      'operation': 'Native fragments composed at 1:1; tiled by NinePatchRect, no painted fill'},
            'item_appearance': {'potion': {'path': potion_script['path'], 'sha256': potion_script['sha256'],
                                          'icon': potion_icon}, 'weapons': 'Native katana icons; v1 equipment is E-ADAPT'},
        }
        (output / 'manifest.json').write_text(json.dumps(result, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
        return result
    finally:
        lib.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--output', type=Path, default=OUTPUT)
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text(encoding='utf-8'))
    library = args.library or cache_home() / lock['version'] / 'library_v1'
    output = args.output.resolve()
    if not any(output.is_relative_to(p.resolve()) for p in [ROOT/'temp', ROOT/'game_dnf/assets_local']):
        parser.error('Output must be inside ignored temp/ or assets_local/')
    result = build(library, output)
    print(json.dumps({'output': str(output), 'images': len(result['images']), 'npcs': len(result['npcs'])}))


if __name__ == '__main__':
    main()
