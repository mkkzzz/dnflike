"""校验副本配置：路线与实际地图导出是否自洽、每个城镇入口能否选到副本。

检查项：
  ① 每个非 legacy 副本的 `map_export` 存在，且 rooms 里的 placement 都在导出里；
  ② 每间房的 `next` 方向在该房的门列表里（除 boss 房）；
  ③ 有副本入口的城镇，按 `session.dungeon_choices` 同一规则（region 缺省 lorien）能选到副本；
  ④ 副本的 requires 任务必须存在于 data/quests.json。

用法：python tools/check_dnf_dungeons.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
DEFAULT_REGION = 'lorien'   # 与 session.dungeon_choices 的缺省值一致


def main() -> int:
    dungeons = json.loads((GAME / 'data/dungeons.json').read_text(encoding='utf-8'))['dungeons']
    towns = json.loads((GAME / 'data/towns.json').read_text(encoding='utf-8'))['locations']
    quests = {q['id'] for q in json.loads((GAME / 'data/quests.json').read_text(encoding='utf-8'))['quests']}
    fails: list[str] = []
    playable = 0
    rooms_total = 0
    for name, spec in dungeons.items():
        region = spec.get('region', DEFAULT_REGION)
        print('== %-14s region=%-11s rooms=%-2d requires=%s min_level=%s'
              % (name, region, len(spec.get('rooms', [])), spec.get('requires'), spec.get('min_level')))
        for need in spec.get('requires', []):
            if need not in quests:
                fails.append('%s 的前置任务 %s 不存在' % (name, need))
        if spec.get('legacy'):
            print('   legacy 样板，跳过路线校验')
            continue
        export = spec.get('map_export', '')
        path = GAME / export.replace('res://', '')
        if not export or not path.is_file():
            fails.append('%s 的地图导出缺失：%s' % (name, export or '(空)'))
            continue
        data = json.loads(path.read_text(encoding='utf-8'))
        placements = {p['id']: p for p in data['dungeon']['placements']}
        playable += 1
        for index, room in enumerate(spec.get('rooms', [])):
            rooms_total += 1
            pid = room['placement']
            found = placements.get(pid)
            if not found:
                fails.append('%s 第 %d 房 %s 不在 %s 里' % (name, index, pid, export))
                continue
            need = room.get('next', '')
            if not need:
                continue
            directions = [g['direction'] for g in found['gates']]
            if need not in directions:
                fails.append('%s 第 %d 房 %s 的 next=%s 无对应门（有 %s）' % (name, index, pid, need, directions))
    print('\n== 城镇入口')
    for town, loc in towns.items():
        if not loc.get('dungeon_entry'):
            continue
        region = loc.get('dungeon_region', DEFAULT_REGION)
        choices = [d for d, s in dungeons.items()
                   if not s.get('legacy') and s.get('region', DEFAULT_REGION) == region]
        print('   %-20s region=%-11s choices=%s' % (town, region, choices))
        if not choices:
            fails.append('城镇 %s 有副本入口但选不到任何副本（region=%s）' % (town, region))
    print('\n[DUGEONS] 可玩副本 %d 个、房间 %d 间' % (playable, rooms_total))
    if fails:
        print('[DUGEONS] FAIL %d' % len(fails))
        for line in fails:
            print('  - ' + line)
        return 1
    print('[DUGEONS] OK 路线、门、入口与前置任务全部自洽')
    return 0


if __name__ == '__main__':
    sys.exit(main())
