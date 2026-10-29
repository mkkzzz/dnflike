"""把副本里出现的怪补进 `data/combat.json` 的 monsters 映射。

运行时 `main.gd` 用 `table.monster_by_mob(mob)` 反查外观，查不到就 `continue`——
房间里的怪会被静默跳过。本工具按 `data/monster_catalog.json` 给"有动作表、
能被 `build_dnf_combat_assets.py` 烘出图集"的怪补映射（key/bank 与构建产物同名），
已有映射一律保留。

用法：python tools/sync_dnf_monster_mapping.py [--dry-run]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
COMBAT = GAME / 'data/combat.json'
CATALOG = GAME / 'data/monster_catalog.json'
DUNGEONS = GAME / 'data/dungeons.json'

# 手写条目（build_dnf_combat_assets.MONSTERS）用的 key；同名 mob 不重复加。
BUILTIN = {
    'monster/goblin/goblin.mob': 'goblin',
    'monster/goblin/goblinthrower.mob': 'goblin_thrower',
    'monster/tau/tauarmy.mob': 'tau_army',
    'monster/tau/taubeast.mob': 'tau_beast',
    'monster/lugaru/lugaru.mob': 'lugaru',
    'monster/lugaru/kurogaru.mob': 'kurogaru',
    'monster/goblin/seagab.mob': 'goblin_ice',
    'monster/goblin/hillgab.mob': 'goblin_fire',
    'monster/goblin/goblintaskmaster.mob': 'goblin_taskmaster',
    'monster/goblin/goblinthrowertaskmaster.mob': 'goblin_thrower_taskmaster',
}


def needed_mobs() -> set[str]:
    out: set[str] = set()
    dungeons = json.loads(DUNGEONS.read_text(encoding='utf-8'))['dungeons']
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    catalog = json.loads(CATALOG.read_text(encoding='utf-8'))['monsters']
    combat = json.loads(COMBAT.read_text(encoding='utf-8'))
    monsters: dict = combat['monsters']
    existing = {str(v.get('mob', '')).lower() for v in monsters.values()}
    added, skipped = [], []
    for mob_path in sorted(needed_mobs()):
        if mob_path in existing:
            continue
        entry = next((m for m in catalog.values() if str(m['path']).lower() == mob_path), None)
        if entry is None or not entry.get('motions'):
            skipped.append(mob_path)
            continue
        key = BUILTIN.get(mob_path) or mob_path.replace('monster/', '', 1).replace('.mob', '').replace('/', '_')
        monsters[key] = {'mob': mob_path, 'bank': key, 'name': str(entry.get('name') or key)}
        added.append(key)
    if added and not args.dry_run:
        COMBAT.write_text(json.dumps(combat, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('[MONSTER_MAP] 新增映射 %d、无动作表跳过 %d、映射总数 %d%s'
          % (len(added), len(skipped), len(monsters), '（dry-run）' if args.dry_run else ''))
    if added:
        print('  ' + ', '.join(added[:20]) + (' …' if len(added) > 20 else ''))
    if skipped:
        print('  跳过：' + ', '.join(skipped[:8]) + (' …' if len(skipped) > 8 else ''))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
