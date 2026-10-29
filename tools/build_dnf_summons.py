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


def resolve_path(base_file: str, relative: str) -> str:
    """`../Animation/Down.ani` → 库内绝对路径（相对 .act 所在目录）。"""
    parts: list[str] = []
    for part in (str(Path(base_file).parent).replace('\\', '/') + '/' + relative.replace('\\', '/')).split('/'):
        if part in ('', '.'):
            continue
        if part == '..':
            if parts:
                parts.pop()
            continue
        parts.append(part)
    return '/'.join(parts).lower()


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
                base_ani = ''
                for cursor, text in enumerate(tokens):
                    if text == '[BASE ANI]' and cursor + 1 < len(tokens):
                        base_ani = resolve_path(path, tokens[cursor + 1])
                        break
                result[path] = {'summons': resolved, 'ani': base_ani,
                                'stem': Path(path).stem.lower()}
    finally:
        lib.close()
    # 两套索引：按动作 ANI 精确匹配（优先），按动作名 stem（兜底）。
    by_ani = {v['ani']: v['summons'] for v in result.values() if v['ani']}
    by_stem: dict[str, list] = {}
    for value in result.values():
        by_stem.setdefault(value['stem'], value['summons'])
    OUT.write_text(json.dumps({
        'schema': 'dnf_summons/2',
        'evidence': '.act 的 [SUMMON MONSTER] [INDEX] 是 monster.lst 键；[BASE ANI] 给出该动作的 ANI',
        'count': len(result), 'unresolved': unresolved,
        'by_ani': by_ani, 'by_stem': by_stem, 'actions': result,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('[SUMMON] %d 个动作带召唤（ANI 索引 %d、stem 索引 %d）、未解析索引 %d'
          % (len(result), len(by_ani), len(by_stem), unresolved))
    for path, value in list(result.items())[:6]:
        print('  %-52s %s -> %s' % (path.split('/')[-3], value['stem'],
                                    [e['monster'].split('/')[-1] for e in value['summons']]))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
