"""检查每个城镇与副本是否都配了 BGM（新场景漏配即失败）。

规范：新增 scene（data/towns.json 的 location）或 dungeon（data/dungeons.json 的 id）时，
必须同时在 data/bgm.json 补映射并跑 `python tools/bake_dnf_bgm.py` 生成曲目。

用法：python tools/check_dnf_bgm.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'


def main() -> int:
    towns = json.loads((GAME / 'data/towns.json').read_text(encoding='utf-8'))['locations']
    dungeons = json.loads((GAME / 'data/dungeons.json').read_text(encoding='utf-8'))
    dungeon_ids = dungeons.get('dungeons', dungeons)
    bgm = json.loads((GAME / 'data/bgm.json').read_text(encoding='utf-8'))
    tracks = bgm.get('tracks', {})
    fails: list[str] = []
    for name in towns:
        key = bgm.get('scenes', {}).get(name, '')
        if key == '':
            fails.append('城镇 %s 没有 BGM 映射（data/bgm.json 的 scenes）' % name)
        elif key not in tracks:
            fails.append('城镇 %s 的曲目 %s 未烘焙' % (name, key))
    for name in dungeon_ids:
        slots = bgm.get('dungeons', {}).get(name)
        if not slots:
            fails.append('副本 %s 没有 BGM 映射（data/bgm.json 的 dungeons）' % name)
            continue
        for slot, key in slots.items():
            if key not in tracks:
                fails.append('副本 %s 的 %s 曲目 %s 未烘焙' % (name, slot, key))
    if 'select' not in bgm.get('screens', {}):
        fails.append('选人界面没有 BGM 映射（data/bgm.json 的 screens.select）')
    if not bgm.get('ambience', {}).get('town'):
        fails.append('城镇环境音缺失（data/bgm.json 的 ambience.town）')
    if fails:
        print('[BGM] FAIL %d' % len(fails))
        for line in fails:
            print('  - ' + line)
        return 1
    print('[BGM] OK 城镇 %d、副本 %d、界面 1、环境音 %d 组全部有映射'
          % (len(towns), len(dungeon_ids), sum(len(v) for v in bgm.get('ambience', {}).values())))
    return 0


if __name__ == '__main__':
    sys.exit(main())
