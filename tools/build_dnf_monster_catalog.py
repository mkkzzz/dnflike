"""解析原版怪物定义（.mob）与攻击判定（.atk），生成怪物总账。

原版依据：`monster/monster.lst` 是 索引→mob 路径 的表；每个 `.mob` 里有
属性系数（`[ability category]`）、速度（move/attack/cast/hit recovery）、视野、
攻击延迟、动作文件（waiting/move/damage/down/overturn/attack motion）、
攻击判定文件（`[attack info]` → `.atk`）、掉落表（`[item]`）。

输出 game_dnf/data/monster_catalog.json：按 mob id 索引，含上述全部字段与动作可用性。
用法：python tools/build_dnf_monster_catalog.py [--library DIR] [--ids goblin,tauarmy]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'data/monster_catalog.json'

MOTIONS = {
    '[waiting motion]': 'waiting', '[move motion]': 'move', '[sit motion]': 'sit',
    '[damage motion 1]': 'damage1', '[damage motion 2]': 'damage2',
    '[down motion]': 'down', '[overturn motion]': 'overturn', '[attack motion]': 'attack',
    '[die motion]': 'die', '[jump motion]': 'jump',
}
SPEEDS = {'[move speed]': 'move', '[attack speed]': 'attack', '[cast speed]': 'cast', '[hit recovery]': 'hit_recovery'}


def one(spans: dict, tag: str, default=None):
    item = spans.get(tag)
    if not item:
        return default
    values = item[0]
    return values[0] if values else default


def many(spans: dict, tag: str) -> list:
    item = spans.get(tag)
    return list(item[0]) if item else []


def abilities(spans: dict) -> dict:
    """`['[HP MAX]','*',70,'[EQUIPMENT_PHYSICAL_ATTACK]','*',90,...]` → {HP MAX: 70, ...}"""
    flat = many(spans, '[ability category]')
    out: dict[str, float] = {}
    index = 0
    while index < len(flat) - 2:
        name, op, value = flat[index], flat[index + 1], flat[index + 2]
        if isinstance(name, str) and name.startswith('[') and op == '*' and isinstance(value, (int, float)):
            out[name.strip('[]').strip()] = value
            index += 3
        else:
            index += 1
    return out


def drops(spans: dict) -> list:
    flat = many(spans, '[item]')
    out = []
    for index in range(0, len(flat) - 1, 2):
        if isinstance(flat[index], int) and isinstance(flat[index + 1], int):
            out.append([flat[index], flat[index + 1]])
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=None)
    parser.add_argument('--ids', default='', help='只解析这些 mob 名（逗号分隔）；空=全部')
    args = parser.parse_args()
    wanted = {x.strip().lower() for x in args.ids.split(',') if x.strip()}
    lib = P.open_library(args.library)
    catalog: dict[str, dict] = {}
    missing_atk = []
    failed = 0
    try:
        table = lib.listing('monster/monster.lst')
        for index, rel in sorted(table.items()):
            path = ('monster/' + rel).lower()
            stem = PurePosixPath(rel).stem.lower()
            if wanted and stem not in wanted:
                continue
            try:
                doc = lib.script(path)
            except Exception:
                failed += 1
                continue
            if not doc:
                failed += 1
                continue
            spans: dict[str, list] = {}
            for item in doc.get('fields') or []:
                spans.setdefault(item['tag'], []).append(item['values'])
            folder = str(PurePosixPath(path).parent)
            entry = {
                'id': index, 'path': path, 'folder': folder,
                'category': [str(v) for v in many(spans, '[category]')],
                'level': [int(v) for v in many(spans, '[level]') if isinstance(v, (int, float))],
                'width': [int(v) for v in many(spans, '[width]') if isinstance(v, (int, float))],
                'sight': one(spans, '[sight]'),
                'attack_delay': one(spans, '[attack delay]'),
                'weight': one(spans, '[weight]'),
                'speeds': {key: one(spans, tag) for tag, key in SPEEDS.items() if one(spans, tag) is not None},
                'abilities': abilities(spans),
                'motions': {},
                'attacks': [],
                'drops': drops(spans),
            }
            for tag, key in MOTIONS.items():
                values = [str(v) for v in many(spans, tag) if isinstance(v, str) and v.lower().endswith('.ani')]
                if values:
                    entry['motions'][key] = values
            for rel_ani in many(spans, '[attack info]'):
                if not isinstance(rel_ani, str) or not rel_ani.lower().endswith('.atk'):
                    continue
                atk_path = folder + '/' + rel_ani.lower()
                info = {'path': atk_path, 'exists': lib.exists(atk_path)}
                if info['exists']:
                    atk_doc = lib.script(atk_path)
                    atk_spans: dict[str, list] = {}
                    for item in atk_doc.get('fields') or []:
                        atk_spans.setdefault(item['tag'], []).append(item['values'])
                    info['raw_tags'] = list(atk_spans)[:12]
                    info['fields'] = {tag: many(atk_spans, tag)[:8] for tag in
                                      ('[attack type]', '[damage]', '[hit box]', '[box]', '[attack box]') if tag in atk_spans}
                else:
                    missing_atk.append(atk_path)
                entry['attacks'].append(info)
            # 同名 mob 在不同目录下有多份（如 3 个 tauarmy.mob），key 必须带目录。
            entry['name'] = stem
            catalog[folder.replace('monster/', '', 1) + '/' + stem] = entry
            # 投掷型远程怪用 [throw attack] 而不是 [attack info]，单列出来。
            throw = many(spans, '[throw attack]')
            if throw:
                entry['throw'] = {'raw': throw[:40]}
    finally:
        lib.close()
    OUT.write_text(json.dumps({
        'schema': 'dnf_monster_catalog/1',
        'evidence': '原版 .mob 的 motion/ability/speed/attack info 字段（E-PARSE）；.atk 判定字段保留原始 tag',
        'count': len(catalog), 'failed': failed, 'missing_atk': missing_atk[:30],
        'monsters': catalog,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    with_motion = sum(1 for m in catalog.values() if m['motions'])
    with_atk = sum(1 for m in catalog.values() if m['attacks'] or m.get('throw'))
    print('[MONSTER] 解析 %d 条定义（失败 %d），有动作表 %d，有攻击定义 %d，缺 .atk %d'
          % (len(catalog), failed, with_motion, with_atk, len(missing_atk)))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
