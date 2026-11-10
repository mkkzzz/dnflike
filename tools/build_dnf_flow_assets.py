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
from export_dnf_map import (Library, export_map, plain, span_values, resolve, COORDINATES,
                            TILE_W, TILE_H, CELL_W, CELL_H, GRID_COLS, GRID_ROWS, LAYERS)

OUTPUT = ROOT / 'game_dnf/assets_local/flow_v1'
SHORTCUT_OUTPUT = OUTPUT / 'skill_shortcut_v1'
SHORTCUT_KEYS = 'ASDFGHQWERTY'
# Original VK dispatch 11C0920 through the hotkey load at 4D66E8/4D6761.
SHORTCUT_KEY_FRAMES = (55, 73, 58, 60, 61, 62, 71, 77, 59, 72, 74, 79)
SELECTOR_PACKS = {
    'lorien': ('worldmap/lorien.wdm', OUTPUT / 'dungeon_selector_v1'),
    'granfloris': ('worldmap/granfloris.wdm', OUTPUT / 'dungeon_selector_gran_v1'),
    'skytower': ('worldmap/skycastle.wdm', OUTPUT / 'dungeon_selector_sky_v1'),
}
SKY_CARD_BANK = 'worldmap/selectdungeonslot/skycastle.img'
SKY_CARD_BANK_SHA = '8b91efb5a16dcaa38d2e83cb97ab2743c149fff46a9589c97188543079bd7409'
ERROR_IMAGE_SHA = '987c3569cc48c257842e011c4747ce4f51f0f3337b75bc283deea84208ba0685'


def build_skill_shortcut(library: Path, output: Path) -> dict:
    """Export the original extended cell and default key glyphs at native size."""
    lib = Library(library, output)
    try:
        path = 'clientonly/hotkeysystem.co'
        hotkeys = lib.script(path)
        if not hotkeys or not hotkeys['crc_ok']:
            raise ValueError('Missing verified original hotkey definitions')
        records = [plain(span['values']) for span in hotkeys['spans'] if span['tag'] == '[key]']
        default_keys = {row[1]: row[4] for row in records if row[2] == 'dungeon'}
        if [default_keys.get(index) for index in range(20, 32)] != list(map(ord, SHORTCUT_KEYS)):
            raise ValueError('Original shortcut definitions disagree with the verified key dispatch')
        extra_slot = lib.image('Interface/ExSkillQuickSlot.img', 0, 'extended skill shortcut')
        glyphs = {key: lib.image('Interface/keyshortcut.img', frame, 'shortcut key ' + key)
                  for key, frame in zip(SHORTCUT_KEYS, SHORTCUT_KEY_FRAMES, strict=True)}
        if (extra_slot is None or lib.images[extra_slot]['size'] != [28, 28]
                or lib.images[extra_slot]['canvas_offset'] != [0, 0] or None in glyphs.values()):
            raise ValueError('Missing original shortcut frame or glyph')
        result = {
            'schema': 'dnf_native_map/1', 'shortcut_schema': 'dnf_skill_shortcut/1',
            'source': {'hotkeys': path, 'sha256': hotkeys['sha256'],
                       'engine_sha256': '187ad34ab6bfff040d9b12bb145bdda0bba29f82aaa41183280b0ae42e914b84',
                       'slot_geometry': 'EXERESX 0x4CDC98/0x4CDD3D/0x11B4030',
                       'draw': 'EXERESX 0x4C0B30/0x4B3370/0x4B33CC',
                       'key_dispatch': 'EXERESX 0x4D66E8/0x11C0920/0x4D6761/0x4D3F50'},
            'extra_slot': extra_slot, 'glyphs': glyphs, 'images': lib.images,
        }
        (output / 'manifest.json').write_text(json.dumps(result, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
        return result
    finally:
        lib.close()


def build_dungeon_selector(library: Path, output: Path, region: str = 'lorien') -> dict:
    """Compile source cards for existing runtime dungeons without adding routes."""
    game = ROOT / 'game_dnf'
    dungeons = json.loads((game / 'data/dungeons.json').read_text(encoding='utf-8'))['dungeons']
    lib = Library(library, output)
    try:
        sources = {}

        def spans(path: str) -> list[dict]:
            data = lib.script(path)
            if not data or not data['crc_ok'] or not data['spans']:
                raise ValueError('Missing verified selector source: ' + path)
            sources[path] = data['sha256']
            return data['spans']

        def image(path: str, frame: int) -> str:
            key = lib.image(path, frame, 'dungeon selector')
            if key is None:
                raise ValueError(f'Missing selector image: {path} frame {frame}')
            return key

        table = {int(s['tag'][1:-1]): plain(s['values']) for s in spans('worldmap/worldmappatterntable2nd.tbl')}
        listing_path = 'dungeon/dungeon.lst'
        listing_sha, listing_crc_ok = lib.config.execute('select sha256,crc_ok from files where path=?', (listing_path,)).fetchone()
        if not listing_crc_ok:
            raise ValueError('Invalid source dungeon listing CRC')
        sources[listing_path] = listing_sha
        listing = lib.listing(listing_path)
        wdm_path, _ = SELECTOR_PACKS[region]
        wdm = spans(wdm_path)
        ui_path, = span_values(wdm, '[ui path]')
        controls = [plain(s['values']) for s in spans(ui_path.lower()) if s['tag'] == '[ui controls]']
        wdm_background, wdm_frame = span_values(wdm, '[map image]')
        background_control = next(v for v in controls if v[1] == 'IDC_WORLDMAP_BACKGROUND')
        background, frame = background_control[5], background_control[7]
        if background_control[0] != '[image]' or background_control[2:4] != [0, 0]:
            raise ValueError(f'Unsupported {region} background control')
        balloons = {v[9]: v for v in controls if v[0] == '[balloon]' and len(v) == 10}
        listed = span_values(wdm, '[dungeon]')[::2]
        cards = {}
        for key, spec in dungeons.items():
            if spec.get('legacy') or spec.get('region', 'lorien') != region:
                continue
            route = json.loads((game / spec['map_export'].removeprefix('res://')).read_text(encoding='utf-8'))['dungeon']
            index = route['index']
            ui_only = (region, key, index) == ('skytower', 'draconiantower_amonlow', 19)
            if index not in balloons or (index not in listed and not ui_only):
                raise ValueError(f'{key} is missing its original WDM or UI slot')
            dgn_path = resolve(listing_path, listing[index])
            dgn = spans(dgn_path)
            if (route['path'], route['sha256']) != (dgn_path, sources[dgn_path]):
                raise ValueError(f'{key} disagrees with the original DGN identity')
            pattern = span_values(dgn, '[worldmap pattern info]')
            if len(pattern) != 4:
                raise ValueError(f'{key} has an unsupported original card record')
            minimum_level = span_values(dgn, '[minimum required level]')
            if not minimum_level or len(minimum_level) != 1 or not isinstance(minimum_level[0], int):
                raise ValueError(f'{key} is missing its original minimum level for keyboard ordering')
            _, control, x, y, _, connector_bank, _, _, ui_pattern, _ = balloons[index]
            offsets = table[ui_pattern]
            compact, expanded, connector = ([x + dx, y + dy] for dx, dy in zip(offsets[::2], offsets[1::2], strict=True))
            if ui_only and (control, pattern[0], pattern[1], pattern[2].lower(), pattern[3]) != (
                    'IDC_WORLDMAP_BUTTON1', 2, 1, SKY_CARD_BANK, 7):
                raise ValueError(f'{key} disagrees with the verified UI-only slot')
            card = lib.image(pattern[2], pattern[3], key) if ui_only else image(pattern[2], pattern[3])
            missing_card = card is None
            if missing_card:
                source = lib.images[image(SKY_CARD_BANK, 0)]
                if source['img_sha256'] != SKY_CARD_BANK_SHA:
                    raise ValueError(f'{key} is missing its verified original card bank')
                # GetImage bounds failure returns the engine error image, Base.img#91.
                card = image('Interface/Base.img', 91)
                fallback = lib.images[card]
                if fallback['img_sha256'] != ERROR_IMAGE_SHA or fallback['size'] != [1, 1]:
                    raise ValueError(f'{key} has an unexpected original error image')
            cards[key] = {'dgn_index': index, 'dgn': dgn_path, 'control': control,
                          'anchor': [x, y], 'ui_pattern': ui_pattern, 'dgn_pattern': pattern,
                          'compact': compact, 'expanded': expanded, 'connector': connector,
                          'card': card, 'connector_image': image(connector_bank, 30 + ui_pattern),
                          'minimum_required_level': minimum_level[0]}
            if missing_card:
                cards[key]['missing_card_frame'] = True
        # Normal client navigation sorts by this DGN field. Equal levels need the
        # server's active DGN list order, which is unnecessary for these distinct levels.
        levels = {key: card['minimum_required_level'] for key, card in cards.items()}
        if len(set(levels.values())) != len(levels):
            raise ValueError(f'{region} needs its original active list order for tied keyboard levels')
        keyboard_order = sorted(levels, key=levels.__getitem__)
        layout = {'wdm': wdm_path, 'ui': ui_path.lower(), 'background': image(background, frame),
                  'cards': cards, 'keyboard_order': keyboard_order}
        if (background.lower(), frame) != (wdm_background.lower(), wdm_frame):
            # Normal selection loads the WDM [ui path] into the visible UI tree.
            layout['background_control'] = background_control
            layout['wdm_background'] = [wdm_background, wdm_frame]
            layout['background_consumer'] = 'EXERESX 0x110F801/0x105D1B0/0x105A010'
        if any(card.get('missing_card_frame') for card in cards.values()):
            layout['missing_frame_consumer'] = 'EXERESX 0x11AA190/0x11B0330/0x6FD626'

        result = {'schema': 'dnf_native_map/1', 'selector_schema': 'dnf_dungeon_selector/1',
                  'source': {'files': sources, 'dungeon_listing': listing_path,
                             'layout_consumer': 'EXERESX 0x106DBBD/0x106D630/0x106CF40',
                             'engine_sha256': '187ad34ab6bfff040d9b12bb145bdda0bba29f82aaa41183280b0ae42e914b84'},
                  'regions': {region: layout}, 'images': lib.images}
        (output / 'manifest.json').write_text(json.dumps(result, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
        return result
    finally:
        lib.close()


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
            'hud': ('Interface2/HUD/HUD.img', list(range(20)) + [21, 30, 31, 32, 37, 45, 68, 69, 70]),
            'common': ('Interface/WindowCommon.img', list(range(29)) + list(range(66, 70)) + [90, 91, 92, 97, 98, 99, 100, 101, 102, 103, 104, 105, 147, 213, 214, 215, 216, 217, 218, 219, 220, 221, 230, 248]),
            'inventory': ('Interface/newstyle/windows/inventory/fuck_1.img', [0, 1, 2, 13, 14, 21, 38, 49]),
            'inventory_grid': ('Interface/ItemInventoryWindow.img', [0]),
            'inventory_bottom': ('Interface/newstyle/windows/inventory/Inventory_tw.img', [0, 1, 4, 5, 7]),
            'equipment': ('Interface/newstyle/windows/inventory/inventory.img', [19, 20, 21, 22]),
            'shop': ('Interface/StackableShopWindow.img', [0, 7, 8, 9, 10, 11, 12, 13]),
            'base': ('Interface/Base.img', [36, 50, 64, 67, 84, 119]),
            'status_icon': ('Interface/Status_Icon.img', [0]),
            'close': ('Interface/commonbtn01.img', [4, 5, 6]),
            'dialog': ('Interface2/npc_dialogue_ui.img', [0, 20]),
            'dialog_face': ('Interface/npc_dialog_face.img', [0]),
            'tooltip': ('Interface/Global.img', list(range(12))),
            'quest': ('Interface/newstyle/windows/quest.img', list(range(20))),
            'quest_list': ('Interface/quest/reformquestwindow.img', [0, 2, 3, 4, 5, 9, 10]),
            'portrait': ('Map/Npc/NpcFace01.img', [8, 9]),
            'result': ('Interface/NewResult/Result.img', [3, 6, 7, 8, 12, 137]),
            'reward': ('Interface2/reward_ver2.0/reward_ver2.img', [33, 34, 35, 36, 41, 42, 43, 45, 46, 47, 60, 61, 82, 84, 94, 95, 96, 97]),
            'select': ('WorldMap/SelectDungeon02_cn.img', [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 22, 23, 58, 79, 91, 105, 164, 165, 166]),
            'worldmap': ('WorldMap/granfloris.img', [0]),
            'dungeon_cards': ('WorldMap/SelectDungeonSlot/granfloris.img', list(range(9))),
            'skill_icons': ('Character/Swordman/Effect/SkillIcon.img', [8, 9, 24, 25, 94, 95, 336, 337]),
            'lorien': ('Map/CutScene/Lorien.img', [0]),
            'characters': ('Interface2/SelectCharacter/SelectCharacter.img', [0, 1, 3, 6, 7, 8, 9, 10, 11, 12, 17]),
            'character_create': ('Interface2/CharacterCreate/CharacterCreate.img', [0, 5, 6, 38]),
        }
        ui = {name: {str(n): lib.image(ref, n, 'flow/' + name) for n in frames}
              for name, (ref, frames) in refs.items()}
        skill_sources = {}
        ui['active_skills'] = {}
        for key, filename in {'hardattack': 'hardattack', 'draw': 'momentaryslash',
                              'triple': 'tripleslash', 'rage_slash': 'gorecross',
                              'buff': 'frenzy', 'guard': 'guard',
                              'moonlight': 'moonlightslash',
                              'charge_crash': 'chargecrash'}.items():
            script = lib.script('skill/swordman/' + filename + '.skl')
            icon = span_values(script['spans'], '[icon]')
            ui['active_skills'][key] = lib.image(icon[0], icon[1], 'flow/active_skills')
            skill_sources[key] = {'path': script['path'], 'sha256': script['sha256'], 'icon': icon}
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
        # Original board edges plus a native opaque grain patch; original
        # dialogue/inventory/map/reward families retain their separate surfaces.
        shop_image = Image.open(output / lib.images[ui['shop']['0']]['file']).convert('RGBA')
        panel = shop_image.crop((108, 30, 148, 65))
        pieces = [Image.open(output / lib.images[ui['common'][str(i)]]['file']) for i in range(9)]
        # Fill each complete edge: tiling a short assembled bottom leaves teeth
        # of transparent gaps when NinePatch repeats the incomplete middle.
        for x in range(11, 29):
            panel.paste(pieces[1].crop((5, 0, 6, 11)), (x, 0))
            panel.paste(pieces[7].crop((5, 0, 6, 11)), (x, 24))
        for i, at in [(0, (0, 0)), (2, (26, 0)), (3, (0, 11)),
                      (5, (29, 11)), (6, (0, 24)), (8, (29, 24))]:
            panel.paste(pieces[i].convert('RGBA'), at)
        panel.save(output / 'panel.png')
        tooltip = Image.new('RGBA', (24, 25))
        for n, at in [(0, (0, 0)), (1, (6, 0)), (2, (18, 0)),
                      (4, (0, 6)), (5, (6, 6)), (6, (18, 6)),
                      (8, (0, 19)), (9, (6, 19)), (10, (18, 19))]:
            tooltip.paste(Image.open(output / lib.images[ui['tooltip'][str(n)]]['file']).convert('RGBA'), at)
        tooltip.save(output / 'tooltip.png')
        fonts = lib.catalog.execute("select * from assets where lower(original_path)='fonts/msjh.ttf'").fetchall()
        if not fonts:
            raise ValueError('Original Chinese font missing')
        font = fonts[0]
        source = library / font['local_path']
        if hashlib.sha256(source.read_bytes()).hexdigest() != font['sha256']:
            raise ValueError('Original font hash mismatch')
        shutil.copyfile(source, output / 'msjh.ttf')
        result = {
            'schema': 'dnf_native_map/1', 'flow_schema': 'dnf_loop_art/8',
            'source': {'asset_version': json.loads(LOCK.read_text(encoding='utf-8'))['version'],
                       'exporter': 'tools/build_dnf_flow_assets.py',
                       'config_role': '111Script backup; effective original runtime unconfirmed',
                       'pixel_policy': 'IMG native RGBA, no resize or substitute images'},
            'coordinates': COORDINATES,
            'constants': {'tile_width': TILE_W, 'tile_height': TILE_H, 'grid_cols': GRID_COLS,
                          'grid_rows': GRID_ROWS, 'cell_width': CELL_W, 'cell_height': CELL_H,
                          'screen_y_offset': 120, 'viewport': [800, 600], 'layers': LAYERS},
            'dungeon': {'rooms': {town_path: town}, 'placements': [
                {'id': 'elvengard', 'map': town_path, 'gates': []}], 'gate_objects': {}},
            'npcs': npc_sources, 'ui': ui, 'font': {'file': 'msjh.ttf', 'sha256': font['sha256'],
                                                  'source': font['original_path']},
            'images': lib.images, 'diagnostics': lib.diags,
            'skill_icon_sources': skill_sources,
            'panel': {'file': 'panel.png', 'size': [40, 35], 'sources': [ui['shop']['0']] + [ui['common'][str(i)] for i in range(9)],
                      'center_crop': [108, 30, 40, 35],
                      'operation': 'Native fragments composed at 1:1; tiled by NinePatchRect, no painted fill'},
            'tooltip': {'file': 'tooltip.png', 'size': [24, 25], 'margins': [6, 6, 6, 6],
                        'sources': [ui['tooltip'][str(i)] for i in [0, 1, 2, 4, 5, 6, 8, 9, 10]],
                        'operation': 'Native translucent black/gold Global frame at 1:1'},
            'item_appearance': {'potion': {'path': potion_script['path'], 'sha256': potion_script['sha256'],
                                          'icon': potion_icon, 'rarity': span_values(potion_script['spans'], '[rarity]')},
                                'weapons': 'Native katana icons; v1 equipment is E-ADAPT',
                                'rarity_frame': {'source': ui['base']['119'], 'operation': 'Native neutral outline with runtime rarity tint; exact original frame use and palette not certified'}},
        }
        result['ui_layout_sources'] = [lib.script(path) for path in [
            'ui/hud/hud.ui', 'ui/inventory/iteminventorywindow.ui',
            'ui/inventory/inventory_item.ui', 'ui/inventory/inventory_bottom.ui',
            'data/ui/newresult.sd', 'ui/selectcharacter/selectcharacterunder.ui',
            'ui/selectcharacter/selectcharacterover.ui']]
        (output / 'manifest.json').write_text(json.dumps(result, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
        return result
    finally:
        lib.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--output', type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--dungeon-selector-only', action='store_true', help='Export the verified world-map UI pack only')
    mode.add_argument('--skill-shortcut-only', action='store_true', help='Export the verified skill shortcut HUD pack only')
    parser.add_argument('--dungeon-selector-region', choices=SELECTOR_PACKS, default='lorien')
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text(encoding='utf-8'))
    library = args.library or cache_home() / lock['version'] / 'library_v1'
    selector_output = SELECTOR_PACKS[args.dungeon_selector_region][1]
    default_output = OUTPUT
    if args.dungeon_selector_only:
        default_output = selector_output
    if args.skill_shortcut_only:
        default_output = SHORTCUT_OUTPUT
    output = (args.output or default_output).resolve()
    if not any(output.is_relative_to(p.resolve()) for p in [ROOT/'temp', ROOT/'game_dnf/assets_local']):
        parser.error('Output must be inside ignored temp/ or assets_local/')
    if args.dungeon_selector_only:
        if output != selector_output.resolve() and not output.is_relative_to((ROOT / 'temp').resolve()):
            parser.error('Selector output must be under temp/ or in its dedicated resource pack')
        result = build_dungeon_selector(library, output, args.dungeon_selector_region)
        print(json.dumps({'output': str(output), 'regions': len(result['regions']), 'images': len(result['images'])}))
        return
    if args.skill_shortcut_only:
        if output != SHORTCUT_OUTPUT.resolve() and not output.is_relative_to((ROOT / 'temp').resolve()):
            parser.error('Skill shortcut output must be under temp/ or in its dedicated resource pack')
        result = build_skill_shortcut(library, output)
        print(json.dumps({'output': str(output), 'images': len(result['images'])}))
        return
    result = build(library, output)
    print(json.dumps({'output': str(output), 'images': len(result['images']), 'npcs': len(result['npcs'])}))


if __name__ == '__main__':
    main()
