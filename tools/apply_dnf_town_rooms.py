"""把 `assets_local/flow_v1/rooms/*` 的导出结果接入 `data/towns.json`（幂等）。

每个房间：location（asset/placement/spawn/walk/camera_y）+ 双向 portal
（父场景侧为入口触发带，房间侧出口触发带放在出生点附近，保证与 spawn 同块可达）。

用法：python tools/apply_dnf_town_rooms.py
"""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOWNS = ROOT / 'game_dnf/data/towns.json'
ROOMS = ROOT / 'game_dnf/assets_local/flow_v1/rooms'

# id → (中文名, spawn, 父场景, 入口 rect, 入口 label, 回程 spawn, 回程 label)
PLAN = {
    'hendon_pub': ('赫顿酒馆', [600, 328], 'hendon_main', [1500, 300, 100, 40], '酒馆入口',
                   [1550, 340], '赫顿玛尔主街'),
    'hendon_inn': ('赫顿旅馆', [450, 340], 'hendon_main', [1900, 300, 100, 40], '旅馆入口',
                   [1950, 340], '赫顿玛尔主街'),
    'alfhlyra': ('阿尔法力亚', [450, 340], 'elvengard', [1250, 300, 100, 40], '阿尔法力亚 →',
                 [1300, 340], '艾尔文防线'),
}


def main() -> int:
    doc = json.loads(TOWNS.read_text(encoding='utf-8'))
    added = 0
    for key, (name, spawn, parent, rect, label, back_spawn, back_label) in PLAN.items():
        walk_file = ROOMS / key / 'walk.json'
        if not walk_file.is_file():
            print('[ROOMS] %s 尚未导出，跳过' % key)
            continue
        walk = json.loads(walk_file.read_text(encoding='utf-8'))['walk']
        doc['locations'][key] = {
            'name': name,
            'asset': 'res://assets_local/flow_v1/rooms/%s/manifest.json' % key,
            'placement': key,
            'spawn': spawn,
            'walk': walk,
            'npcs': {},
            'labels': [],
            'camera_y': 0,
        }
        doc['portals']['%s_to_%s' % (parent, key)] = {
            'from': parent, 'rect': rect, 'to': key, 'spawn': spawn, 'label': label,
            'reciprocal': '%s_exit' % key,
        }
        exit_rect = [max(0, spawn[0] - 100), max(0, spawn[1] - 40), 200, 60]
        doc['portals']['%s_exit' % key] = {
            'from': key, 'rect': exit_rect, 'to': parent, 'spawn': back_spawn,
            'label': back_label, 'reciprocal': '%s_to_%s' % (parent, key),
        }
        added += 1
    TOWNS.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('[ROOMS] 接入 %d 个房间，towns.json portals 共 %d 个' % (added, len(doc['portals'])))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
