"""解析原版怪物数值表 `monster/*monsterbaseparameter.tbl`。

格式（实测）：`b0 d0 02` 魔数 + 4 字节头（BOSS/普通表是 1，chaos 表是起始 ID）+ 定长 5 字节记录
`02 <int32>`。BOSS/普通表共 4799 个整数 = **24 列 × 199 行**（尾部 23 个残留），
首列是等级（5, 10, 15 …，每 5 级一行）。

列含义（E-INFER，依据与 `.mob` 的 `[ability category]` 交叉验证）：
  0-3  等级（同一行重复 4 次，疑为 4 个难度档共用同行）
  4    HP MAX %          5  物理攻击 %
  6-9  物理/魔法防御 %    10+  其余留空或少量标记

用途：`.mob` 的 ability 就是这张表对应行的值；部分怪（如 tauarmy）mob 里没写全，
可用本表按等级补全。输出 `data/monster_tables.json`。

用法：python tools/build_dnf_monster_tables.py [--library DIR]
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'data/monster_tables.json'
TABLES = {
    'boss': 'monster/bossmonsterbaseparameter.tbl',
    'common': 'monster/commonmonsterbaseparameter.tbl',
    'named': 'monster/namedmonsterbaseparameter.tbl',
    'summon': 'monster/summonmonsterbaseparameter.tbl',
    'chaos': 'monster/chaosmonsterbaseparameter.tbl',
    # 等级 → 基准值（11 列 99 行）：列7/9 = 150/300/450… 等差 +150，推断为 HP 基准；
    # 列4/5 二阶递增（50/74/101/133…），推断为经验。这张表才是"基准值"的真源。
    'base': 'monster/monsterbaseparameter.tbl',
    'warroom': 'monster/warroommonsterbaseparameter.tbl',
    'apc_bonus': 'monster/monsterapcdifficultybonus.tbl',
}
# 各表的列数不同：base 11 列、其余 24 列；apc_bonus 是 float 表（魔数 b0d004）。
COLUMNS = {'base': 11, 'warroom': 12}
DEFAULT_COLUMNS = 24


def parse(blob: bytes, columns: int = DEFAULT_COLUMNS) -> dict:
    """整数表魔数 `b0 d0 02`，浮点表魔数 `b0 d0 04`；两者都是 4 字节头 + 5 字节记录。"""
    if len(blob) < 8:
        return {'ok': False, 'reason': 'short'}
    head = blob[:3]
    if head not in (b'\xb0\xd0\x02', b'\xb0\xd0\x04'):
        return {'ok': False, 'reason': 'magic %s' % head.hex()}
    is_float = head == b'\xb0\xd0\x04'
    header = struct.unpack('<i', blob[3:7])[0]
    body = blob[7:]
    if is_float:
        values = [round(struct.unpack('<f', body[i + 1:i + 5])[0], 4) for i in range(0, len(body) - 4, 5)]
    else:
        values = [struct.unpack('<i', body[i + 1:i + 5])[0] for i in range(0, len(body) - 4, 5)]
    rows = len(values) // columns
    table = []
    for index in range(rows):
        cell = values[index * columns:(index + 1) * columns]
        row = {'raw': cell}
        if not is_float and columns == DEFAULT_COLUMNS:
            row.update({'level': cell[0], 'hp_pct': cell[4], 'attack_pct': cell[5],
                        'physical_defense_pct': cell[6], 'magical_defense_pct': cell[8]})
        elif not is_float and columns == 11:
            # base 表：列1/3 等级区间、列4/5 经验、列7/9 基准值（推断）。
            row.update({'from_level': cell[1], 'to_level': cell[3],
                        'experience': cell[4], 'base_value': cell[7]})
        table.append(row)
    return {'ok': True, 'float': is_float, 'header': header, 'values': len(values),
            'columns': columns, 'rows': rows, 'trailing': values[rows * columns:], 'table': table}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path, default=None)
    args = parser.parse_args()
    lib = P.open_library(args.library)
    result: dict[str, dict] = {}
    try:
        for name, path in TABLES.items():
            if not lib.exists(path):
                result[name] = {'ok': False, 'reason': 'missing'}
                continue
            raw = lib.raw(path)
            result[name] = parse(raw[0] if raw else b'', COLUMNS.get(name, DEFAULT_COLUMNS))
    finally:
        lib.close()
    OUT.write_text(json.dumps({
        'schema': 'dnf_monster_tables/1',
        'evidence': 'b0d002 + 4 字节头 + 5 字节记录（02+int32）；24 列，首列等级每 5 级一行',
        'tables': result,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    for name, table in result.items():
        if not table.get('ok'):
            print('[TABLE] %-9s 解析失败 %s' % (name, table.get('reason')))
            continue
        first, last = table['table'][0], table['table'][-1]
        if 'level' in first:
            print('[TABLE] %-9s 行 %-3d 列 %d 等级 %s..%s  首行 hp%%=%s atk%%=%s'
                  % (name, table['rows'], table['columns'], first['level'], last['level'],
                     first['hp_pct'], first['attack_pct']))
        else:
            print('[TABLE] %-9s 行 %-3d 列 %d 等级 %s..%s  首行 base=%-6s exp=%s%s'
                  % (name, table['rows'], table['columns'], first.get('from_level'), last.get('from_level'),
                     first.get('base_value'), first.get('experience'), '（float 表）' if table.get('float') else ''))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
