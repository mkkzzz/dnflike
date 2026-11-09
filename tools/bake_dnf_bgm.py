"""把原版 BGM 与环境音复制进工程，并生成场景映射（不转码，保留原文件字节）。

来源：原版库 catalog 的 kind='audio' 记录。输出：
  game_dnf/assets_local/audio/bgm/*.ogg   曲目原字节
  game_dnf/data/bgm.json                  场景/界面/环境音映射，新副本从原 MAP 与 audio.xml 解析

用法：python tools/bake_dnf_bgm.py [--library DIR]
"""
from __future__ import annotations

import argparse
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
}
# 环境音：与 BGM 叠加的低音量底噪（原版 sounds/amb）
AMBIENCE = {
    'town': ['sounds/amb/amb_town_01.ogg', 'sounds/amb/amb_town_02.ogg', 'sounds/amb/amb_town_03.ogg'],
    'forest': ['sounds/amb/amb_forest_01.ogg', 'sounds/amb/amb_forest_02.ogg'],
}


def source_dungeon_tracks(export: dict, rooms: list[dict], music: dict[str, str]) -> dict[str, str]:
    dungeon = export['dungeon']
    placements = {p['id']: p['map'] for p in dungeon['placements']}
    tracks = {'normal': set(), 'boss': set()}
    for room in rooms:
        map_path = placements[room['placement']]
        keys = dungeon['rooms'][map_path].get('sound', [])
        candidates = {music[key] for key in keys if key in music}
        if len(candidates) != 1:
            raise ValueError(f'{map_path}: expected one audio.xml music cue, found {keys}')
        tracks['boss' if room.get('boss') else 'normal'].update(candidates)
    for role, candidates in tracks.items():
        if len(candidates) != 1:
            raise ValueError(f'{dungeon["path"]}: expected one {role} track, found {sorted(candidates)}')
    return {role: next(iter(candidates)) for role, candidates in tracks.items()}


def dungeon_music_sources(cat, library: Path) -> dict:
    routes = json.loads((GAME / 'data/dungeons.json').read_text(encoding='utf-8'))['dungeons']
    missing = sorted(routes.keys() - DUNGEONS.keys())
    if not missing:
        return DUNGEONS
    row = cat.execute("select local_path, sha256 from assets where lower(original_path)='audio.xml'").fetchone()
    if row is None:
        raise ValueError('Original audio.xml required to resolve dungeon music')
    raw = (library / row['local_path']).read_bytes()
    if hashlib.sha256(raw).hexdigest() != row['sha256']:
        raise ValueError('Original audio.xml hash mismatch')
    music = {node.attrib['ID']: node.attrib['FILE'].replace('\\', '/').lower()
             for node in ET.fromstring(raw).findall('MUSIC')}
    result = DUNGEONS.copy()
    for key in missing:
        route = routes[key]
        export_path = route['map_export'].removeprefix('res://')
        export = json.loads((GAME / export_path).read_text(encoding='utf-8'))
        result[key] = source_dungeon_tracks(export, route['rooms'], music)
    return result


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
        dungeon_sources = dungeon_music_sources(cat, lib.path)
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
        'screens': screens, 'scenes': scenes, 'dungeons': dungeons, 'ambience': ambience, 'tracks': tracks,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('[BGM] tracks=%d screens=%d towns=%d dungeons=%d amb=%d bytes=%d'
          % (len(tracks), len(screens), len(scenes), len(dungeons), sum(len(v) for v in ambience.values()),
             sum(t['bytes'] for t in tracks.values())))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
