"""导出城镇内的独立房间（酒馆、旅馆房间、通道），并给出可走区建议。

原版依据：房间就是 `map/hendonmyre/*.map`、`map/elvengard/*.map` 这类独立地图，
用与城镇街道相同的 `export_dnf_map.export_map` 导出；走区由该地图的通行格
（`walk_grid`，格 16×12）自动合并成矩形，避免手工量错。

输出：
  game_dnf/assets_local/flow_v1/rooms/<id>/manifest.json   房间美术（原生像素）
  game_dnf/assets_local/flow_v1/rooms/<id>/walk.json       建议走区矩形（map 坐标）
用法：python tools/build_dnf_town_rooms.py [--library DIR] [--id hendon_pub]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_dnf_map import Library, export_map, CELL_W, CELL_H

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUTPUT = GAME / 'assets_local/flow_v1/rooms'

# 原版房间：key → 地图路径。名称与位置由 towns.json 引用。
ROOMS = {
    'hendon_pub': 'map/hendonmyre/hendon_pub.map',
    'hendon_inn': 'map/hendonmyre/(r)gate_hendon.map',
    'alfhlyra': 'map/elvengard/elven2alfh.map',
    # 西海岸：赫顿玛尔西侧的海岸城镇，(r) 版与 hendon_main 的取法一致。
    'westcoast': 'map/hendonmyre/(r)westcoast.map',
}


def rects_from_grid(grid: list) -> list[list[int]]:
    """通行格 → 走区矩形（合并相邻行的相同列段，格 16×12，返回 map 坐标）。"""
    walks: dict[int, list[tuple[int, int]]] = {}
    for row, cols in enumerate(grid):
        spans: list[tuple[int, int]] = []
        start = None
        for col, value in enumerate(cols):
            walkable = int(value) == 0
            if walkable and start is None:
                start = col
            elif not walkable and start is not None:
                spans.append((start, col - start))
                start = None
        if start is not None:
            spans.append((start, len(cols) - start))
        if spans:
            walks[row] = spans
    out: list[list[int]] = []
    open_rects: list[list[int]] = []
    for row in sorted(walks):
        current = walks[row]
        still_open: list[list[int]] = []
        for rect in open_rects:
            if (rect[0], rect[2]) in current:
                rect[3] += CELL_H
                still_open.append(rect)
            else:
                out.append(rect)
        used = {(r[0], r[2]) for r in still_open}
        for start, width in current:
            if (start, width) in used:
                continue
            rect = [start * CELL_W, row * CELL_H, width * CELL_W, CELL_H]
            still_open.append(rect)
        open_rects = still_open
    out.extend(open_rects)
    out.sort(key=lambda r: (r[1], r[0]))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=None)
    parser.add_argument('--id', default='')
    args = parser.parse_args()
    jobs = {k: v for k, v in ROOMS.items() if not args.id or k == args.id}
    if not jobs:
        raise SystemExit('未知房间 id：' + args.id)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    library = args.library
    if library is None:
        import dnf_pvf as P
        probe = P.open_library()
        library = probe.path
        probe.close()
    lib = Library(library, OUTPUT)
    try:
        ids = {'objects': lib.listing('passiveobject/passiveobject.lst'),
               'monsters': lib.listing('monster/monster.lst')}
        for key, path in jobs.items():
            room = export_map(lib, path, ids)
            folder = OUTPUT / key
            folder.mkdir(parents=True, exist_ok=True)
            walk = rects_from_grid(room.get('walk_grid') or [])
            manifest = {
                'schema': 'dnf_native_map/1',
                'source': {'path': path, 'evidence': 'E-PARSE 原版房间地图，原生像素不缩放'},
                'constants': {
                    'tile_width': 224, 'tile_height': 480, 'grid_cols': 14, 'grid_rows': 30,
                    'cell_width': CELL_W, 'cell_height': CELL_H, 'screen_y_offset': 120, 'viewport': [640, 480],
                },
                'dungeon': {'rooms': {path: room},
                            'placements': [{'id': key, 'map': path, 'gates': []}]},
                'images': dict(lib.images),
                'walk': walk,
            }
            (folder / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
            (folder / 'walk.json').write_text(json.dumps({'walk': walk}, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
            tiles = [t for t in room.get('tiles', []) if t.get('image')]
            print('[ROOM] %-12s tiles=%-3d animations=%-3d objects=%-3d walk_rects=%d'
                  % (key, len(tiles), len(room.get('animations') or []), len(room.get('objects') or []), len(walk)))
    finally:
        lib.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
