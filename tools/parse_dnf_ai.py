"""反汇编原版 `.ai` 字节码（BOSS 行为脚本），把指令流与常量表导出来。

为什么能反汇编：去掉 4 字节魔数 `b0 d0 05 fc` 与 3 字节头之后，字节数恰好是 5 的整数倍，
每条指令都是 `[opcode:1][arg:4]` 定长。参数含义按实测区分：

  - `0x02` + int32   整数常量（10000、-1、4…）
  - `0x04` + float32 浮点常量（200.0、30.0、110.0…）—— 距离/速度/概率这类阈值
  - `0x05` / `0x07` + int32  索引（509/510/783…），成对出现，疑为操作数/跳转目标

仍未知的是 opcode 的**语义**（哪个是条件、哪个是调用）。本工具只做无损反汇编与统计，
不臆造语义；输出用于①对比不同 BOSS 的阈值差异 ②后续逆向的基线。

用法：
  python tools/parse_dnf_ai.py --list                 # 列出有 .ai 的怪
  python tools/parse_dnf_ai.py --mob lakius           # 反汇编某只怪的全部 .ai
  python tools/parse_dnf_ai.py --dump-all             # 全量导出到 data/ai_program.json
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
OUT = GAME / 'data/ai_program.json'
MAGIC = b'\xb0\xd0\x05\xfc'
HEADER = 3
STRIDE = 5
INT_OPS = {0x02}
FLOAT_OPS = {0x04}
INDEX_OPS = {0x05, 0x07}


def decode(blob: bytes) -> dict:
    """把一个 .ai 文件切成指令序列。"""
    if not blob.startswith(MAGIC):
        return {'ok': False, 'reason': 'magic mismatch'}
    body = blob[len(MAGIC) + HEADER:]
    if len(body) % STRIDE != 0:
        return {'ok': False, 'reason': 'body %d not multiple of %d' % (len(body), STRIDE)}
    instructions = []
    for offset in range(0, len(body), STRIDE):
        opcode = body[offset]
        raw = body[offset + 1:offset + STRIDE]
        item = {'op': opcode, 'at': offset}
        if opcode in FLOAT_OPS:
            item['kind'] = 'float'
            item['value'] = round(struct.unpack('<f', raw)[0], 4)
        elif opcode in INT_OPS:
            item['kind'] = 'int'
            item['value'] = struct.unpack('<i', raw)[0]
        elif opcode in INDEX_OPS:
            item['kind'] = 'index'
            item['value'] = struct.unpack('<i', raw)[0]
        else:
            item['kind'] = 'unknown'
            item['raw'] = raw.hex()
        instructions.append(item)
    counts = Counter(i['op'] for i in instructions)
    return {'ok': True, 'instructions': instructions,
            'ops': {'0x%02x' % k: v for k, v in sorted(counts.items())},
            'floats': [i['value'] for i in instructions if i['kind'] == 'float'],
            'ints': [i['value'] for i in instructions if i['kind'] == 'int']}


def ai_files(lib, keyword: str = '') -> list[str]:
    if keyword:
        rows = [r[0] for r in lib.db.execute(
            "select path from files where path like ? and path like '%.ai' order by path",
            ('%' + keyword + '%',))]
    else:
        rows = [r[0] for r in lib.db.execute(
            "select path from files where path like 'monster/%' and path like '%.ai' order by path")]
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path, default=None)
    parser.add_argument('--mob', default='')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--dump-all', action='store_true')
    parser.add_argument('--limit', type=int, default=0)
    args = parser.parse_args()
    lib = P.open_library(args.library)
    try:
        targets = ai_files(lib, args.mob)
        if args.list:
            owners = Counter(path.split('/animal')[0].rsplit('/ai/', 1)[0] for path in targets)
            print('[AI] 共 %d 个 .ai，涉及 %d 个怪' % (len(targets), len(owners)))
            for owner, count in owners.most_common(20):
                print('  %-58s %d' % (owner, count))
            return 0
        if args.limit:
            targets = targets[:args.limit]
        programs = {}
        for path in targets:
            raw = lib.raw(path)
            blob = raw[0] if raw else b''
            decoded = decode(blob)
            decoded['bytes'] = len(blob)
            programs[path] = decoded
            if args.mob:
                print('\n== %s  %d bytes  ops=%s' % (path, len(blob), decoded.get('ops')))
                if decoded.get('ok'):
                    for item in decoded['instructions'][:24]:
                        print('   %04x  %-8s %s' % (item['at'], item['kind'], item.get('value', item.get('raw'))))
                    if len(decoded['instructions']) > 24:
                        print('   ... 共 %d 条指令' % len(decoded['instructions']))
                else:
                    print('   解码失败：%s' % decoded.get('reason'))
        if args.dump_all:
            OUT.write_text(json.dumps({
                'schema': 'dnf_ai_program/1',
                'evidence': '魔数 b0d005fc + 3 字节头 + 5 字节定长指令；02=int32 04=float32 05/07=索引',
                'count': len(programs), 'programs': programs,
            }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
            ok = sum(1 for p in programs.values() if p.get('ok'))
            print('\n[AI] 导出 %d 个程序（解码成功 %d）→ %s' % (len(programs), ok, OUT))
        return 0
    finally:
        lib.close()


if __name__ == '__main__':
    raise SystemExit(main())
