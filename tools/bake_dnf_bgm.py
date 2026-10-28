"""把原版 BGM 与环境音复制进工程，并生成场景映射（不转码，保留原文件字节）。

来源：原版库 catalog 的 kind='audio' 记录。输出：
  game_dnf/assets_local/audio/bgm/*.ogg   曲目原字节
  game_dnf/data/bgm.json                  场景/界面/环境音映射（新场景只需在此加一行）

用法：python tools/bake_dnf_bgm.py [--library DIR]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
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
}
# 副本（key 与 data/dungeons.json 的 id 对应）；boss 曲为 E-ADAPT：原版洛兰无独立 BOSS 曲，用森林深处曲代用
DUNGEONS = {
    'lorien': {'normal': 'music/forest01.ogg', 'boss': 'music/forest02.ogg'},
    'lorien_inside': {'normal': 'music/forest01.ogg', 'boss': 'music/forest01.ogg'},
    'forest_trial': {'normal': 'music/forest02.ogg', 'boss': 'music/forest02.ogg'},
    'mirkwood': {'normal': 'music/forest02.ogg', 'boss': 'music/forest02.ogg'},
    'mirkwood_deep': {'normal': 'music/forest02.ogg', 'boss': 'music/forest02.ogg'},
}
# 环境音：与 BGM 叠加的低音量底噪（原版 sounds/amb）
AMBIENCE = {
    'town': ['sounds/amb/amb_town_01.ogg', 'sounds/amb/amb_town_02.ogg', 'sounds/amb/amb_town_03.ogg'],
    'forest': ['sounds/amb/amb_forest_01.ogg', 'sounds/amb/amb_forest_02.ogg'],
}


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
        screens = {name: take(source) for name, source in SCREENS.items()}
        scenes = {name: take(source) for name, source in TOWNS.items()}
        dungeons = {name: {slot: take(source) for slot, source in slots.items()} for name, slots in DUNGEONS.items()}
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
