"""核查城镇/副本的可行走区域是否踩在真实地面美术上，并检查路径连通。

判定口径（见 docs/design/41_场景画面基准.md）：
  画布坐标 = 美术坐标 + ART_DY(80)；脚点 = 地面坐标 + MAP_DY(200)。
  可走区域是**矩形并集**（连接处常是窄通道），所以按 STEP 像素逐点采样：
    ① 每个可走采样点的脚点必须落在该场景地砖/背景/物件美术的某一纵向区段内；
    ② 并集必须是一个连通块（窄通道把两片区域连起来，不能断）；
    ③ 每条传送门的触发带必须有可走采样点，且与出生点同属一块。
  副本用原 MAP 通行格：每格中心同样检查支撑，并从 [dungeon start area] 或门格出发做连通。

用法：
  python tools/check_dnf_walk.py            # 默认读 game_dnf/
  python tools/check_dnf_walk.py --root game_dnf

只读 assets_local 与 data/，不启动引擎；缺资源时以退出码 2 结束。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ART_DY, MAP_DY = 80, 200
TOLERANCE = 2.0
STEP = 8
ROOT = Path(__file__).resolve().parent.parent


def canvas_art(manifest: dict, room: dict) -> list[tuple[float, float]]:
    """地砖、背景层与物件在画布上的纵向覆盖区段。"""
    segs: list[tuple[float, float]] = []
    for tile in room.get('tiles', []):
        info = manifest['images'].get(tile.get('image')) if tile.get('image') else None
        if not info:
            continue
        y = tile['offset'][1] + ART_DY
        segs.append((y, y + info['size'][1]))
    for bg in room.get('background', []):
        frames = bg['sprite'].get('frames') or []
        if not frames:
            continue
        frame = frames[0]
        info = manifest['images'].get(frame.get('image'))
        if not info:
            continue
        y = frame.get('offset', [0, 0])[1] + ART_DY
        segs.append((y, y + info['size'][1]))
    for item in room.get('objects', []) + room.get('animations', []):
        sprite = item.get('sprite')
        frames = (sprite or {}).get('frames') or []
        if not frames:
            continue
        frame = frames[0]
        info = manifest['images'].get(frame.get('image'))
        if not info:
            continue
        y = item['anchor'][1] + MAP_DY + frame.get('offset', [0, 0])[1]
        segs.append((y, y + info['size'][1]))
    return segs


def supported(segs: list[tuple[float, float]], feet: float) -> bool:
    return any(lo - TOLERANCE <= feet <= hi + TOLERANCE for lo, hi in segs)


def walk_points(rects: list) -> set[tuple[int, int]]:
    """矩形并集的采样点：全场景共用一套 STEP 网格，只保留落在并集内的点。

    共用网格很关键——各矩形若各自从自身左上角开始采样，重叠区会错开半个步长，
    连通判定会把本来相接的通道判成断开的。
    """
    max_x = max(r[0] + r[2] for r in rects)
    max_y = max(r[1] + r[3] for r in rects)
    pts: set[tuple[int, int]] = set()
    for x in range(STEP // 2, int(max_x), STEP):
        for y in range(STEP // 2, int(max_y), STEP):
            if any(r[0] <= x < r[0] + r[2] and r[1] <= y < r[1] + r[3] for r in rects):
                pts.add((x, y))
    return pts


def blocks(points: set[tuple[int, int]]) -> list[set[tuple[int, int]]]:
    """八邻域外的四邻接连通块（采样步长即格距）。"""
    seen: set[tuple[int, int]] = set()
    out: list[set[tuple[int, int]]] = []
    for start in points:
        if start in seen:
            continue
        comp = {start}
        seen.add(start)
        stack = [start]
        while stack:
            x, y = stack.pop()
            for nb in ((x + STEP, y), (x - STEP, y), (x, y + STEP), (x, y - STEP)):
                if nb in points and nb not in seen:
                    seen.add(nb)
                    comp.add(nb)
                    stack.append(nb)
        out.append(comp)
    return out


def grid_blocks(cells: set[tuple[int, int]]) -> list[set[tuple[int, int]]]:
    """通行格的四邻接连通块（格距 1）。"""
    seen: set[tuple[int, int]] = set()
    out: list[set[tuple[int, int]]] = []
    for start in cells:
        if start in seen:
            continue
        comp = {start}
        seen.add(start)
        stack = [start]
        while stack:
            c, r = stack.pop()
            for nb in ((c + 1, r), (c - 1, r), (c, r + 1), (c, r - 1)):
                if nb in cells and nb not in seen:
                    seen.add(nb)
                    comp.add(nb)
                    stack.append(nb)
        out.append(comp)
    return out


def points_in(rect: list, points: set[tuple[int, int]]) -> list[tuple[int, int]]:
    x, y, w, h = rect
    return [p for p in points if x <= p[0] < x + w and y <= p[1] < y + h]


def check_towns(game: Path) -> list[str]:
    fails: list[str] = []
    towns = json.loads((game / 'data/towns.json').read_text(encoding='utf-8'))
    manifests: dict[Path, dict] = {}
    points_map: dict[str, set[tuple[int, int]]] = {}
    home_map: dict[str, set[tuple[int, int]]] = {}
    segs_map: dict[str, list[tuple[float, float]]] = {}
    for key, loc in towns['locations'].items():
        path = game / loc['asset'].replace('res://', '')
        if path not in manifests:
            manifests[path] = json.loads(path.read_text(encoding='utf-8'))
        manifest = manifests[path]
        room = None
        for placement in manifest['dungeon']['placements']:
            if placement['id'] == loc['placement']:
                room = manifest['dungeon']['rooms'][placement['map']]
        if room is None:
            fails.append('%s: placement %s not found' % (key, loc['placement']))
            continue
        segs = canvas_art(manifest, room)
        if not segs:
            fails.append('%s: no art segments' % key)
            continue
        points = walk_points(loc['walk'])
        if not points:
            fails.append('%s: empty walk union' % key)
            continue
        points_map[key] = points
        segs_map[key] = segs
        bad = [p for p in points if not supported(segs, p[1] + MAP_DY)]
        if bad:
            fails.append('%s: %d walk points have no floor (e.g. %s)' % (key, len(bad), sorted(bad)[:3]))
        comps = blocks(points)
        if len(comps) > 1:
            fails.append('%s: walk union splits into %d disconnected parts' % (key, len(comps)))
        spawn = loc['spawn']
        home = [c for c in comps if any(abs(p[0] - spawn[0]) <= STEP and abs(p[1] - spawn[1]) <= STEP for p in c)]
        if not home:
            fails.append('%s: spawn %s is not on a walk sample' % (key, spawn))
            continue
        home_map[key] = home[0]
    # 传送门：源侧触发带必须有可走点且与出生点同块；目标侧落点必须落在目标场景走区上。
    ok_by_source: dict[str, int] = {}
    total_by_source: dict[str, int] = {}
    for portal in towns['portals'].values():
        src, dst = portal['from'], portal['to']
        label = portal.get('reciprocal', dst)
        total_by_source[src] = total_by_source.get(src, 0) + 1
        hits = points_in(portal['rect'], points_map.get(src, set()))
        if not hits:
            fails.append('%s: portal %s trigger band has no walkable point' % (src, label))
            continue
        home = home_map.get(src, set())
        if home and not any(p in home for p in hits):
            fails.append('%s: portal %s is not reachable from the spawn' % (src, label))
            continue
        landing = portal['spawn']
        near = [p for p in points_map.get(dst, set()) if abs(p[0] - landing[0]) <= STEP and abs(p[1] - landing[1]) <= STEP]
        if not near:
            fails.append('%s: portal %s lands at %s outside %s walkable area' % (src, label, landing, dst))
            continue
        ok_by_source[src] = ok_by_source.get(src, 0) + 1
    for key, loc in towns['locations'].items():
        segs = segs_map.get(key)
        if not segs:
            continue
        print('  %-20s art %4.0f..%4.0f  rects %d  points %5d  portals %d/%d'
              % (key, min(s[0] for s in segs), max(s[1] for s in segs), len(loc['walk']),
                 len(points_map.get(key, set())), ok_by_source.get(key, 0), total_by_source.get(key, 0)))
    return fails


def check_dungeons(game: Path) -> list[str]:
    fails: list[str] = []
    combat = json.loads((game / 'data/combat.json').read_text(encoding='utf-8'))
    path = game / combat['map_export'].replace('res://', '')
    manifest = json.loads(path.read_text(encoding='utf-8'))
    cell_w = manifest['constants']['cell_width']
    cell_h = manifest['constants']['cell_height']
    for name, room in manifest['dungeon']['rooms'].items():
        segs = canvas_art(manifest, room)
        grid = room['walk_grid']
        cells = {(c, r) for r, row in enumerate(grid) for c, v in enumerate(row) if v == 0}
        if not cells or not segs:
            continue
        points = {(c * cell_w + cell_w // 2, r * cell_h + cell_h // 2) for c, r in cells}
        bad = [p for p in points if not supported(segs, p[1] + MAP_DY)]
        if bad:
            fails.append('%s: %d walk cells have no floor (e.g. %s)' % (name, len(bad), sorted(bad)[:3]))
        comps = grid_blocks(cells)
        if len(comps) > 1:
            fails.append('%s: walkable cells split into %d disconnected parts' % (name, len(comps)))
        print('  %-22s art %4.0f..%4.0f  cells %5d  blocks %d' % (name, min(s[0] for s in segs), max(s[1] for s in segs), len(cells), len(comps)))
    return fails


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default=str(ROOT / 'game_dnf'))
    args = parser.parse_args()
    game = Path(args.root).resolve()
    if not (game / 'data/towns.json').exists() or not (game / 'assets_local/manifest.json').exists():
        print('[WALK] 缺少 game_dnf 数据或 assets_local（先同步资源库）', file=sys.stderr)
        return 2
    print('== 城镇（矩形并集逐点 + 连通 + 门触发带）==')
    fails = check_towns(game)
    print('== 副本（通行格逐格 + 连通）==')
    fails += check_dungeons(game)
    if fails:
        print('\n[WALK] FAIL %d' % len(fails))
        for line in fails:
            print('  - ' + line)
        return 1
    print('\n[WALK] OK 走区逐点踩在真实地面美术上、连通且门触发带可达')
    return 0


if __name__ == '__main__':
    sys.exit(main())
