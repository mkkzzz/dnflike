"""把原版 `.ai` / `.act` 字节码还原成可读脚本。

格式：`b0 d0 05` + 4 字节基址 + 5 字节定长指令 `[opcode:1][arg:4]`。

关键：**多数 opcode 的参数是 stringtable 索引**，解出来就是脚本关键字/字面量：

    op05 509 → '[think]'                     op05 511 → 'is the skill in cooltime()'
    op05 513 → 'is target in attack area()'  op05 536 → '[target distance]'
    op05 712 → '[HP]'                        op05 719 → '[BEHAVIOR]'
    op05 865 → '[DO BEHAVIOR]'               op05 1743 → '[SUMMON MONSTER]'
    op07 1292 → '../Animation/Stay.ani'      op07 301397 → '../Animation_Kinol/Attack1.ani'

    op02 <int32>   整数常量
    op04 <float32> 浮点常量

因此 `.ai`/`.act` 是**可完整还原的文本脚本**，不是不可解析的字节码。

用法：
  python tools/decompile_dnf_ai.py --mob goblin --text          # 打印可读脚本
  python tools/decompile_dnf_ai.py --dump --ids lakius,mirkius  # 导出到 docs/reverse/
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
OUT = GAME / 'data/ai_scripts.json'
DOCS = ROOT / 'docs/reverse'
MAGIC = b'\xb0\xd0\x05'
STRIDE = 5
# 这些 opcode 的参数是 stringtable 索引
STRING_OPS = {0x05, 0x07, 0x09, 0x0a, 0x0b, 0x0c}


def decode(blob: bytes, strings) -> dict:
    if not blob.startswith(MAGIC):
        return {'ok': False, 'reason': 'magic'}
    body = blob[len(MAGIC) + 4:]
    if len(body) % STRIDE != 0:
        return {'ok': False, 'reason': 'stride %d' % (len(body) % STRIDE)}
    tokens: list[dict] = []
    for offset in range(0, len(body), STRIDE):
        opcode = body[offset]
        raw = body[offset + 1:offset + STRIDE]
        if opcode in STRING_OPS:
            index = struct.unpack('<i', raw)[0]
            try:
                text = strings.get(index)
            except Exception:
                text = ''
            tokens.append({'op': opcode, 'at': offset, 'kind': 'string',
                           'index': index, 'text': text})
        elif opcode == 0x04:
            tokens.append({'op': opcode, 'at': offset, 'kind': 'float',
                           'value': round(struct.unpack('<f', raw)[0], 4)})
        elif opcode == 0x02:
            tokens.append({'op': opcode, 'at': offset, 'kind': 'int',
                           'value': struct.unpack('<i', raw)[0]})
        else:
            tokens.append({'op': opcode, 'at': offset, 'kind': 'unknown', 'raw': raw.hex()})
    return {'ok': True, 'tokens': tokens,
            'text': render(tokens)}


def render(tokens: list[dict], indent: bool = True) -> str:
    """按原版脚本习惯缩进：`[...]` 块开始 +1、`[/...]` 块结束 -1。"""
    lines: list[str] = []
    depth = 0
    for token in tokens:
        if token['kind'] == 'string':
            text = token['text'].strip()
            if text.startswith('[/'):
                depth = max(0, depth - 1)
                lines.append('    ' * depth + text)
                continue
            lines.append('    ' * depth + text)
            if text.startswith('[') and not text.startswith('[/') and text.endswith(']') \
                    and text not in ('[ME]', '[HP]', '[%]', '[target distance]', '[last result]'):
                depth += 1
        elif token['kind'] == 'float':
            lines.append('    ' * depth + ('%g' % token['value']))
        else:
            lines.append('    ' * depth + str(token.get('value')))
    return '\n'.join(lines)


def targets(lib, keyword: str, kinds=('ai', 'act')) -> list[str]:
    rows: list[str] = []
    for kind in kinds:
        rows.extend(r[0] for r in lib.db.execute(
            "select path from files where path like ? and path like ? order by path",
            ('%' + keyword + '%', '%%.' + kind)))
    return sorted(set(rows))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path, default=None)
    parser.add_argument('--mob', default='')
    parser.add_argument('--ids', default='')
    parser.add_argument('--text', action='store_true', help='打印可读脚本')
    parser.add_argument('--dump', action='store_true', help='导出到 data/ai_scripts.json 与 docs/reverse/')
    parser.add_argument('--act', action='store_true', help='同时处理 .act')
    parser.add_argument('--limit', type=int, default=0)
    args = parser.parse_args()
    lib = P.open_library(args.library)
    try:
        kinds = ('ai', 'act') if args.act else ('ai',)
        names = [n for n in (args.ids or args.mob).split(',') if n]
        paths: list[str] = []
        for name in names:
            paths.extend(targets(lib, name, kinds))
        if not paths:
            paths = targets(lib, '', kinds)
        if args.limit:
            paths = paths[:args.limit]
        result: dict[str, dict] = {}
        for path in paths:
            raw = lib.raw(path)
            blob = raw[0] if raw else b''
            decoded = decode(blob, lib.strings)
            decoded['bytes'] = len(blob)
            result[path] = decoded
            if args.text or (names and not args.dump):
                print('\n===== %s (%d bytes)\n%s' % (path, len(blob), decoded.get('text', '')))
        if args.dump:
            ok = sum(1 for v in result.values() if v.get('ok'))
            OUT.parent.mkdir(parents=True, exist_ok=True)
            OUT.write_text(json.dumps({
                'schema': 'dnf_ai_scripts/1',
                'evidence': 'op05/0x07/0x09 参数为 stringtable 索引 → 脚本关键字；op02=int、op04=float',
                'count': len(result), 'decoded': ok, 'scripts': result,
            }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
            # 把有内容的脚本单独落一份可读文本，便于直接读
            DOCS.mkdir(parents=True, exist_ok=True)
            written = 0
            for path, entry in result.items():
                if not entry.get('ok') or not (entry.get('text') or '').strip():
                    continue
                target = DOCS / (path.replace('/', '_') + '.txt')
                target.write_text('# %s\n\n%s\n' % (path, entry['text']), encoding='utf-8')
                written += 1
            print('\n[AI] 反编译 %d 个脚本（成功 %d），导出 %d 份可读文本 → %s'
                  % (len(result), ok, written, DOCS))
        return 0
    finally:
        lib.close()


if __name__ == '__main__':
    raise SystemExit(main())
