"""从 `.act` 里提取召唤参数（原版 [SUMMON MONSTER] 块）。

反编译出的形态（mirkius/action/summon.act 实测）：

    [BEHAVIOR]
        [RESTORE] [HP] -20 [%]          ← 召唤代价
        [SUMMON MONSTER]
            [INDEX] 61523               ← monster.lst 的索引
            [LEVEL] 0
            [POS] -300 100 0            ← 相对施法者的位置

`[INDEX]` 就是 `monster/monster.lst` 的键（61523 → NewMonsters/RealSky/Minius/Minius.mob），
所以召唤物路径可以直接反查。

输出 `data/summons.json`：act 路径 → [{monster, level, pos}]。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P
from decompile_dnf_ai import decode

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'data/summons.json'


def number(text: str) -> float | None:
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def extract(tokens: list[str]) -> list[dict]:
    summons: list[dict] = []
    for index, text in enumerate(tokens):
        if text != '[SUMMON MONSTER]':
            continue
        entry: dict = {}
        # 往后最多 40 个 token 找 INDEX / LEVEL / POS
        cursor = index + 1
        while cursor < min(len(tokens), index + 40):
            token = tokens[cursor]
            if token == '[/SUMMON MONSTER]':
                break
            if token == '[INDEX]' and cursor + 1 < len(tokens):
                value = number(tokens[cursor + 1])
                if value is not None:
                    entry['index'] = int(value)
                cursor += 2
                continue
            if token == '[LEVEL]' and cursor + 1 < len(tokens):
                value = number(tokens[cursor + 1])
                if value is not None:
                    entry['level'] = int(value)
                cursor += 2
                continue
            if token == '[POS]' and cursor + 3 < len(tokens):
                values = [number(tokens[cursor + k]) for k in range(1, 4)]
                if all(v is not None for v in values):
                    entry['pos'] = [int(v) for v in values]
                cursor += 4
                continue
            cursor += 1
        if 'index' in entry:
            summons.append(entry)
    return summons


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path, default=None)
    parser.add_argument('--limit', type=int, default=0)
    args = parser.parse_args()
    lib = P.open_library(args.library)
    result: dict[str, list] = {}
    unresolved = 0
    try:
        monsters = lib.listing('monster/monster.lst')
        rows = [r[0] for r in lib.db.execute(
            "select path from files where path like 'monster/%' and path like '%.act' order by path")]
        if args.limit:
            rows = rows[:args.limit]
        for path in rows:
            raw = lib.raw(path)
            blob = raw[0] if raw else b''
            decoded = decode(blob, lib.strings)
            if not decoded.get('ok'):
                continue
            tokens = [t['text'].strip() if t['kind'] == 'string' else str(t.get('value'))
                      for t in decoded['tokens']]
            summons = extract(tokens)
            if not summons:
                continue
            resolved = []
            for entry in summons:
                target = monsters.get(entry['index'], '')
                if not target:
                    unresolved += 1
                    continue
                resolved.append({'monster': 'monster/' + target.lower(), 'index': entry['index'],
                                 'level': entry.get('level', 0), 'pos': entry.get('pos', [0, 0, 0])})
            if resolved:
                result[path] = resolved
    finally:
        lib.close()
    OUT.write_text(json.dumps({
        'schema': 'dnf_summons/1',
        'evidence': '.act 的 [SUMMON MONSTER] [INDEX] 是 monster.lst 键，可直接反查路径',
        'count': len(result), 'unresolved': unresolved, 'summons': result,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('[SUMMON] %d 个动作带召唤、未解析索引 %d' % (len(result), unresolved))
    for path, entries in list(result.items())[:6]:
        print('  %-58s %s' % (path.split('/')[-3], [e['monster'].split('/')[-1] for e in entries]))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
