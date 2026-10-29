"""副本配置契约校验：新增副本只要通过这里，运行时就不需要逐副本用例。

校验项（都会让运行时崩或走不通）：
  ① map_export 存在、rooms 非空、placement 唯一且都在导出里；
  ② 每间房的地图数据自洽：walk_grid 行数 = grid_rows、列数 = 格数、width = 列数 × tile_width、tiles 每列有图；
  ③ 首房必须有 start_area；每间房的怪物锚点完整；
  ④ 非 BOSS 房的 `next` 方向必须有对应门；门的朝向只能是上下左右；
  ⑤ BOSS 房存在且只有一间，并且是最后一间；
  ⑥ requires 里的任务必须存在；min_level/monster_level 在 1..level_cap；
  ⑦ 每个副本至少能被一个带副本入口的城镇选到（region 缺省 lorien）。

用法：python tools/check_dnf_dungeons.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
DEFAULT_REGION = 'lorien'   # 与 session.dungeon_choices 的缺省值一致
DIRECTIONS = {'left', 'right', 'up', 'down'}


def main() -> int:
    dungeons = json.loads((GAME / 'data/dungeons.json').read_text(encoding='utf-8'))['dungeons']
    towns = json.loads((GAME / 'data/towns.json').read_text(encoding='utf-8'))['locations']
    quests = {q['id'] for q in json.loads((GAME / 'data/quests.json').read_text(encoding='utf-8'))['quests']}
    level_cap = int(json.loads((GAME / 'data/numbers.json').read_text(encoding='utf-8'))['progression']['level_cap'])
    fails: list[str] = []
    playable = 0
    rooms_total = 0
    covered: dict[str, list[str]] = {}

    for name, spec in dungeons.items():
        region = spec.get('region', DEFAULT_REGION)
        rooms = spec.get('rooms', [])
        print('== %-14s region=%-11s rooms=%-2d requires=%s min_level=%s'
              % (name, region, len(rooms), spec.get('requires'), spec.get('min_level')))
        for need in spec.get('requires', []):
            if need not in quests:
                fails.append('%s: 前置任务 %s 不存在' % (name, need))
        for key in ('min_level', 'monster_level'):
            value = spec.get(key)
            if value is not None and not (1 <= int(value) <= level_cap):
                fails.append('%s: %s=%s 超出 1..%d' % (name, key, value, level_cap))
        if spec.get('legacy'):
            print('   legacy 样板，跳过路线校验')
            continue
        export = spec.get('map_export', '')
        path = GAME / export.replace('res://', '')
        if not export or not path.is_file():
            fails.append('%s: 地图导出缺失 %s' % (name, export or '(空)'))
            continue
        if not rooms:
            fails.append('%s: 没有任何房间' % name)
            continue
        data = json.loads(path.read_text(encoding='utf-8'))
        constants = data['constants']
        cell_cols = int(constants['grid_cols'])
        grid_rows = int(constants['grid_rows'])
        tile_width = int(constants['tile_width'])
        placements = {p['id']: p for p in data['dungeon']['placements']}
        playable += 1
        boss_rooms = [i for i, r in enumerate(rooms) if r.get('boss')]
        if not boss_rooms:
            fails.append('%s: 没有 BOSS 房，结算无法触发' % name)
        elif len(boss_rooms) > 1:
            fails.append('%s: BOSS 房不止一间 %s' % (name, boss_rooms))
        elif boss_rooms[0] != len(rooms) - 1:
            fails.append('%s: BOSS 房必须排在最后一间' % name)
        seen_ids: set[str] = set()
        for index, room in enumerate(rooms):
            rooms_total += 1
            pid = room['placement']
            if pid in seen_ids:
                fails.append('%s: 第 %d 房 placement %s 重复' % (name, index, pid))
            seen_ids.add(pid)
            found = placements.get(pid)
            if not found:
                fails.append('%s: 第 %d 房 %s 不在 %s 里' % (name, index, pid, export))
                continue
            map_room = data['dungeon']['rooms'].get(found['map'])
            if map_room is None:
                fails.append('%s: 第 %d 房 %s 的地图 %s 不存在' % (name, index, pid, found['map']))
                continue
            tiles = [t for t in map_room.get('tiles', []) if t.get('image')]
            columns = len({t['column'] for t in tiles})
            grid = map_room.get('walk_grid') or []
            if not tiles:
                fails.append('%s: 第 %d 房 %s 没有地砖' % (name, index, pid))
            if len(grid) != grid_rows:
                fails.append('%s: 第 %d 房 %s walk_grid 行数 %d != %d' % (name, index, pid, len(grid), grid_rows))
            elif columns and len(grid[0]) != columns * cell_cols:
                fails.append('%s: 第 %d 房 %s walk_grid 列数 %d != %d' % (name, index, pid, len(grid[0]), columns * cell_cols))
            if columns and int(map_room.get('width', 0)) != columns * tile_width:
                fails.append('%s: 第 %d 房 %s width %s != %d' % (name, index, pid, map_room.get('width'), columns * tile_width))
            if index == 0 and not map_room.get('start_area'):
                fails.append('%s: 首房 %s 缺少出生区域 start_area' % (name, pid))
            for monster in map_room.get('monsters', []):
                if len(monster.get('anchor') or []) < 3:
                    fails.append('%s: 第 %d 房 %s 有怪物锚点不完整' % (name, index, pid))
            gates = found.get('gates') or []
            for gate in gates:
                if gate.get('direction') not in DIRECTIONS:
                    fails.append('%s: 第 %d 房 %s 门方向非法 %s' % (name, index, pid, gate.get('direction')))
            need = room.get('next', '')
            if need:
                if need not in DIRECTIONS:
                    fails.append('%s: 第 %d 房 next 方向非法 %s' % (name, index, need))
                elif need not in [g['direction'] for g in gates]:
                    fails.append('%s: 第 %d 房 %s 的 next=%s 无对应门（有 %s）'
                                 % (name, index, pid, need, [g['direction'] for g in gates]))
            if room.get('boss') and not any(m.get('raw') and str(m['raw'][-1]) == '[boss]' for m in map_room.get('monsters', [])):
                fails.append('%s: BOSS 房 %s 的怪物表里没有 [boss] 标记' % (name, pid))

    print('\n== 城镇入口')
    for town, loc in towns.items():
        if not loc.get('dungeon_entry'):
            continue
        region = loc.get('dungeon_region', DEFAULT_REGION)
        regions = region if isinstance(region, list) else [region]
        choices = [d for d, s in dungeons.items()
                   if not s.get('legacy') and s.get('region', DEFAULT_REGION) in regions]
        print('   %-20s region=%-24s choices=%s' % (town, str(region), choices))
        for choice in choices:
            covered.setdefault(choice, []).append(town)
        if not choices:
            fails.append('城镇 %s 有副本入口但选不到任何副本（region=%s）' % (town, region))
    for name, spec in dungeons.items():
        if spec.get('legacy'):
            continue
        if not covered.get(name):
            fails.append('%s 没有任何城镇入口能选到它' % name)

    print('\n[DUNGEONS] 可玩副本 %d 个、房间 %d 间' % (playable, rooms_total))
    if fails:
        print('[DUNGEONS] FAIL %d' % len(fails))
        for line in fails:
            print('  - ' + line)
        return 1
    print('[DUNGEONS] OK 契约全部满足：路线/门/房间数据/入口/前置一致')
    return 0


if __name__ == '__main__':
    sys.exit(main())
