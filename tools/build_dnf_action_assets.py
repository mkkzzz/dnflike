"""解析 `.act`（动作资产定义），输出「动作 → ANI / 装备动画 / 音效」映射。

已解出的格式与语义（证据完整）：
  文件 = `b0 d0 05` + 4 字节基址 + 5 字节定长指令
  `0x02 <int32>`   整数参数
  `0x04 <float32>` 浮点参数
  `0x07 <idx>`     **stringtable 索引**，实测解出：
                     `../Animation_Kinol/Attack1.ani`      ← 该动作的 ANI
                     `../Animation/Damage1.ani` / `Stay.ani`
                     `../../../equipment/monster/goblin/LKinolPantsAnimation/move_`  ← 装备动画
                     `../../../equipment/monster/goblin/weapon09-animation/move_10`  ← 武器动画
                     `speech_on_situation_610` / `throw` / `Dcount`  ← 语义 key
  `0x09 / 0x0a <idx>` 条件与音效/台词 key

因此 `.act` **不是 AI 行为脚本，而是动作资产定义**（ANI + 装备层 + 武器层 + 音效）。
输出 `data/action_assets.json`，供运行时按动作播放正确的音效与分层动画。

用法：python tools/build_dnf_action_assets.py [--library DIR] [--limit N]
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from pathlib import Path, PurePosixPath

# 游戏内不允许韩文：含韩文的字符串一律丢弃（多为原版内部 key，无运行时用途）。
KOREAN = re.compile(r'[\uac00-\ud7af\u1100-\u11ff]')


def safe(text: str) -> str:
    return '' if KOREAN.search(text or '') else text

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'data/action_assets.json'
MAGIC = b'\xb0\xd0\x05'
STRIDE = 5


def parse(path: str, blob: bytes, strings) -> dict:
    body = blob[7:]
    entry = {'act': path, 'base': struct.unpack('<i', blob[3:7])[0],
             'animation': '', 'equipment': [], 'weapon': [], 'keys': [], 'sounds': [], 'ints': [], 'floats': []}
    for offset in range(0, len(body) - 4, STRIDE):
        opcode = body[offset]
        if opcode == 0x04:
            entry['floats'].append(round(struct.unpack('<f', body[offset + 1:offset + 5])[0], 3))
            continue
        value = struct.unpack('<i', body[offset + 1:offset + 5])[0]
        if opcode == 0x02:
            entry['ints'].append(value)
            continue
        if opcode not in (0x07, 0x09, 0x0a):
            continue
        try:
            text = strings.get(int(value))
        except Exception:
            continue
        text = safe(text)
        if not text:
            continue
        lowered = text.lower()
        if lowered.endswith('.ani'):
            if entry['animation'] == '':
                entry['animation'] = text
        elif 'equipment/' in lowered or lowered.endswith('animation/move_'):
            entry['equipment' if 'weapon' not in lowered else 'weapon'].append(text)
        elif opcode == 0x0a:
            entry['sounds'].append(text)
        else:
            entry['keys'].append(text)
    return entry


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path, default=None)
    parser.add_argument('--limit', type=int, default=0)
    args = parser.parse_args()
    lib = P.open_library(args.library)
    result: dict[str, dict] = {}
    try:
        rows = [r[0] for r in lib.db.execute(
            "select path from files where path like 'monster/%' and path like '%.act' order by path")]
        if args.limit:
            rows = rows[:args.limit]
        failed = 0
        for path in rows:
            raw = lib.raw(path)
            blob = raw[0] if raw else b''
            if not blob.startswith(MAGIC) or (len(blob) - 7) % STRIDE != 0:
                failed += 1
                continue
            entry = parse(path, blob, lib.strings)
            if entry['animation'] or entry['sounds'] or entry['keys']:
                result[path] = entry
    finally:
        lib.close()
    OUT.write_text(json.dumps({
        'schema': 'dnf_action_assets/1',
        'evidence': '.act = b0d005 + 4 字节基址 + 5 字节指令；0x07 = stringtable 索引（ANI/装备/武器/语义 key）',
        'count': len(result), 'failed': failed, 'actions': result,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    with_ani = sum(1 for v in result.values() if v['animation'])
    with_sound = sum(1 for v in result.values() if v['sounds'])
    print('[ACTION] 解析 %d 个 .act（失败 %d）：有 ANI %d、有音效 %d'
          % (len(result), failed, with_ani, with_sound))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
