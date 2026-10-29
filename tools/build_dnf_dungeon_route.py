"""按原版 DGN 的 cell 图生成副本路线，写入 data/dungeons.json。

原版依据（export 里已有的字段）：
  dungeon.cells        —— 每个 cell 的坐标、doors（四向门）、map_candidates、start/boss 候选
  dungeon.start_map_raw / boss_map_raw —— 候选起终点 cell 对
所以路线 = 从起点 cell 沿 doors 走到 boss cell 的最短路径，每格选一张候选地图。

用法：
  python tools/build_dnf_dungeon_route.py --check              # 只校验已有路线与 cell 图是否一致
  python tools/build_dnf_dungeon_route.py --write --id mirkwood --export <path> --name 幽暗密林
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
DUNGEONS = GAME / 'data/dungeons.json'
MOVE = {'left': (-1, 0), 'right': (1, 0), 'up': (0, -1), 'down': (0, 1)}

# 待入表的副本清单：id, 导出目录（相对 game_dnf），中文名, region, monster_level
PENDING = [
    ('grakkarak', 'assets_local/flow_v1/gran_v1/grakkarak', '格拉卡', 'granfloris', 8),
    ('grakkarak_burning', 'assets_local/flow_v1/gran_v1/grakkarak_burning', '燃烧的格拉卡', 'granfloris', 9),
    ('sunderland', 'assets_local/flow_v1/gran_v1/sunderland', '桑德兰', 'granfloris', 10),
    ('sunderland_dark', 'assets_local/flow_v1/gran_v1/sunderland_dark', '黑暗桑德兰', 'granfloris', 11),
    ('sunderland_poison', 'assets_local/flow_v1/gran_v1/sunderland_poison', '剧毒桑德兰', 'granfloris', 12),
    ('draconiantower', 'assets_local/flow_v1/skytower_v1/draconiantower', '龙人之塔', 'skytower', 13),
    ('golemtower', 'assets_local/flow_v1/skytower_v1/golemtower', '石巨人塔', 'skytower', 14),
    ('floatingcastle', 'assets_local/flow_v1/skytower_v1/floatingcastle', '悬空城', 'skytower', 15),
    ('palaceofload', 'assets_local/flow_v1/skytower_v1/palaceofload', '城主宫殿', 'skytower', 16),
    ('darkentrance', 'assets_local/flow_v1/skytower_v1/darkentrance', '幽暗回廊', 'skytower', 15),
    ('hallofdoll', 'assets_local/flow_v1/skytower_v1/hallofdoll', '人偶之塔', 'skytower', 14),
    ('draconiantower_amonlow', 'assets_local/flow_v1/skytower_v1/draconiantower_amonlow', '龙人之塔·亚蒙下层', 'skytower', 14),
]
# 注意：amonhigh/amonlow/oceanhigh/oceanlow/sepahigh/sepalow 这 6 个 .dgn 在
# dungeon/dungeon.lst 里没有条目（原版未注册，玩家不可进入），其地图目录
# （map/amon、map/ocean）实际归属 DraconianTower(11)、Hallofdoll(12)、PalaceOfLoad(15)。
# 因此天空之城可玩副本就是下面这 8 个，不要再把那 6 个加回来。


def cell_graph(export: dict) -> dict:
    cells = export['dungeon']['cells']
    return {(int(c['x']), int(c['y'])): c for c in cells}


def shortest(cells: dict, start: tuple[int, int], goal: tuple[int, int]) -> list[tuple[tuple[int, int], str]] | None:
    """BFS：返回 [(cell, 走出方向), ...]，最后一步为进入 goal 的方向。"""
    queue = deque([(start, [])])
    seen = {start}
    while queue:
        current, path = queue.popleft()
        if current == goal:
            return path
        for door in cells[current].get('doors', []):
            step = MOVE.get(door)
            if not step:
                continue
            nxt = (current[0] + step[0], current[1] + step[1])
            if nxt not in cells or nxt in seen:
                continue
            # 没有候选地图的格子走不通（原版 dgn 里可能存在空 cell）。
            if nxt != goal and not (cells[nxt].get('map_candidates') or []):
                continue
            seen.add(nxt)
            queue.append((nxt, path + [(current, door)]))
    return None


def pick_map(cell: dict, role: str) -> str:
    candidates = [str(c) for c in cell.get('map_candidates') or []]
    if role == 'start':
        preferred = [c for c in candidates if Path(c).stem.lower().startswith('s')]
    elif role == 'boss':
        preferred = [c for c in candidates if Path(c).stem.lower().startswith('b')]
    else:
        preferred = [c for c in candidates if not Path(c).stem.lower().startswith(('s', 'b'))]
    chosen = (preferred or candidates)
    if not chosen:
        raise ValueError('cell %s 没有候选地图' % cell)
    return Path(chosen[0]).stem


def build(export: dict, start_cell=None, boss_cell=None) -> list[dict]:
    cells = cell_graph(export)
    starts = sorted(cells) if start_cell is None else [tuple(start_cell)]
    bosses = sorted(cells) if boss_cell is None else [tuple(boss_cell)]
    best = None
    for s in starts:
        if not cells[s].get('start_candidate') or not (cells[s].get('map_candidates') or []):
            continue
        for b in bosses:
            if not cells[b].get('boss_candidate') or not (cells[b].get('map_candidates') or []):
                continue
            path = shortest(cells, s, b)
            if path is not None and (best is None or len(path) < len(best[2])):
                best = (s, b, path)
    if best is None:
        return None
    start, boss, path = best
    rooms = []
    for index, (cell, door) in enumerate(path):
        rooms.append({
            'name': '',
            'placement': '%d_%d:%s' % (cell[0], cell[1], pick_map(cells[cell], 'start' if index == 0 else 'normal')),
            'next': door,
        })
    rooms.append({
        'name': '',
        'placement': '%d_%d:%s' % (boss[0], boss[1], pick_map(cells[boss], 'boss')),
        'next': '',
        'boss': True,
    })
    return rooms


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    parser.add_argument('--id', default='')
    parser.add_argument('--name', default='')
    parser.add_argument('--export', default='')
    parser.add_argument('--region', default='granfloris')
    parser.add_argument('--requires', default='')
    parser.add_argument('--min-level', type=int, default=0)
    parser.add_argument('--monster-level', type=int, default=0)
    parser.add_argument('--status', action='store_true', help='列出待入表副本的导出进度')
    parser.add_argument('--apply-all', action='store_true', help='把已导出的待入表副本批量写入 dungeons.json')
    args = parser.parse_args()
    doc = json.loads(DUNGEONS.read_text(encoding='utf-8'))
    dungeons = doc['dungeons']
    if args.status:
        ready = 0
        for dungeon_id, folder, name, _region, _level in PENDING:
            done = (GAME / folder / 'map_export.json').is_file()
            ready += 1 if done else 0
            print('  %s %-24s %s' % ('就绪' if done else '导出中', dungeon_id, name))
        print('\n[STATUS] 就绪 %d / 共 %d' % (ready, len(PENDING)))
        print('[STATUS] 全部就绪，可执行 --apply-all' if ready == len(PENDING) else '[STATUS] 仍有副本在导出，稍后再跑')
        return 0
    if args.apply_all:
        applied = 0
        waiting = []
        for dungeon_id, folder, name, region, level in PENDING:
            export = GAME / folder / 'map_export.json'
            if not export.is_file():
                waiting.append(dungeon_id)
                continue
            export_doc = json.loads(export.read_text(encoding='utf-8'))
            rooms = build(export_doc)
            if rooms is None:
                waiting.append(dungeon_id + '(无连通路径)')
                continue
            for room in rooms:
                room['name'] = name
            origin = export_doc.get('dungeon') or export_doc.get('source', {})
            dungeons[dungeon_id] = {
                'name': name, 'region': region, 'map_export': 'res://' + folder + '/map_export.json',
                'rooms': rooms, 'monster_level': level,
                'source': {'path': origin.get('path', ''),
                           'sha256': origin.get('sha256', ''),
                           'evidence': '由 tools/build_dnf_dungeon_route.py --apply-all 按原版 cell 图自动生成'}}
            applied += 1
            print('  [OK] %-24s rooms=%d' % (dungeon_id, len(rooms)))
        if applied:
            DUNGEONS.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
        print('\n[APPLY] 写入 %d 个；仍待导出 %d 个 %s' % (applied, len(waiting), waiting))
        return 0
    if not args.write:
        # 校验模式：把已有路线与 cell 图对照，报告长度与起终点是否合法
        fails = 0
        for name, spec in dungeons.items():
            if spec.get('legacy') or not spec.get('map_export'):
                continue
            path = GAME / spec['map_export'].replace('res://', '')
            if not path.is_file():
                print('  %-14s 地图缺失' % name)
                fails += 1
                continue
            cells = cell_graph(json.loads(path.read_text(encoding='utf-8')))
            rooms = spec.get('rooms', [])
            first = rooms[0]['placement'].split(':')[0] if rooms else ''
            last = rooms[-1]['placement'].split(':')[0] if rooms else ''
            start_ok = bool(first) and bool(cells.get(tuple(int(v) for v in first.split('_')))) and cells[tuple(int(v) for v in first.split('_'))].get('start_candidate')
            boss_ok = bool(last) and bool(cells.get(tuple(int(v) for v in last.split('_')))) and cells[tuple(int(v) for v in last.split('_'))].get('boss_candidate')
            print('  %-14s rooms=%-2d 起点合法=%-5s BOSS合法=%s' % (name, len(rooms), start_ok, boss_ok))
            if not start_ok or not boss_ok:
                fails += 1
        return 1 if fails else 0
    path = GAME / args.export.replace('res://', '')
    if not args.id or not path.is_file():
        raise SystemExit('--write 需要 --id 与存在的 --export')
    export = json.loads(path.read_text(encoding='utf-8'))
    rooms = build(export)
    for room in rooms:
        room['name'] = args.name or args.id
    spec = {'name': args.name or args.id, 'region': args.region,
            'map_export': args.export, 'rooms': rooms}
    if args.requires:
        spec['requires'] = [x for x in args.requires.split(',') if x]
    if args.min_level:
        spec['min_level'] = args.min_level
    if args.monster_level:
        spec['monster_level'] = args.monster_level
    origin = export.get('dungeon') or export.get('source', {})
    spec['source'] = {'path': origin.get('path', ''),
                      'sha256': origin.get('sha256', ''),
                      'evidence': '由 tools/build_dnf_dungeon_route.py 按原版 cell 图自动生成路线'}
    dungeons[args.id] = spec
    DUNGEONS.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('[ROUTE] %s rooms=%d 写入 data/dungeons.json' % (args.id, len(rooms)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
