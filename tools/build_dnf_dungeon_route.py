"""按原版 DGN 的 cell 图生成副本路线，写入 data/dungeons.json。

原版依据（export 里已有的字段）：
  dungeon.cells        —— 每个 cell 的坐标、doors（四向门）、map_candidates、start/boss 候选
  dungeon.start_map_raw / boss_map_raw —— 候选起终点 cell 对
所以路线 = 从起点 cell 沿 doors 走到 boss cell 的最短路径，每格选一张候选地图。

用法：
  python tools/build_dnf_dungeon_route.py                      # 只校验已有路线与 cell 图是否一致
  python tools/build_dnf_dungeon_route.py --write --id mirkwood --export <path> --name 幽暗密林
  python tools/build_dnf_dungeon_route.py --export <path> --selected-map 5 0 3024 --room-role boss --ingress left
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import deque
from pathlib import Path
from check_dnf_walk import visible_down_gate, visible_entry_point
from export_dnf_map import (CELL_H, CELL_W, DOOR_BITS, OPPOSITE, VERIFIED_MAP_GREED_DUNGEONS,
                            dungeon_placement, parse_greed, source_map_greed_pairs)

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
DUNGEONS = GAME / 'data/dungeons.json'
MOVE = {'left': (-1, 0), 'right': (1, 0), 'up': (0, -1), 'down': (0, 1)}
QUEST_MAZES = {'draconiantower': 4307, 'hallofdoll': 4308, 'palaceofload': 4312}
DIFFICULTIES = ['normal', 'adventure', 'expert', 'king']
# Other original mazes may specify a pool per cell. Enable this mapping only
# for the ordinary maze with verified single-map rows and playable traversal.
VERIFIED_NORMAL_MAP_SPECIFICATIONS = {'dungeon/act2/palaceofload.dgn'}

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


def source_start_maps(cell: dict, maps: dict) -> list[str]:
    return [path for path in cell.get('map_candidates') or [] if maps[path].get('start_area')]


def pick_map(cell: dict, role: str, maps: dict) -> str:
    candidates = [str(c) for c in cell.get('map_candidates') or []]
    if role == 'start':
        # Some Act 2 start MAPs prefix their stem with the authored cell.
        # Their actual spawn area is stronger evidence than a filename prefix.
        start_maps = source_start_maps(cell, maps)
        prefix = f"({cell['x']},{cell['y']})"
        matching_cell = [path for path in start_maps if Path(path).stem.startswith(prefix)]
        preferred = matching_cell or start_maps or [c for c in candidates if Path(c).stem.lower().startswith('s')]
    else:
        preferred = [c for c in candidates if not Path(c).stem.lower().startswith(('s', 'b'))]
    chosen = (preferred or candidates)
    if not chosen:
        raise ValueError('cell %s 没有候选地图' % cell)
    return Path(chosen[0]).stem


def has_source_boss(room: dict) -> bool:
    return any(monster.get('raw') and monster['raw'][-1] == '[boss]' for monster in room.get('monsters', []))


def ordinary_specification_rows(dungeon: dict, tags):
    ordinary_maze = False
    for span in dungeon['raw']:
        tag = span['tag']
        if tag == '[maze info]':
            if ordinary_maze:
                break
            ordinary_maze = True
        elif ordinary_maze and tag == '[quest connection]':
            raise ValueError('Expected the ordinary maze before quest mazes')
        elif ordinary_maze and tag in tags:
            values = [token[2] for token in span['values']]
            if len(values) < 3 or any(type(value) is not int for value in values):
                raise ValueError(f'Invalid ordinary {tag} row: {values}')
            x, y, *map_ids = values
            yield tag, (x, y), map_ids


def source_map_specifications(dungeon: dict) -> dict:
    """Read the ordinary maze's per-cell MAP pools without choosing a role or slot."""
    specifications = {tag: {} for tag in ('[map specification]', '[boss map specification]',
                                           '[layered map specification]')}
    for tag, cell, map_ids in ordinary_specification_rows(dungeon, specifications):
        # The native parser clears this pool on every row, then appends its IDs.
        specifications[tag][cell] = map_ids
    return specifications


def normal_map_specifications(dungeon: dict) -> dict:
    if dungeon.get('path') not in VERIFIED_NORMAL_MAP_SPECIFICATIONS:
        return {}
    fixed = {}
    for _, cell, map_ids in ordinary_specification_rows(dungeon, {'[map specification]'}):
        if len(map_ids) != 1:
            raise ValueError('Expected one source MAP in ordinary [map specification]')
        if cell in fixed:
            raise ValueError('Duplicate cell in ordinary [map specification]')
        fixed[cell] = map_ids[0]
    if not fixed:
        raise ValueError('Missing ordinary [map specification]')
    return fixed


def resolve_selected_room(export: dict, cell: tuple[int, int], map_id: int, role: str, *,
                          layered: bool = False, ingress: str | None = None) -> dict:
    """Resolve an already selected MAP to an existing ordinary-maze placement.

    The original START_MAP notification supplies the cell and MAP ID. Source
    pools remain distinct. Where the server selection has been verified, check
    the selected pool and the entry side without choosing a random MAP.
    """
    valid_cell = len(cell) == 2 and all(type(coordinate) is int and 0 <= coordinate <= 0xff for coordinate in cell)
    if not valid_cell or type(map_id) is not int or not 0 <= map_id <= 0xffff:
        raise ValueError(f'Invalid selected room {cell}, MAP{map_id}')
    dungeon = export['dungeon']
    cells = cell_graph(export)
    definition = cells.get(cell)
    if definition is None:
        raise ValueError(f'Invalid selected room {cell}, MAP{map_id}')
    maps = dungeon['rooms']
    candidates = [path for path in definition['map_candidates'] if maps[path]['map_id'] == map_id]
    if len(candidates) != 1:
        raise ValueError(f'MAP{map_id} is not a unique source candidate at {cell}')
    path = candidates[0]
    room = maps[path]
    starts = bool(room.get('start_area'))
    boss = has_source_boss(room)
    verified_greed = dungeon.get('path') in VERIFIED_MAP_GREED_DUNGEONS
    if verified_greed:
        # A start MAP can also be registered as a normal room by the server.
        map_types = [token[2] for span in room['raw'] if span['tag'] == '[type]' for token in span['values']]
        normal = map_types == ['[normal]']
        boss = boss and map_types == ['[boss]']
    else:
        normal = not starts and not boss
    eligible = {'start': definition.get('start_candidate') and starts and not boss,
                'normal': normal, 'boss': definition.get('boss_candidate') and boss and not starts}
    if not eligible.get(role):
        raise ValueError(f'MAP{map_id} is not an eligible {role} room at {cell}')
    if ingress is not None and (not verified_greed or layered or role == 'start'):
        raise ValueError('Ingress verification requires a supported ordinary transition')
    if layered:
        pools = source_map_specifications(dungeon)['[layered map specification]']
        if map_id not in pools.get(cell, []):
            raise ValueError(f'MAP{map_id} is not a source layered room at {cell}')
    if verified_greed and not layered:
        pairs = room.get('greed_pairs') or source_map_greed_pairs(room)
        matching = [entrance for layout, entrance in pairs if layout == definition['mask']]
        if not matching:
            raise ValueError(f'MAP{map_id} has no matching source layout at {cell}')
        if role in ('normal', 'boss'):
            tag = '[boss map specification]' if role == 'boss' else '[map specification]'
            pool = source_map_specifications(dungeon)[tag].get(cell, [])
            if pool and map_id not in pool:
                raise ValueError(f'MAP{map_id} is outside source {tag} at {cell}')
            if pool:
                # For a specified MAP the server checks all its ingress masks.
                matching = [entrance for _, entrance in pairs]
        if ingress is not None:
            if ingress not in definition['doors']:
                raise ValueError(f'No source {ingress} door at {cell}')
            dx, dy = MOVE[ingress]
            neighbour = cells.get((cell[0] + dx, cell[1] + dy), {})
            if OPPOSITE[ingress] not in neighbour.get('doors', []):
                raise ValueError(f'No reciprocal source door at {cell} via {ingress}')
            if not any(mask & DOOR_BITS[ingress] for mask in matching):
                raise ValueError(f'MAP{map_id} does not accept ingress from {ingress} at {cell}')
    placements = [p for p in dungeon['placements'] if p['cell'] == list(cell) and p['map'] == path
                  and not p.get('quest_maze')]
    if len(placements) != 1:
        raise ValueError(f'MAP{map_id} has no unique ordinary placement at {cell}')
    return placements[0]


def first_source_placement(export: dict, cell: tuple[int, int], role: str, ingress: str | None) -> str:
    dungeon = export['dungeon']
    for path in cell_graph(export)[cell]['map_candidates']:
        map_id = dungeon['rooms'][path]['map_id']
        try:
            return resolve_selected_room(export, cell, map_id, role, ingress=ingress)['id']
        except ValueError:
            continue
    raise ValueError(f'No source {role} room at {cell} with ingress {ingress}')


def build(export: dict, start_cell=None, boss_cell=None) -> list[dict] | None:
    cells = cell_graph(export)
    maps = export['dungeon']['rooms']
    starts = sorted(cells) if start_cell is None else [tuple(start_cell)]
    bosses = sorted(cells) if boss_cell is None else [tuple(boss_cell)]
    # A boss cell may also accept ordinary maps or multiple mode-specific maps.
    # Generate a default route only when the cell has a unique source boss map.
    endings = {}
    for b in bosses:
        if not cells[b].get('boss_candidate'):
            continue
        candidates = [path for path in cells[b]['map_candidates'] if has_source_boss(maps[path])]
        if len(candidates) == 1:
            endings[b] = candidates[0]
    best = None
    for s in starts:
        if not cells[s].get('start_candidate') or not (cells[s].get('map_candidates') or []):
            continue
        for b in endings:
            path = shortest(cells, s, b)
            if path is not None and (best is None or len(path) < len(best[2])):
                best = (s, b, path)
    if best is None:
        return None
    start, boss, path = best
    if export['dungeon'].get('path') in VERIFIED_MAP_GREED_DUNGEONS:
        # Produce an offline fixed sample. The server rolls on first entry and
        # retains all other connected cells, including the side branches.
        rooms = []
        ingress = None
        for cell, door in path + [(boss, '')]:
            role = 'start' if cell == start else 'boss' if cell == boss else 'normal'
            placement = first_source_placement(export, cell, role, ingress)
            rooms.append({'name': '', 'placement': placement, 'next': door})
            ingress = OPPOSITE.get(door)
        rooms[-1]['boss'] = True
        return rooms
    fixed = normal_map_specifications(export['dungeon'])
    rooms = []
    for index, (cell, door) in enumerate(path):
        if index > 0 and cell in fixed:
            specified = [p for p in cells[cell]['map_candidates'] if maps[p].get('map_id') == fixed[cell]]
            if len(specified) != 1:
                raise ValueError(f'Normal cell {cell} requires source MAP{fixed[cell]}')
            stem = Path(specified[0]).stem
        else:
            stem = pick_map(cells[cell], 'start' if index == 0 else 'normal', maps)
        rooms.append({
            'name': '',
            'placement': '%d_%d:%s' % (cell[0], cell[1], stem),
            'next': door,
        })
    rooms.append({
        'name': '',
        'placement': '%d_%d:%s' % (boss[0], boss[1], Path(endings[boss]).stem),
        'next': '',
        'boss': True,
    })
    return rooms


def merge_route(existing: dict | None, generated: dict, *, refresh: bool) -> dict:
    """Preserve authored runtime gates unless a route refresh was requested."""
    if existing is None:
        return generated
    if not refresh:
        return existing
    merged = existing.copy()
    merged.update(generated)
    return merged


def source_quest_maze(dungeon: dict, quest_id: int) -> dict:
    section = {}
    matches = []
    for span in dungeon['raw'] + [{'tag': '[maze info]', 'values': []}]:
        tag = span['tag']
        if tag == '[maze info]':
            connection = section.get('[quest connection]', [])
            if (len(connection) == 3 and connection[:2] == [0, quest_id]
                    and type(connection[2]) is int and 0 <= connection[2] < len(DIFFICULTIES)):
                matches.append(section)
            section = {}
        elif not tag.startswith('[/'):
            section.setdefault(tag, []).extend(token[2] for token in span['values'])
    if len(matches) != 1:
        raise ValueError(f'Expected exactly one quest maze for QST{quest_id}')
    return matches[0]


def compile_quest_maze(dungeon: dict, quest_id: int, name: str) -> tuple[dict, dict, list[dict], dict]:
    source = source_quest_maze(dungeon, quest_id)
    start, boss = tuple(source['[start map]']), tuple(source['[boss map]'])
    issues = []
    cells = parse_greed(source['[greed]'][0], *source['[size]'], dungeon['path'], issues)
    if issues or start not in cells or boss not in cells:
        raise ValueError(f'Invalid QST{quest_id} maze graph: {issues}')
    maps = dungeon['rooms']
    map_ids = {room['map_id']: path for path, room in maps.items()}
    fixed = {}
    for tag in ('[map specification]', '[boss map specification]'):
        values = source.get(tag, [])
        if len(values) % 3:
            raise ValueError(f'Invalid {tag} for QST{quest_id}')
        for x, y, map_id in zip(values[::3], values[1::3], values[2::3]):
            if (x, y) not in cells or (x, y) in fixed or map_id not in map_ids:
                raise ValueError(f'Invalid QST{quest_id} fixed MAP{map_id} at {x},{y}')
            fixed[(x, y)] = map_ids[map_id]
    for pos, cell in cells.items():
        matches = sorted(path for path, room in maps.items() if cell['code'][0] in room['greed_codes'])
        if pos in fixed:
            if fixed[pos] not in matches:
                raise ValueError(f'QST{quest_id} fixed MAP has mismatched door code: {fixed[pos]}')
            matches = [fixed[pos]]
        elif pos == boss:
            matches = [path for path in matches if has_source_boss(maps[path])]
        elif pos != start:
            matches = [path for path in matches if not maps[path]['start_area'] and not has_source_boss(maps[path])]
        cell['map_candidates'] = matches
    starts = source_start_maps(cells[start], maps)
    bosses = cells[boss]['map_candidates']
    if len(starts) != 1 or len(bosses) != 1 or not has_source_boss(maps[bosses[0]]):
        raise ValueError(f'QST{quest_id} needs a unique source start and boss MAP')
    entry = maps[starts[0]]
    ai_character = [token[2] for span in entry['raw'] if span['tag'] == '[ai character]' for token in span['values']]
    if len(ai_character) != 8 or any(type(value) is not int for value in ai_character[:4]) or ai_character[4:6] != ['[character]', '[normal]']:
        raise ValueError(f'Unsupported QST{quest_id} [ai character] entry: {ai_character}')
    cells[start]['map_candidates'] = starts
    path = shortest(cells, start, boss)
    if not path:
        raise ValueError(f'No connected QST{quest_id} route')
    rooms = []
    placements = []
    for (x, y), side in path + [(boss, '')]:
        cell = cells[x, y]
        candidates = cell['map_candidates']
        preferred = [path for path in candidates if Path(path).stem.startswith(f'({x},{y})')]
        room = maps[(preferred or candidates)[0]]
        placement = dungeon_placement(room, cell, dungeon['pathgate_slots'], {boss}, f'quest{quest_id}_')
        if quest_id == 4312 and (x, y) == start:
            placement['spawn_override'] = list(visible_entry_point(room, CELL_W, CELL_H))
            placement['spawn_adaptation'] = 'E-ADAPT: 原出生区域落在固定 HUD 下方，选最近的可见原通行格'
        visible = visible_down_gate(room, placement, CELL_W, CELL_H)
        if visible:
            gate = next(g for g in placement['gates'] if g['direction'] == 'down')
            gate['source_anchor'] = gate['anchor']
            gate['anchor'] = [*visible, gate['source_anchor'][2]]
            gate['anchor_adaptation'] = 'E-ADAPT: 原门下沿超出固定画布，吸附到同侧原通行格可见边缘'
        placements.append(placement)
        rooms.append({'name': name, 'placement': placement['id'], 'next': side})
    rooms[-1]['boss'] = True
    companion = {'source_id': ai_character[0], 'anchor': ai_character[1:4], 'raw': ai_character}
    maze = {'source_id': quest_id, 'quest_connection_raw': source['[quest connection]'],
            'size': source['[size]'], 'greed_raw': source['[greed]'][0],
            'start_cell': list(start), 'boss_cell': list(boss),
            'map_specification_raw': source['[map specification]'],
            'boss_map_specification_raw': source.get('[boss map specification]', []),
            'cells': list(cells.values()), 'evidence': 'E-PARSE 专用迷宫与指定地图；E-ADAPT 最短通路，同坐标优先后取稳定候选'}
    difficulty = source['[quest connection]'][2]
    # QST4312's original condition explicitly permits Medium and higher.
    modes = DIFFICULTIES[difficulty:] if quest_id == 4312 else [DIFFICULTIES[difficulty]]
    route = {'difficulty': modes, 'companion_id': companion['source_id'],
             'source_map_id': maps[bosses[0]]['map_id'], 'rooms': rooms}
    return maze, route, placements, companion


def quest_maze_exports(dungeons: dict, check: bool) -> bool:
    outputs = {}
    for name, quest_id in QUEST_MAZES.items():
        spec = dungeons[name]
        path = GAME / spec['map_export'].removeprefix('res://')
        export = json.loads(path.read_bytes())
        dungeon = export['dungeon']
        maze, route, placements, companion = compile_quest_maze(dungeon, quest_id, spec['name'])
        quest = f'original.quest.{quest_id}'
        start = dungeon['rooms'][placements[0]['map']]
        if check:
            if (dungeon.get('quest_mazes', {}).get(quest) != maze or spec.get('quest_routes', {}).get(quest) != route
                    or [p for p in dungeon['placements'] if p.get('quest_maze') == quest] != [dict(p, quest_maze=quest) for p in placements]
                    or start.get('companions') != [companion]):
                print(f'[QUEST MAZE] {quest} stale or incomplete')
                return False
        else:
            dungeon.setdefault('quest_mazes', {})[quest] = maze
            dungeon['placements'] = [p for p in dungeon['placements'] if p.get('quest_maze') != quest]
            dungeon['placements'].extend(dict(p, quest_maze=quest) for p in placements)
            start['companions'] = [companion]
            spec.setdefault('quest_routes', {})[quest] = route
            outputs[path] = export
        print(f'[QUEST MAZE] {quest} rooms={len(route["rooms"])} MAP{route["source_map_id"]} APC{route["companion_id"]}')
    for path, export in outputs.items():
        path.write_text(json.dumps(export, ensure_ascii=False, indent=1, allow_nan=False) + '\n', encoding='utf-8')
    return True


def write_dungeons(doc: dict) -> None:
    temporary = DUNGEONS.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    os.replace(temporary, DUNGEONS)


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
    parser.add_argument('--refresh-existing', action='store_true', help='显式刷新已有路线，并保留运行时手工字段')
    parser.add_argument('--quest-mazes', action='store_true', help='核对原任务专用迷宫；加 --write 重建地图元数据和路线')
    parser.add_argument('--selected-map', nargs=3, type=int, metavar=('X', 'Y', 'MAP_ID'),
                        help='只读校验已选原房间，输出既有地图放置记录')
    parser.add_argument('--room-role', choices=('start', 'normal', 'boss'), default='normal')
    parser.add_argument('--layered-map', action='store_true', help='校验原多层地图池')
    parser.add_argument('--ingress', choices=DOOR_BITS, help='校验首次进入目标房间所用的原方向位')
    args = parser.parse_args()
    if args.ingress is not None and args.selected_map is None:
        parser.error('--ingress requires --selected-map')
    if args.selected_map is not None:
        if not args.export or args.write or args.status or args.apply_all or args.quest_mazes:
            parser.error('--selected-map requires --export and is read-only')
        path = GAME / args.export.removeprefix('res://')
        x, y, map_id = args.selected_map
        try:
            export = json.loads(path.read_text(encoding='utf-8'))
            placement = resolve_selected_room(export, (x, y), map_id, args.room_role,
                                              layered=args.layered_map, ingress=args.ingress)
        except (OSError, ValueError) as error:
            parser.error(str(error))
        print(json.dumps(placement, ensure_ascii=False))
        return 0
    doc = json.loads(DUNGEONS.read_text(encoding='utf-8'))
    dungeons = doc['dungeons']
    if args.quest_mazes:
        if not quest_maze_exports(dungeons, check=not args.write):return 1
        if args.write:write_dungeons(doc)
        return 0
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
            if dungeon_id in dungeons and not args.refresh_existing:
                print('  [KEEP] %-24s 已有运行配置，保留入口/等级/前置/隐藏状态' % dungeon_id)
                continue
            export = GAME / folder / 'map_export.json'
            if not export.is_file():
                waiting.append(dungeon_id)
                continue
            export_doc = json.loads(export.read_text(encoding='utf-8'))
            rooms = build(export_doc)
            if rooms is None:
                waiting.append(dungeon_id + '(无连通路径或领主地图不明确)')
                continue
            for room in rooms:
                room['name'] = name
            origin = export_doc.get('dungeon') or export_doc.get('source', {})
            generated = {
                'name': name, 'region': region, 'map_export': 'res://' + folder + '/map_export.json',
                'rooms': rooms, 'monster_level': level,
                'source': {'path': origin.get('path', ''),
                           'sha256': origin.get('sha256', ''),
                           'evidence': '由 tools/build_dnf_dungeon_route.py --apply-all 按原版 cell 图自动生成'}}
            dungeons[dungeon_id] = merge_route(
                dungeons.get(dungeon_id),
                generated,
                refresh=args.refresh_existing,
            )
            applied += 1
            print('  [OK] %-24s rooms=%d' % (dungeon_id, len(rooms)))
        if applied:
            write_dungeons(doc)
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
    if rooms is None:
        raise SystemExit('未找到可到达且有唯一原版领主地图的领主格')
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
    if args.id in dungeons and not args.refresh_existing:
        print('[ROUTE] %s 已有运行配置，未刷新；需要更新路线请加 --refresh-existing' % args.id)
        return 0
    dungeons[args.id] = merge_route(
        dungeons.get(args.id),
        spec,
        refresh=args.refresh_existing,
    )
    write_dungeons(doc)
    print('[ROUTE] %s rooms=%d 写入 data/dungeons.json%s'
          % (args.id, len(rooms), '（保留既有运行字段）' if args.refresh_existing else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
