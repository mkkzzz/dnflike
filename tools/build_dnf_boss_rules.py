"""从反编译的 `.ai` 脚本里提取 BOSS 的选招规则（原版逻辑，不是模板）。

脚本形态（mirkius/action.ai 实测）：

    [think] [void]
        number of in attack area()  10000 10000 10000 10000  all  summon  61523
        [think]
            [last result] == 0
            [true]   →  checkup 技能 4 冷却 → [return] 4
            [false]  →  is target in attack area() 200 200 30 30
                         →  checkup 技能 2 冷却 → [return] 2
                         →  否则 [return] -1

提取方式（不建完整解释器，按块回溯）：
  每个 `[return] N`（N >= 0）向上找最近的
    ① `is target in attack area() x y z w` → 该招的触发范围
    ② `is the skill in cooltime() N`        → 该招的编号
  若找不到范围，则记为该 BOSS 的默认招（原版常用于远距离/无条件分支）。

输出 `data/boss_rules.json`：mob → [{skill, area, cooldown_checked}]。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'data/boss_rules.json'
BOSS_MOVES = GAME / 'data/boss_moves.json'
MAGIC = b'\xb0\xd0\x05'
STRIDE = 5


def tokens_of(lib, path: str) -> list[str]:
    """把脚本切成字符串 token 序列（数字也转成字符串，便于按位置回溯）。"""
    raw = lib.raw(path)
    blob = raw[0] if raw else b''
    if not blob.startswith(MAGIC):
        return []
    body = blob[len(MAGIC) + 4:]
    out: list[str] = []
    for offset in range(0, len(body) - 4, STRIDE):
        opcode = body[offset]
        if opcode in (0x05, 0x07, 0x09, 0x0a, 0x0b, 0x0c):
            index = int.from_bytes(body[offset + 1:offset + 5], 'little', signed=True)
            try:
                out.append(lib.strings.get(index).strip())
            except Exception:
                out.append('')
        elif opcode == 0x04:
            import struct
            out.append('%g' % round(struct.unpack('<f', body[offset + 1:offset + 5])[0], 3))
        elif opcode == 0x02:
            out.append(str(int.from_bytes(body[offset + 1:offset + 5], 'little', signed=True)))
        else:
            out.append('?')
    return out


def number(text: str) -> float | None:
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def extract(tokens: list[str]) -> list[dict]:
    """从 token 序列里抽 (技能号, 触发范围) 规则。

    做法：以 `is target in attack area()` 为锚点向下找该分支的第一个 `[return] N`；
    没有 area 的 `[return] N` 视为无条件（最高优先级）分支。
    """
    rules: list[dict] = []
    covered: set[int] = set()
    for index, token in enumerate(tokens):
        if token != 'is target in attack area()':
            continue
        values = [number(tokens[index + k]) for k in range(1, 5)]
        area = [int(v) for v in values] if all(v is not None for v in values) else []
        for forward in range(index + 5, min(len(tokens), index + 45)):
            if tokens[forward] != '[return]':
                continue
            skill = number(tokens[forward + 1]) if forward + 1 < len(tokens) else None
            if skill is not None and skill >= 0:
                rules.append({'skill': int(skill), 'area': area, 'cooldown_checked': True})
                covered.add(forward)
                break
            # skill < 0 表示“该技能冷却中，本分支不出手”，继续找同分支真正的 [return] N。
    # 无条件分支：前面没有 area 锚点的 [return] N（原版常见于“大招冷却好就放”）
    for index, token in enumerate(tokens):
        if token != '[return]' or index in covered or index + 1 >= len(tokens):
            continue
        skill = number(tokens[index + 1])
        if skill is None or skill < 0:
            continue
        head = tokens[max(0, index - 12):index]
        if 'is target in attack area()' in head:
            continue
        rules.append({'skill': int(skill), 'area': [], 'cooldown_checked': 'is the skill in cooltime()' in head})
    # 同一技能号只保留第一次（原版脚本里同一招可能被多处引用）
    seen: set[int] = set()
    unique: list[dict] = []
    for rule in rules:
        if rule['skill'] in seen:
            continue
        seen.add(rule['skill'])
        unique.append(rule)
    return unique


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path, default=None)
    parser.add_argument('--all', action='store_true', help='扫描全部 .ai（默认只扫副本 BOSS）')
    args = parser.parse_args()
    moves = json.loads(BOSS_MOVES.read_text(encoding='utf-8'))['bosses'] if BOSS_MOVES.is_file() else {}
    lib = P.open_library(args.library)
    result: dict[str, dict] = {}
    try:
        if args.all:
            rows = [r[0] for r in lib.db.execute(
                "select path from files where path like 'monster/%' and path like '%.ai' "
                "and path like '%/action.ai' order by path")]
        else:
            rows = []
            for mob in moves:
                stem = Path(mob).stem
                rows.extend(r[0] for r in lib.db.execute(
                    "select path from files where path like ? and path like '%/action.ai'",
                    ('%/' + stem + '/ai/action.ai',)))
        for path in rows:
            tokens = tokens_of(lib, path)
            if not tokens:
                continue
            rules = extract(tokens)
            if rules:
                result[path] = {'script': path, 'rules': rules}
    finally:
        lib.close()
    # 运行时按怪物名（mob 文件名，不含扩展名）查规则：
    # 脚本路径 monster/.../<name>/ai/action.ai 的倒数第三段就是怪物名。
    index: dict[str, list] = {}
    for path, entry in result.items():
        parts = path.split('/')
        name = parts[-3] if len(parts) >= 3 else ''
        if not name or name in index:
            continue
        # 无条件分支（如“大招冷却好就放”）优先，其余按原版距离由近到远。
        rules = sorted(entry['rules'], key=lambda r: (0 if not r['area'] else 1, r['area'][0] if r['area'] else 0))
        index[name] = rules
    OUT.write_text(json.dumps({
        'schema': 'dnf_boss_rules/1',
        'evidence': '由 .ai 反编译脚本提取：is target in attack area(x,y,z,w) + [return] 技能号',
        'count': len(result), 'index': index, 'bosses': result,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('[RULES] 提取 %d 份脚本的选招规则' % len(result))
    for path, entry in list(result.items())[:6]:
        print('  %-52s %s' % (path.split('/')[-3], [(r['skill'], r['area']) for r in entry['rules']]))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
