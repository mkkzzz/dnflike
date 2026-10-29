"""把指定怪物切换到新版（newmonsters）架构，同时保留老版数值。

用法：
  python tools/switch_monster_version.py --list                 # 列出可切换的怪
  python tools/switch_monster_version.py --switch mirkius       # 切换（幂等）

做法：在 data/combat.json 的 monsters 条目里补两个字段——
  ``mob``       新版 mob 路径（动作在 action/*.act、AI 在 ai/*.ai）
  ``stats_mob`` 老版 mob 路径（level/hp/attack/speed/sight 仍取老版）
图集沿用老版烘焙结果（两版共用同一批 IMG，外观一致）。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
COMBAT = GAME / 'data/combat.json'
DUNGEONS = GAME / 'data/dungeons.json'


def used_mobs() -> set[str]:
    dungeons = json.loads(DUNGEONS.read_text(encoding='utf-8'))['dungeons']
    out: set[str] = set()
    for spec in dungeons.values():
        export = spec.get('map_export', '')
        if not export:
            continue
        path = GAME / export.replace('res://', '')
        if not path.is_file():
            continue
        data = json.loads(path.read_text(encoding='utf-8'))
        for room in (data.get('dungeon', {}).get('rooms') or {}).values():
            for monster in room.get('monsters') or []:
                if monster.get('mob'):
                    out.add(str(monster['mob']).lower())
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--library', type=Path, default=None)
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--switch', default='', help='怪物名（不含扩展名），逗号分隔')
    args = parser.parse_args()
    lib = P.open_library(args.library)
    try:
        new_mobs: dict[str, str] = {}
        for row in lib.db.execute(
                "select path from files where path like 'monster/newmonsters/%.mob' order by path"):
            path = row[0]
            new_mobs.setdefault(PurePosixPath(path).stem.lower(), path)
        used = used_mobs()
        candidates = [(PurePosixPath(m).stem.lower(), m, new_mobs[PurePosixPath(m).stem.lower()])
                      for m in sorted(used) if PurePosixPath(m).stem.lower() in new_mobs]
        if args.list:
            print('[SWITCH] 可切换 %d / %d 种' % (len(candidates), len(used)))
            for stem, old, new in candidates:
                folder = str(PurePosixPath(new).parent)
                has_ai = lib.db.execute(
                    "select count(1) from files where path like ?", (folder + '/ai/%.ai',)).fetchone()[0] > 0
                print('  %-22s ai=%-5s %s' % (stem, has_ai, new))
            return 0
        names = [n.strip().lower() for n in args.switch.split(',') if n.strip()]
        if not names:
            print('需要 --switch 或 --list')
            return 1
        doc = json.loads(COMBAT.read_text(encoding='utf-8'))
        mapping = doc['monsters']
        changed = 0
        for stem, old, new in candidates:
            if stem not in names:
                continue
            # 找到该老版 mob 对应的映射条目
            hits = [key for key, value in mapping.items()
                    if str(value.get('mob', '')).lower() == old]
            for key in hits:
                mapping[key]['mob'] = new
                mapping[key]['stats_mob'] = old
                changed += 1
                print('  [OK] %-22s %s -> %s（数值仍用 %s）'
                      % (key, old, new, old))
        if changed:
            COMBAT.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
        else:
            print('没有匹配到要切换的怪：%s' % names)
        return 0
    finally:
        lib.close()


if __name__ == '__main__':
    raise SystemExit(main())
