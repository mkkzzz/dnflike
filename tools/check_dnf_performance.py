"""Reject known DNF performance regressions before running/importing the game.

Runtime readers must use Numbers.shared_config(); full mutable snapshots belong
only in tests/debug tools. This is a targeted guard, not a general GDScript profiler.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NUMBERS = 'stats/api/numbers.gd'
SKILL_PANEL = 'ui/flow/skill_panel.gd'
LITERALS = re.compile(r'"""[\s\S]*?"""|\x27\x27\x27[\s\S]*?\x27\x27\x27|"(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27|#[^\n]*')
ALIASES = re.compile(r'\b(?:const|var)\s+(\w+)\s*(?::\s*\w+\s*)?(?::=|=)\s*(?:preload|load)\s*\(\s*["\x27]res://stats/api/numbers\.gd["\x27]')
FUNCTION = re.compile(r'^\s*(?:static\s+)?func\s+(\w+)\s*\(')


def mask_literals(source: str) -> str:
    return LITERALS.sub(lambda match: ''.join('\n' if c == '\n' else ' ' for c in match[0]), source)


def check(game: Path) -> list[str]:
    problems = []
    for path in sorted(game.rglob('*.gd')):
        rel = path.relative_to(game).as_posix()
        if rel.split('/')[0] in {'tests', 'debug', '.godot', '.mcp', 'assets_local'}:
            continue
        source = path.read_text(encoding='utf-8-sig')
        aliases = {'Numbers', *ALIASES.findall(source)}
        code = mask_literals(source)
        old_api = re.compile(r'\b(?:' + '|'.join(re.escape(a) for a in aliases) + r')\s*\.\s*config\s*\(')
        function = ''
        for lineno, line in enumerate(code.splitlines(), 1):
            declaration = FUNCTION.match(line)
            if declaration:
                function = declaration[1]
                continue
            reason = ''
            if old_api.search(line) or (rel == NUMBERS and re.search(r'(?<![\w.])config\s*\(', line)):
                reason = 'removed Numbers.config() API; use shared_config() for runtime reads'
            elif re.search(r'\bconfig_snapshot\s*\(', line):
                reason = 'full numeric snapshot is forbidden in runtime code'
            elif re.search(r'\bshared_config\s*\(\s*\)\s*\.\s*duplicate\s*\(\s*true\s*\)', line) and not (rel == NUMBERS and function == 'config_snapshot'):
                reason = 'do not deep-copy the complete numeric catalog'
            elif rel == SKILL_PANEL and function in {'select_skill', 'change', '_refresh_progress'} and re.search(r'\b(?:show_overlay|show_window)\s*\(', line):
                reason = 'skill selection/rank refresh must retain the existing tree controls'
            if reason:
                problems.append(f'{rel}:{lineno}: {reason}')
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--game', type=Path, default=ROOT / 'game_dnf')
    args = parser.parse_args()
    problems = check(args.game)
    for problem in problems:
        print('[DNF_PERF] FAIL ' + problem)
    print(f'[DNF_PERF] {"OK" if not problems else "FAILED"} violations={len(problems)}')
    return int(bool(problems))


if __name__ == '__main__':
    raise SystemExit(main())
