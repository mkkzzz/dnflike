"""全量解析原版装备/消耗品定义，生成物品总账（供物品表实装使用）。

来源：`.equ`（装备 74k）、`.stk`（消耗品/材料 10k）、`.etc`。
输出 game_dnf/data/item_catalog.json：
  summary —— 各类数量、稀有度分布、带英文名的装备数
  items   —— 每件：路径、类别、稀有度、等级、职业限制、交易类型、价格、重量、图标引用、属性、名字槽指纹

本总账只记录name2与name_sig，不解析中文全文；这不是加密或缺中文的证据。
111直接字串可按CP950读取，本地化引用由audit_dnf_reusable_data.TextResolver解出STR正文。

用法：
  python tools/build_dnf_item_catalog.py            # 全量（约 85k 条，数分钟）
  python tools/build_dnf_item_catalog.py --limit 3000 --kind equ
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import re
import sys
from pathlib import Path

KOREAN = re.compile(r'[\uac00-\ud7af\u1100-\u11ff]')

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'data/item_catalog.json'

# 数值字段：原版 tag → 输出键
NUMERIC = {
    '[minimum level]': 'level',
    '[grade]': 'grade',
    '[rarity]': 'rarity',
    '[weight]': 'weight',
    '[price]': 'price',
    '[repair price]': 'repair_price',
    '[value]': 'value',
    '[physical attack]': 'physical_attack',
    '[magical attack]': 'magical_attack',
    '[physical defense]': 'physical_defense',
    '[magical defense]': 'magical_defense',
    '[attack speed]': 'attack_speed',
    '[creation rate]': 'creation_rate',
    '[cool time]': 'cool_time',
    '[fire attack]': 'fire_attack',
    '[water attack]': 'water_attack',
    '[light attack]': 'light_attack',
    '[dark attack]': 'dark_attack',
}
TEXT = {
    '[usable job]': 'usable_job',
    '[attach type]': 'attach',
    '[equipment type]': 'equipment_type',
    '[item group name]': 'group',
    '[move wav]': 'move_wav',
    '[stackable type]': 'stackable_type',
}


def as_text(values: list) -> str:
    return str(values[0]) if values else ''


def safe(value: str) -> str:
    """游戏内不得出现韩文；含韩文的槽位一律留空，只保留 name_sig 供后续对齐。"""
    return '' if KOREAN.search(value or '') else value


def as_int(values: list):
    return int(values[0]) if values and isinstance(values[0], (int, float)) else None


def parse(path: str, lib) -> dict | None:
    try:
        doc = lib.script(path)
    except Exception:
        return None
    spans = {}
    for item in doc.get('fields') or []:
        spans.setdefault(item['tag'], item['values'])
    if not spans:
        return None
    kind = path.rsplit('.', 1)[-1]
    entry = {'path': path, 'kind': kind}
    numeric = {}
    for tag, key in NUMERIC.items():
        if tag in spans:
            value = as_int(spans[tag])
            if value is not None:
                numeric[key] = value
    entry['stats'] = numeric
    entry['level'] = numeric.pop('level', None)
    entry['rarity'] = numeric.pop('rarity', None)
    entry['grade'] = numeric.pop('grade', None)
    for tag, key in TEXT.items():
        if tag in spans:
            entry[key] = safe(as_text(spans[tag]))
    entry['name_en'] = safe(as_text(spans['[name2]'])) if '[name2]' in spans else ''
    raw = lib.raw(path)
    if raw is not None:
        entry['name_sig'] = hashlib.sha1(raw[0]).hexdigest()[:10]
    icon = spans.get('[icon]')
    if icon and len(icon) >= 2:
        entry['icon'] = {'image': str(icon[0]), 'frame': int(icon[1])}
    field = spans.get('[field image]')
    if field and len(field) >= 2:
        entry['field_image'] = {'image': str(field[0]), 'frame': int(field[1])}
    return entry


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=None)
    parser.add_argument('--kind', default='', help='只处理某类，如 equ / stk / etc')
    parser.add_argument('--limit', type=int, default=0, help='每类最多处理多少条（0=全部）')
    args = parser.parse_args()
    lib = P.open_library(args.library)
    items: list[dict] = []
    failed = 0
    summary_kinds = collections.Counter()
    rarity = collections.Counter()
    try:
        for ext in ('equ', 'stk', 'etc'):
            if args.kind and args.kind != ext:
                continue
            sql = "select path from files where path like ? order by path"
            if args.limit:
                sql += " limit %d" % args.limit
            for row in lib.db.execute(sql, ('%.' + ext,)):
                entry = parse(row[0], lib)
                if entry is None:
                    failed += 1
                    continue
                items.append(entry)
                summary_kinds[ext] += 1
                rarity[str(entry.get('rarity'))] += 1
    finally:
        lib.close()
    with_name = sum(1 for i in items if i.get('name_en'))
    catalog = {
        'schema': 'dnf_item_catalog/1',
        'evidence': '原版 .equ/.stk/.etc 结构字段 E-PARSE；本总账保留名称字节指纹，中文正文另由TextResolver解析',
        'summary': {
            'total': len(items),
            'failed': failed,
            'kinds': dict(summary_kinds),
            'rarity': dict(rarity.most_common()),
            'with_english_name': with_name,
            'limit': args.limit,
        },
        'items': items,
    }
    OUT.write_text(json.dumps(catalog, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('[ITEM_CATALOG] total=%d failed=%d kinds=%s english=%d'
          % (len(items), failed, dict(summary_kinds), with_name))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
