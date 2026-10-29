"""把每个 BOSS 的招式表从原版数据里解出来（不猜、不用通用模板）。

数据来源：
  - `.mob` 的 `[attack motion]`：这一招用哪段 ANI（多值 = 多招）
  - 该 ANI 每帧的 `boxes`（kind=damage）：这一招实际能打到多远的**判定盒**
  - `.mob` 的 `[attack info]`：这一招的 `.atk`（伤害倍率 / 击退 / 浮空 / 命中音）
  - `[attack delay]`：出手间隔

输出 `data/boss_moves.json`：每个 BOSS 一组招，每招带 `reach`（相对锚点的可命中 x 区间）、
`damage_bonus`、`push`、`lift`、`knock_back`、`hit_wav`、`frames`（判定出现的时刻）。

用法：python tools/build_dnf_boss_moves.py [--library DIR]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_dnf_combat_assets as B

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'data/boss_moves.json'
CATALOG = GAME / 'data/monster_catalog.json'
DUNGEONS = GAME / 'data/dungeons.json'


def boss_mobs() -> dict[str, set]:
    """从副本导出里找出带 [boss] 标记的怪，并记录它出现在哪些副本。"""
    found: dict[str, set] = {}
    dungeons = json.loads(DUNGEONS.read_text(encoding='utf-8'))['dungeons']
    for name, spec in dungeons.items():
        if spec.get('legacy') or not spec.get('map_export'):
            continue
        path = GAME / spec['map_export'].replace('res://', '')
        if not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding='utf-8'))
        except Exception:
            continue
        for room in (data.get('dungeon', {}).get('rooms') or {}).values():
            for monster in room.get('monsters') or []:
                raw = monster.get('raw') or []
                if raw and str(raw[-1]) == '[boss]' and monster.get('mob'):
                    found.setdefault(str(monster['mob']).lower(), set()).add(name)
    return found


def spans_of(src, path: str, kind: str = '') -> dict[str, list]:
    doc = src.lib.script(path, kind) if kind else src.lib.script(path)
    spans: dict[str, list] = {}
    for item in doc.get('fields') or []:
        spans.setdefault(item['tag'], []).append(item['values'])
    return spans


def first(spans: dict, tag: str, default=None):
    item = spans.get(tag)
    if not item:
        return default
    values = item[0]
    return values[0] if values else default


def group(spans: dict, tag: str) -> list:
    item = spans.get(tag)
    return list(item[0]) if item else []


def reach_of(src, ani_path: str) -> dict:
    """读 ANI 的所有 damage 判定盒，算出这一招能打到的 x 区间与该帧时刻。"""
    try:
        ani = src.animation(ani_path)
    except KeyError:
        return {}
    meta = ani.get('metadata') or ani
    frames = meta.get('frames') or []
    low = None
    high = None
    hit_frames = []
    elapsed = 0
    for frame in frames:
        elapsed += int(frame.get('delay_ms') or 0)
        hit = False
        for box in frame.get('boxes') or []:
            if str(box.get('kind')) != 'damage':
                continue
            values = box.get('box') or []
            if len(values) < 4:
                continue
            # box = [x, y, z, w, d, h]：x/w 是相对锚点的水平范围
            x, width = float(values[0]), float(values[3])
            low = x if low is None else min(low, x)
            high = x + width if high is None else max(high, x + width)
            hit = True
        if hit:
            hit_frames.append(elapsed)
    if low is None:
        return {}
    return {'reach': [round(low), round(high)], 'hit_at_ms': hit_frames,
            'duration_ms': int(meta.get('duration_ms') or 0)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=None)
    args = parser.parse_args()
    src = B.Source(args.library)
    catalog = json.loads(CATALOG.read_text(encoding='utf-8'))['monsters']
    bosses = boss_mobs()
    result: dict[str, dict] = {}
    try:
        for mob, dungeons in sorted(bosses.items()):
            entry = next((m for m in catalog.values() if str(m['path']).lower() == mob), None)
            if entry is None:
                continue
            folder = str(PurePosixPath(mob).parent)
            spans = spans_of(src, mob, 'mob')
            motions = [str(v) for v in group(spans, '[attack motion]') if isinstance(v, str)]
            infos = [str(v) for v in group(spans, '[attack info]') if isinstance(v, str)]
            moves = []
            for index, motion in enumerate(motions):
                ani_path = (folder + '/' + motion).lower()
                geometry = reach_of(src, ani_path)
                move = {'index': index, 'motion': motion, 'ani': ani_path,
                        'attack_delay': first(spans, '[attack delay]')}
                move.update(geometry)
                if index < len(infos) and infos[index].lower().endswith('.atk'):
                    atk_path = (folder + '/' + infos[index]).lower()
                    if src.lib.exists(atk_path):
                        atk = spans_of(src, atk_path, 'atk')
                        move['atk'] = atk_path
                        move['damage_bonus'] = first(atk, '[damage bonus]')
                        move['push'] = first(atk, '[push aside]')
                        move['lift'] = first(atk, '[lift up]')
                        move['knock_back'] = first(atk, '[knuck back]')
                        move['hit_wav'] = first(atk, '[hit wav]')
                moves.append(move)
            result[mob] = {'mob': mob, 'name': entry.get('name'), 'dungeons': sorted(dungeons),
                           'level': entry.get('level'), 'sight': entry.get('sight'),
                           'attack_delay': first(spans, '[attack delay]'), 'moves': moves}
    finally:
        if hasattr(src, 'lib'):
            src.lib.close()
    OUT.write_text(json.dumps({
        'schema': 'dnf_boss_moves/1',
        'evidence': 'attack motion 取 ANI 的 damage 判定盒算 reach；攻击参数取 .atk（E-PARSE）',
        'bosses': result,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    total = sum(len(v['moves']) for v in result.values())
    with_reach = sum(1 for v in result.values() for m in v['moves'] if m.get('reach'))
    print('[BOSS] %d 个 BOSS、%d 招（其中 %d 招有判定范围）' % (len(result), total, with_reach))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
