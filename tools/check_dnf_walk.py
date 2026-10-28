"""核查城镇/副本的可行走区域是否踩在真实地面美术上。

判定口径（见 docs/design/41_场景画面基准.md）：
  画布坐标 = 美术坐标 + ART_DY(80)；脚点 = map/地面坐标 + MAP_DY(200)。
  走区矩形的底边（角色最深的落脚点）必须落在该场景地砖/背景/物件美术的某一纵向区段内。
  副本用原 MAP 的通行格：可走行的底边必须落在地砖区段内。

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


def supported(segs: list[tuple[float, float]], feet_bottom: float) -> bool:
    return any(lo - TOLERANCE <= feet_bottom <= hi + TOLERANCE for lo, hi in segs)


def check_towns(game: Path) -> list[str]:
    fails: list[str] = []
    towns = json.loads((game / 'data/towns.json').read_text(encoding='utf-8'))
    manifests: dict[str, dict] = {}
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
        for rect in loc['walk']:
            bottom = rect[1] + rect[3] + MAP_DY
            if not supported(segs, bottom):
                fails.append('%s: walk bottom %.0f has no floor under it' % (key, bottom))
        print('  %-20s art %4.0f..%4.0f  %d walk rects' % (key, min(s[0] for s in segs), max(s[1] for s in segs), len(loc['walk'])))
    return fails


def check_dungeons(game: Path) -> list[str]:
    fails: list[str] = []
    combat = json.loads((game / 'data/combat.json').read_text(encoding='utf-8'))
    path = game / combat['map_export'].replace('res://', '')
    manifest = json.loads(path.read_text(encoding='utf-8'))
    cell = manifest['constants']['cell_height']
    for name, room in manifest['dungeon']['rooms'].items():
        segs = canvas_art(manifest, room)
        rows = [i for i, row in enumerate(room['walk_grid']) if any(v == 0 for v in row)]
        if not rows or not segs:
            continue
        bottom = (rows[-1] + 1) * cell + MAP_DY
        top = rows[0] * cell + MAP_DY
        if not supported(segs, bottom):
            fails.append('%s: walk bottom %.0f has no floor under it' % (name, bottom))
        if top < min(s[0] for s in segs) - TOLERANCE:
            fails.append('%s: walk top %.0f is above the art' % (name, top))
        print('  %-22s art %4.0f..%4.0f  rows %d..%d' % (name, min(s[0] for s in segs), max(s[1] for s in segs), rows[0], rows[-1]))
    return fails


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default=str(ROOT / 'game_dnf'))
    args = parser.parse_args()
    game = Path(args.root).resolve()
    if not (game / 'data/towns.json').exists() or not (game / 'assets_local/manifest.json').exists():
        print('[WALK] 缺少 game_dnf 数据或 assets_local（先同步资源库）', file=sys.stderr)
        return 2
    print('== 城镇 ==')
    fails = check_towns(game)
    print('== 副本 ==')
    fails += check_dungeons(game)
    if fails:
        print('\n[WALK] FAIL %d' % len(fails))
        for line in fails:
            print('  - ' + line)
        return 1
    print('\n[WALK] OK 所有走区脚点都落在真实地面美术上')
    return 0


if __name__ == '__main__':
    sys.exit(main())
