"""Layering guard for game_dnf (docs/design/29_新版工程框架.md, sections 2/5/10).

Enforced on every res:// reference to a .gd/.tscn/.tres file:
1. Kernel purity: core(0) < content(1) < combat(2). A kernel module may only depend on
   lower kernel modules; it never reaches upper modules or the transitional scripts/ and
   scenes/ (allowlisted bridges excepted).
2. Kernel encapsulation: from any other module, content/ and combat/ are reached only
   through their api/ folder. core/ is public as a whole.
Above the kernel (map/flow/items/save/town/view/ui), internal organisation and the use of
legacy scripts/ during migration are left to the owning workspace (doc 28).
debug/, tests/, scripts/ and scenes/ are exempt as sources. Exit code 1 on any violation.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / 'game_dnf'
KERNEL = {'core': 0, 'content': 1, 'combat': 2}
ENCAPSULATED = {'content', 'combat'}
EXEMPT_SOURCES = {'debug', 'tests', 'scripts', 'scenes', 'assets_local', '.godot'}
LEGACY = {'scripts', 'scenes'}
# Transitional bridges that wrap the legacy battle scene until the World kernel lands (F3).
BRIDGES = {('combat/api/combat_session.gd', 'scenes/main.tscn')}
REF = re.compile(r'res://([A-Za-z0-9_./-]+\.(?:gd|tscn|tres))')


def module_of(rel: str) -> str:
    return rel.split('/', 1)[0] if '/' in rel else ''


def check(game: Path) -> list[str]:
    problems = []
    for path in sorted(game.rglob('*.gd')):
        rel = path.relative_to(game).as_posix()
        source = module_of(rel)
        if source in EXEMPT_SOURCES:
            continue
        for lineno, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            if line.lstrip().startswith('#'):
                continue
            for target in REF.findall(line):
                dest = module_of(target)
                if dest == source:
                    continue
                where = f'{rel}:{lineno} -> res://{target}'
                if source in KERNEL:
                    if dest in LEGACY:
                        if (rel, target) not in BRIDGES:
                            problems.append(f'{where}: kernel module depends on legacy {dest}/')
                        continue
                    if dest not in KERNEL or KERNEL[dest] > KERNEL[source]:
                        problems.append(f'{where}: kernel {source} may only depend on lower kernel modules')
                        continue
                if dest in ENCAPSULATED and not target.startswith(dest + '/api/'):
                    problems.append(f'{where}: bypasses {dest}/api/')
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--game', type=Path, default=GAME)
    args = parser.parse_args()
    problems = check(args.game)
    for p in problems:
        print('[DNF_DEPS] FAIL ' + p)
    print(f'[DNF_DEPS] {"OK" if not problems else "FAILED"} violations={len(problems)}')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
