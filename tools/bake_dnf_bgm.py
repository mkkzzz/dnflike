"""把原版 BGM 与环境音复制进工程，并生成场景映射（不转码，保留原文件字节）。

来源：原版库 catalog 的 kind='audio' 记录。输出：
  game_dnf/assets_local/audio/bgm/*.ogg   曲目原字节
  game_dnf/data/bgm.json                  场景/界面/环境音映射，新副本从原 MAP 与 audio.xml 解析

用法：python tools/bake_dnf_bgm.py [--library DIR]
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import sqlite3
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'assets_local/audio/bgm'
MAP = GAME / 'data/bgm.json'

# 界面：选人/建角
SCREENS = {'select': 'music/characterselectstage.ogg'}
# 城镇（key 与 data/towns.json 的 location 一一对应）
TOWNS = {
    'elvengard': 'music/forest_town.ogg',
    'seria_room': 'music/sera_shop_new.ogg',
    'hendon_city': 'music/hendonmyre_new.ogg',
    'hendon_main': 'music/hendonmyre_new.ogg',
    'hendon_auction': 'music/hendonmyre_new.ogg',
    'hendon_forest_gate': 'music/forest_town.ogg',
    'hendon_alley': 'music/hendonmyre_new.ogg',
    'hendon_pub': 'music/tavern.ogg',
    'hendon_inn': 'music/sera_shop_new.ogg',
    'alfhlyra': 'music/alfhlyra_new.ogg',
    'westcoast': 'music/westcoast_new.ogg',
    'westcoast_magic': 'music/westcoast_new.ogg',
    'westcoast_sky': 'music/westcoast_new.ogg',
}
# 副本（key 与 data/dungeons.json 的 id 对应）。
# 洛兰原版没有独立 BOSS 曲，用森林深处曲代用（E-ADAPT）；其余都有各自的 normal/boss。
DUNGEONS = {
    'lorien': {'normal': 'music/forest01.ogg', 'boss': 'music/forest02.ogg'},
    'lorien_inside': {'normal': 'music/forest01.ogg', 'boss': 'music/forest01.ogg'},
    'forest_trial': {'normal': 'music/forest02.ogg', 'boss': 'music/forest02.ogg'},
    'mirkwood': {'normal': 'music/mirkwood.ogg', 'boss': 'music/mirkwood_boss.ogg'},
    'mirkwood_deep': {'normal': 'music/mirkwood.ogg', 'boss': 'music/mirkwood_boss.ogg'},
    'mirkwood_frost': {'normal': 'music/mirkwood.ogg', 'boss': 'music/mirkwood_boss.ogg'},
    'grakkarak': {'normal': 'music/grakkarak_new.ogg', 'boss': 'music/grakkarak_new_boss.ogg'},
    'grakkarak_burning': {'normal': 'music/grakkarak_new.ogg', 'boss': 'music/grakkarak_new_boss.ogg'},
    'sunderland': {'normal': 'music/sunderland.ogg', 'boss': 'music/sunderland_boss.ogg'},
    'sunderland_poison': {'normal': 'music/sunderland.ogg', 'boss': 'music/sunderland_boss.ogg'},
    'sunderland_dark': {'normal': 'music/sunderland.ogg', 'boss': 'music/sunderland_boss.ogg'},
    'draconiantower': {'normal': 'music/draconian_tower.ogg', 'boss': 'music/draconian_tower_boss.ogg'},
    'draconiantower_amonlow': {'normal': 'music/draconian_tower.ogg', 'boss': 'music/draconian_tower_boss.ogg'},
    'golemtower': {'normal': 'music/golem_tower.ogg', 'boss': 'music/golem_tower_boss.ogg'},
    'floatingcastle': {'normal': 'music/float_castle.ogg', 'boss': 'music/b_float_castle.ogg'},
    'palaceofload': {'normal': 'music/palace_of_load.ogg', 'boss': 'music/palace_of_load_boss.ogg'},
    'hallofdoll': {'normal': 'music/hall_of_doll.ogg', 'boss': 'music/hall_of_doll_boss.ogg'},
    'darkentrance': {'normal': 'music/skycastle.ogg', 'boss': 'music/skycastle_boss.ogg'},
    # act8 阿登高地（无法地带主题）：act8 原生曲未在 music/ 下找到，
    # 暂借 skycastle 系（E-ADAPT，待确认 act8 曲目后替换）。
    'arden': {'normal': 'music/skycastle.ogg', 'boss': 'music/skycastle_boss.ogg'},
    # DGN21 MAP sound list: M_OUTER_TEMPLE, M_BEHEMOTH_BOSS_01_1.
    'outerwall': {'normal': 'music/outer_temple.ogg', 'boss': 'music/behemoth_b01_1.ogg'},
}
# 环境音：与 BGM 叠加的低音量底噪（原版 sounds/amb）
AMBIENCE = {
    'town': ['sounds/amb/amb_town_01.ogg', 'sounds/amb/amb_town_02.ogg', 'sounds/amb/amb_town_03.ogg'],
    'forest': ['sounds/amb/amb_forest_01.ogg', 'sounds/amb/amb_forest_02.ogg'],
}


def music_candidates(keys: list[str], music: dict[str, str],
                     random_music: dict[str, set[str]]) -> set[str]:
    """A MAP sound list can combine ambience and its background track."""
    candidates: set[str] = set()
    for key in keys:
        if key.upper().startswith(('R_AMB_', 'AMB_')):
            continue
        if key in music:
            candidates.add(music[key])
        elif key in random_music:
            candidates.update(random_music[key])
    return candidates


def source_dungeon_tracks(export: dict, rooms: list[dict], music: dict[str, str],
                          random_music: dict[str, set[str]]) -> dict[str, str]:
    dungeon = export['dungeon']
    placements = {p['id']: p['map'] for p in dungeon['placements']}
    tracks = {'normal': Counter(), 'boss': Counter()}
    for room in rooms:
        map_path = placements[room['placement']]
        keys = dungeon['rooms'][map_path].get('sound', [])
        candidates = music_candidates(keys, music, random_music)
        if len(candidates) != 1:
            raise ValueError(f'{map_path}: expected one audio.xml music cue, found {keys}')
        tracks['boss' if room.get('boss') else 'normal'].update(candidates)
    result = {}
    for role, counts in tracks.items():
        ranked = counts.most_common()
        if not ranked or (len(ranked) > 1 and ranked[0][1] == ranked[1][1]):
            raise ValueError(f'{dungeon["path"]}: ambiguous {role} track, found {ranked}')
        result[role] = ranked[0][0]
    return result


def source_native_dungeon_tracks(export: dict, music: dict[str, str],
                                 random_music: dict[str, set[str]]) -> tuple[dict[str, str], dict]:
    tracks = {'normal': Counter(), 'boss': Counter()}
    gaps = {}
    dungeon = export['dungeon']
    if len(dungeon.get('maze_blocks') or []) > 1:
        selected = dungeon['maze_blocks'][dungeon['maze_block_index']]
        fixed = {}
        for row in (selected.get('map_specifications') or []) + (selected.get('boss_map_specifications') or []):
            fixed.setdefault((int(row[0]), int(row[1])), set()).add(int(row[2]))
        start = tuple(dungeon.get('start_map_raw') or [])
        boss = tuple(dungeon.get('boss_map_raw') or [])
        map_paths = []
        for placement in dungeon.get('placements', []):
            map_path = placement['map']
            cell = tuple(placement.get('cell') or [])
            room = dungeon['rooms'][map_path]
            if cell in fixed and int(room['map_id']) not in fixed[cell]:
                continue
            if cell == start and not room.get('start_area'):
                continue
            role = next((str(span['values'][0][2]) for span in room.get('raw', [])
                         if span.get('tag') == '[type]' and span.get('values')
                         and len(span['values'][0]) >= 3), '')
            if cell == boss and role != '[boss]':
                continue
            map_paths.append(map_path)
    else:
        map_paths = sorted(dungeon['rooms'])
    for map_path in map_paths:
        room = dungeon['rooms'][map_path]
        role = ''
        for span in room.get('raw', []):
            if span.get('tag') != '[type]':
                continue
            values = span.get('values') or []
            if len(values) == 1 and len(values[0]) >= 3:
                role = str(values[0][2])
            break
        if role not in ('[normal]', '[boss]'):
            gaps[map_path] = {
                'reason': 'native MAP role is not consumed as a normal or boss room',
                'role': role or None,
                'sound': list(room.get('sound', [])),
            }
            continue
        candidates = music_candidates(room.get('sound', []), music, random_music)
        if not candidates:
            gaps[map_path] = {
                'reason': 'audio.xml has no MUSIC/RANDOM entry for any MAP sound key',
                'sound': list(room.get('sound', [])),
            }
            continue
        tracks['boss' if role == '[boss]' else 'normal'].update(candidates)
    result = {}
    for role, counts in tracks.items():
        ranked = counts.most_common()
        if not ranked or (len(ranked) > 1 and ranked[0][1] == ranked[1][1]):
            raise ValueError(f'{export["dungeon"]["path"]}: ambiguous {role} track, found {ranked}')
        result[role] = ranked[0][0]
    return result, gaps


def dungeon_music_sources(cat, library: Path) -> tuple[dict, dict]:
    routes = json.loads((GAME / 'data/dungeons.json').read_text(encoding='utf-8'))['dungeons']
    missing = sorted(routes.keys() - DUNGEONS.keys())
    if not missing:
        return DUNGEONS, {}
    row = cat.execute("select local_path, sha256 from assets where lower(original_path)='audio.xml'").fetchone()
    if row is None:
        raise ValueError('Original audio.xml required to resolve dungeon music')
    raw = (library / row['local_path']).read_bytes()
    if hashlib.sha256(raw).hexdigest() != row['sha256']:
        raise ValueError('Original audio.xml hash mismatch')
    music = {node.attrib['ID']: node.attrib['FILE'].replace('\\', '/').lower()
             for node in ET.fromstring(raw).findall('MUSIC')}
    random_music = {
        node.attrib['ID']: {
            music[item.attrib['TAG']]
            for item in node.findall('ITEM')
            if item.attrib.get('TAG') in music
        }
        for node in ET.fromstring(raw).findall('RANDOM')
    }
    result = DUNGEONS.copy()
    source_gaps = {}
    for key in missing:
        route = routes[key]
        export_path = route['map_export'].removeprefix('res://')
        export = json.loads((GAME / export_path).read_text(encoding='utf-8'))
        if route.get('mode') == 'native_maze':
            result[key], source_gaps[key] = source_native_dungeon_tracks(export, music, random_music)
            if not source_gaps[key]:
                source_gaps.pop(key)
        else:
            result[key] = source_dungeon_tracks(export, route['rooms'], music, random_music)
    return result, source_gaps


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=None)
    args = parser.parse_args()
    lib = P.open_library(args.library)
    cat = sqlite3.connect(f'file:{lib.path / "catalog.sqlite"}?mode=ro', uri=True)
    cat.row_factory = sqlite3.Row
    OUT.mkdir(parents=True, exist_ok=True)
    tracks: dict[str, dict] = {}
    missing: list[str] = []

    def take(source: str) -> str:
        key = Path(source).stem
        if key in tracks:
            return key
        row = cat.execute("select local_path, sha256, bytes from assets where kind='audio' and lower(original_path)=? order by container limit 1",
                          (source,)).fetchone()
        if row is None:
            missing.append(source)
            return ''
        data = (lib.path / row['local_path']).read_bytes()
        if hashlib.sha256(data).hexdigest() != row['sha256']:
            raise ValueError('音频哈希不一致: ' + source)
        (OUT / (key + '.ogg')).write_bytes(data)
        tracks[key] = {'file': 'audio/bgm/%s.ogg' % key, 'source': source,
                       'sha256': row['sha256'], 'bytes': row['bytes']}
        return key

    try:
        dungeon_sources, source_gaps = dungeon_music_sources(cat, lib.path)
        screens = {name: take(source) for name, source in SCREENS.items()}
        scenes = {name: take(source) for name, source in TOWNS.items()}
        dungeons = {name: {slot: take(source) for slot, source in slots.items()} for name, slots in dungeon_sources.items()}
        ambience = {name: [take(source) for source in sources] for name, sources in AMBIENCE.items()}
    finally:
        cat.close()
        lib.close()
    if missing:
        print('[BGM] 缺少原版音频: ' + ', '.join(missing), file=sys.stderr)
        return 2
    MAP.write_text(json.dumps({
        'schema': 'dnf_bgm/2',
        'evidence': '原版 Music/*.ogg 与 sounds/amb/*.ogg 原字节（E-PARSE）；boss 代用为 E-ADAPT',
        'screens': screens, 'scenes': scenes, 'dungeons': dungeons, 'ambience': ambience,
        'source_gaps': source_gaps, 'tracks': tracks,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('[BGM] tracks=%d screens=%d towns=%d dungeons=%d amb=%d bytes=%d'
          % (len(tracks), len(screens), len(scenes), len(dungeons), sum(len(v) for v in ambience.values()),
             sum(t['bytes'] for t in tracks.values())))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
