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
import re
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

# 新版（newmonsters）把动作挪到 `<mob 目录>/action/*.act`，文件名即动作名。
# 这里把 act 名映射回 .mob 的 motion 槽位，让两代架构能共用同一套运行时。
ACT_SLOTS = {
    'stay': 'waiting', 'move': 'move', 'sit': 'sit', 'jump': 'jump',
    'damage1': 'damage1', 'damage2': 'damage2', 'down': 'down',
    'overturn': 'overturn', 'die': 'die', 'attack': 'attack',
    'attack1': 'attack', 'attacklong': 'attack', 'attackheart': 'attack',
}


def motions_from_acts(lib, folder: str) -> dict:
    """新版 mob 的 `[attack motion]` 为空时，从 `<folder>/action/*.act` 的 [BASE ANI] 反推动作表。"""
    from decompile_dnf_ai import decode

    result: dict[str, list] = {}
    rows = [r[0] for r in lib.db.execute(
        "select path from files where path like ? and path like '%.act' order by path",
        (folder + '/action/%',))]
    for path in rows:
        stem = Path(path).stem.lower()
        slot = ACT_SLOTS.get(stem)
        if slot is None:
            continue
        raw = lib.raw(path)
        decoded = decode(raw[0] if raw else b'', lib.strings)
        if not decoded.get('ok'):
            continue
        tokens = [t.get('text', '').strip() for t in decoded['tokens']]
        if '[BASE ANI]' not in tokens:
            continue
        index = tokens.index('[BASE ANI]')
        if index + 1 >= len(tokens):
            continue
        ani = tokens[index + 1]
        if not ani.lower().endswith('.ani'):
            continue
        # [BASE ANI] 相对 action/ 目录
        parts: list[str] = []
        for part in (folder + '/action/' + ani.replace('\\', '/')).split('/'):
            if part in ('', '.'):
                continue
            if part == '..':
                if parts:
                    parts.pop()
                continue
            parts.append(part)
        resolved = '/'.join(parts).lower()
        if not lib.exists(resolved):
            continue
        # 与老架构一致：motion 值写成“相对 mob 目录”的路径（如 animation/stay.ani）。
        relative = resolved[len(folder) + 1:] if resolved.startswith(folder + '/') else Path(resolved).name
        result.setdefault(slot, []).append(relative)
    return {slot: sorted(set(names)) for slot, names in result.items()}


def one(spans: dict, tag: str, default=None):
    item = spans.get(tag)
    if not item:
        return default
    values = item[0]
    return values[0] if values else default


# 覆盖三种韩文字符：音节（AC00-D7AF）、字母（1100-11FF）、兼容字母（3130-318F）。
KOREAN = re.compile(r'[\uac00-\ud7af\u1100-\u11ff\u3130-\u318f]')


def safe(value) -> str:
    """游戏内不允许韩文；含韩文的字段留空（多为原版内部台词原文）。"""
    text = str(value)
    return '' if KOREAN.search(text) else text


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
                # 死亡表现：原版 [die effect] = [0, N, M]，N 每怪不同（goblin 1、tau 9、
                # mirkius 4、steelmaster 17）；[speech on situation] 是台词/音效的字符串 ID。
                'die_effect': many(spans, '[die effect]'),
                # 台词 key 与音效 tag 里可能混入韩文原文，游戏内不允许韩文，过滤掉。
                'speech': [text for text in (safe(v) for v in many(spans, '[speech on situation]')) if text][:12],
                'sounds': {tag: [text for text in (safe(v) for v in many(spans, tag)) if text][:6]
                           for tag in ('[hit wav]', '[die wav]', '[attack wav]', '[field wav]') if tag in spans},
            }
            for tag, key in MOTIONS.items():
                values = [str(v) for v in many(spans, tag) if isinstance(v, str) and v.lower().endswith('.ani')]
                if values:
                    entry['motions'][key] = values
            # 新版架构：动作不在 mob 里，而在 <目录>/action/*.act 的 [BASE ANI]。
            if not entry['motions']:
                entry['motions'] = motions_from_acts(lib, folder)
                if entry['motions']:
                    entry['motion_source'] = 'action/*.act'
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
