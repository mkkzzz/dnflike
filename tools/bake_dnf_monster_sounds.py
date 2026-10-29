"""按原版 `audio.xml` 的命名约定，为每只怪烘焙受击/死亡/攻击音效。

原版没有在 `.mob` 里写音效字段，引擎按「怪名 + 事件」拼 sound ID（如 `GOBLIN_DIE_01`），
真实 ID→文件映射在 `audio.xml`。这里按 `mob 文件名 → mob 类别` 的优先级去匹配：

  1. `<STEM>_DIE*` / `<STEM>_HIT*` / `<STEM>_ATTACK*`（如 goblin → GOBLIN_DIE_01）
  2. `<CATEGORY>_DIE*`（如 tauarmy 落在 [tau] 类别 → TAU_DIE）
  3. 都没有则该怪不配音效（不伪造借用别的怪）

输出：`assets_local/combat/monster_sound/<key>/<event>_NN.ogg` + `data/monster_sounds.json`
用法：python tools/bake_dnf_monster_sounds.py [--library DIR]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dnf_pvf as P

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'game_dnf'
CATALOG = GAME / 'data/monster_catalog.json'
COMBAT = GAME / 'data/combat.json'
# 独立于 combat/：build_dnf_combat_assets 会整目录重建，音效放在里面会被反复删除；
# 文件数过多还会触发环境的批量删除保护。
OUT = GAME / 'assets_local/monster_sound'
MAP = GAME / 'data/monster_sounds.json'
# 原版音效 ID 的命名不统一：有 GOBLIN_DIE_01（怪名+事件）、TAU_DIE（类别+事件）、
# GOLEM_DOWN / STATUE_DIE（通用名+事件）、ZOMBIE_BITE（行为名）。所以按「名字出现 + 事件关键字出现」双条件匹配。
EVENTS = {
    'die': ('DIE', 'DOWN'),
    'hit': ('HIT', 'DMG'),
    'attack': ('ATK', 'ATTACK', 'BITE', 'SMASH', 'SLUG'),
}
# 目录名 → 原版共用的音效名前缀
ALIASES = {'CHARACTERSTATUE': 'STATUE', 'NEW_GOLEM': 'GOLEM', 'DOLLMASTER': 'DOLL'}


def load_audio_index(cat, root: Path) -> dict[str, str]:
    row = cat.execute("select local_path from assets where lower(original_path)='audio.xml' limit 1").fetchone()
    if row is None:
        return {}
    text = (root / row['local_path']).read_text(encoding='utf-8', errors='replace')
    index: dict[str, str] = {}
    for match in re.finditer(r'<EFFECT[^>]*ID="([^"]+)"[^>]*FILE="([^"]+)"', text, re.I):
        index[match.group(1).upper()] = match.group(2).replace('\\', '/')
    return index


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=None)
    args = parser.parse_args()
    catalog = json.loads(CATALOG.read_text(encoding='utf-8'))['monsters']
    combat = json.loads(COMBAT.read_text(encoding='utf-8'))['monsters']
    lib = P.open_library(args.library)
    cat = sqlite3.connect(f'file:{lib.path / "catalog.sqlite"}?mode=ro', uri=True)
    cat.row_factory = sqlite3.Row
    index = load_audio_index(cat, lib.path)
    OUT.mkdir(parents=True, exist_ok=True)
    result: dict[str, dict] = {}
    copied = 0
    missing: list[str] = []
    try:
        for key, spec in combat.items():
            mob_path = str(spec.get('mob', '')).lower()
            entry = next((m for m in catalog.values() if str(m['path']).lower() == mob_path), None)
            if entry is None:
                continue
            stem = PurePosixPath(mob_path).stem.upper()
            categories = [c.strip('[]').strip().upper() for c in (entry.get('category') or []) if isinstance(c, str)]
            names = [stem] + categories
            # 目录名与少量已知同义词：原版把一族怪共用的音效叫 GOLEM_* / STATUE_* / DOLL_*
            folder_name = PurePosixPath(mob_path).parent.name.upper()
            for alias in (folder_name, ALIASES.get(folder_name, '')):
                if alias and alias not in names:
                    names.append(alias)
            sound: dict[str, list] = {}
            for event, keywords in EVENTS.items():
                files = []
                for name in names:
                    named = re.compile(r'(^|_)%s(_|$)' % re.escape(name))
                    files = [f for i, f in sorted(index.items())
                             if named.search(i) and any(k in i for k in keywords)]
                    if files:
                        break
                if not files:
                    continue
                folder = OUT / key
                folder.mkdir(parents=True, exist_ok=True)
                for position, file in enumerate(files[:4], start=1):
                    row = cat.execute(
                        "select local_path, sha256 from assets where kind='audio' and lower(original_path)=?",
                        (file.lower(),)).fetchone()
                    if row is None:
                        continue
                    raw = (lib.path / row['local_path']).read_bytes()
                    if hashlib.sha256(raw).hexdigest() != row['sha256']:
                        raise ValueError('音效哈希不一致: ' + file)
                    target = folder / ('%s_%02d.ogg' % (event, position))
                    target.write_bytes(raw)
                    sound.setdefault(event, []).append('monster_sound/%s/%s' % (key, target.name))
                    copied += 1
            if sound:
                result[key] = {'mob': mob_path, 'events': sound}
            else:
                missing.append(key)
    finally:
        cat.close()
        lib.close()
    MAP.write_text(json.dumps({
        'schema': 'dnf_monster_sounds/1',
        'evidence': 'sound ID 取自 audio.xml；按 mob 文件名优先、[category] 兜底匹配（E-PARSE）',
        'monsters': result,
    }, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    print('[MON_SOUND] 有音效 %d / %d、文件 %d、无音效 %d' % (len(result), len(combat), copied, len(missing)))
    if missing:
        print('  无音效：' + ', '.join(missing[:10]) + (' …' if len(missing) > 10 else ''))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
