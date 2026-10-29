"""解析原版 `.ptl` 粒子定义，输出可还原的粒子参数。

`.ptl` 与 `.ai`/`.act` 同为 `b0 d0 05` 字节码容器，但用 TAG 式字段（`[move type]` 之类），
字段含义直接可读。实测一个粒子包含：

  发射与寿命   `[life time]`、`[maximum create number]`、`[creation frequency]`
  发射范围     `[create area size]`（x, y, z 半径）
  运动         `[move type]`（straight line 等）、`[move variable 1]`（速度上下限）、
               `[gravity]`、`[changing term]`/`[changing type]`
  外观         `[object type]`（animation）、`[object]`（ANI 路径列表 + 权重）、
               `[transparent value]`（起始/结束透明度）、
               `[rotation angle variable]`、`[rotation angle range type]`、
               `[random range]`

输出 `data/particles.json`：每个 `.ptl` 的参数 + 它引用的 ANI（供烘焙图集）。

用法：python tools/build_dnf_particles.py [--library DIR] [--limit N]
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
OUT = GAME / 'data/particles.json'
# 覆盖音节、字母、兼容字母三种韩文字符区。
KOREAN = re.compile(r'[\uac00-\ud7af\u1100-\u11ff\u3130-\u318f]')

SCALARS = {
    '[life time]': 'life_ms',
    '[maximum create number]': 'max_count',
    '[creation frequency]': 'frequency',
    '[gravity]': 'gravity',
    '[changing term]': 'change_ms',
}
LISTS = {
    '[move variable 1]': 'speed',
    '[transparent value]': 'alpha',
    '[create area size]': 'area',
    '[rotation angle variable]': 'rotation',
    '[display effect rate]': 'rate',
}
TEXTS = {
    '[move type]': 'move_type',
    '[landing type]': 'landing',
    '[changing type]': 'change_type',
    '[object type]': 'object_type',
    '[rotation angle range type]': 'rotation_type',
}


def one(spans: dict, tag: str, default=None):
    item = spans.get(tag)
    if not item:
        return default
    values = item[0]
    return values[0] if values else default


def many(spans: dict, tag: str) -> list:
    item = spans.get(tag)
    return list(item[0]) if item else []


def parse(path: str, doc: dict) -> dict | None:
    spans: dict[str, list] = {}
    for item in doc.get('fields') or []:
        spans.setdefault(item['tag'], []).append(item['values'])
    if not spans:
        return None
    entry: dict = {'ptl': path}
    for tag, key in SCALARS.items():
        value = one(spans, tag)
        if isinstance(value, (int, float)):
            entry[key] = value
    for tag, key in LISTS.items():
        values = [v for v in many(spans, tag) if isinstance(v, (int, float))]
        if values:
            entry[key] = values
    for tag, key in TEXTS.items():
        value = one(spans, tag)
        # 游戏内不允许韩文：含韩文的字段丢弃（多为原版内部标签）。
        if isinstance(value, str) and not KOREAN.search(value):
            entry[key] = value.strip('[]')
    # [object] 是 ANI 路径与权重交替出现（路径, -1, 路径, -1 …）
    folder = str(PurePosixPath(path).parent)
    animations = []
    for value in many(spans, '[object]'):
        if isinstance(value, str) and value.lower().endswith('.ani'):
            animations.append(resolve(folder, value))
    if animations:
        entry['animations'] = animations
    return entry if len(entry) > 1 else None


def resolve(folder: str, relative: str) -> str:
    """把 `../Animation/X.ani` 形式的相对路径解成库内绝对路径。"""
    parts = (folder + '/' + relative.replace('\\', '/')).split('/')
    stack: list[str] = []
    for part in parts:
        if part in ('', '.'):
            continue
        if part == '..':
            if stack:
                stack.pop()
            continue
        stack.append(part)
    return '/'.join(stack).lower()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path, default=None)
    parser.add_argument('--limit', type=int, default=0)
    args = parser.parse_args()
    lib = P.open_library(args.library)
    result: dict[str, dict] = {}
    failed = 0
    animations: set[str] = set()
    try:
        rows = [r[0] for r in lib.db.execute(
            "select path from files where path like '%.ptl' order by path")]
        if args.limit:
            rows = rows[:args.limit]
        for path in rows:
            try:
                doc = lib.script(path)
            except Exception:
                failed += 1
                continue
            entry = parse(path, doc) if doc else None
            if entry is None:
                failed += 1
                continue
            result[path] = entry
            animations.update(entry.get('animations') or [])
    finally:
        lib.close()
    OUT.write_text(json.dumps({
        'schema': 'dnf_particles/1',
        'evidence': '.ptl 为 b0d005 容器 + TAG 字段；[object] 指向 ANI 序列帧',
        'count': len(result), 'failed': failed,
        'animations': len(animations), 'particles': result,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    with_move = sum(1 for v in result.values() if v.get('move_type'))
    print('[PTL] 解析 %d 个粒子（失败 %d），带运动类型 %d，引用 ANI %d 个'
          % (len(result), failed, with_move, len(animations)))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
