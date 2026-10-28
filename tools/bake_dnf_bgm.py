"""把原版 BGM 复制进工程并生成场景映射（不转码，保留原文件字节）。

来源：原版库 catalog 的 kind='audio' 记录（`Music/*.ogg`），按场景复制到
`game_dnf/assets_local/audio/bgm/`，映射与哈希写入 `game_dnf/data/bgm.json`。

用法：python tools/bake_dnf_bgm.py [--library DIR]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'assets_local/audio/bgm'
MAP = GAME / 'data/bgm.json'

# 场景 → 原版曲目（60 版命名：森林城镇 forest_town、赫顿 hendonmyre_new、赛丽亚 sera_shop_new）
SCENES = {
    'elvengard': 'music/forest_town.ogg',
    'seria_room': 'music/sera_shop_new.ogg',
    'hendon_city': 'music/hendonmyre_new.ogg',
    'hendon_main': 'music/hendonmyre_new.ogg',
    'hendon_auction': 'music/hendonmyre_new.ogg',
    'hendon_forest_gate': 'music/forest_town.ogg',
    'hendon_alley': 'music/hendonmyre_new.ogg',
    'lorien': 'music/forest01.ogg',
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
    try:
        for scene, source in SCENES.items():
            row = cat.execute("select local_path, sha256, bytes from assets where kind='audio' and lower(original_path)=? order by container limit 1",
                              (source,)).fetchone()
            if row is None:
                print('[BGM] 缺少 ' + source, file=sys.stderr)
                return 2
            key = Path(source).stem
            if key in tracks:
                tracks[key]['scenes'].append(scene)
                continue
            data = (lib.path / row['local_path']).read_bytes()
            if hashlib.sha256(data).hexdigest() != row['sha256']:
                raise ValueError('BGM hash mismatch: ' + source)
            target = OUT / (key + '.ogg')
            target.write_bytes(data)
            tracks[key] = {'file': 'audio/bgm/%s.ogg' % key, 'source': source,
                           'sha256': row['sha256'], 'bytes': row['bytes'], 'scenes': [scene]}
    finally:
        cat.close()
        lib.close()
    mapping = {scene: next(key for key, entry in tracks.items() if scene in entry['scenes']) for scene in SCENES}
    MAP.write_text(json.dumps({'schema': 'dnf_bgm/1', 'evidence': '原版 Music/*.ogg 原字节，E-PARSE',
                               'scenes': mapping, 'tracks': tracks}, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('[BGM] tracks=%d scenes=%d bytes=%d' % (len(tracks), len(mapping), sum(t['bytes'] for t in tracks.values())))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
