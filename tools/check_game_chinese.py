"""Reject Korean in game-owned text; baked IMG lettering also needs visual review.

Raw archived assets and provenance remain intact. This gate checks source text,
not image pixels, so it must run alongside the rendered-screen review checklist.
"""
from pathlib import Path
import re
import argparse

ROOT = Path(__file__).resolve().parents[1]
KOREAN = re.compile(r'[\u1100-\u11ff\u3130-\u318f\ua960-\ua97f\uac00-\ud7ff\uffa0-\uffdc]')


def scan(root: Path) -> list[dict]:
    problems = []
    for file in sorted(root.rglob('*')):
        if not file.is_file() or file.suffix not in ['.gd', '.tscn', '.json']:continue
        if any(part in ['assets_local', '.godot'] for part in file.relative_to(root).parts):continue
        for number, line in enumerate(file.read_text(encoding='utf-8-sig').splitlines(), 1):
            if KOREAN.search(line):problems.append({'path': file.relative_to(root).as_posix(), 'line': number})
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT/'game_dnf')
    args = parser.parse_args()
    problems = scan(args.root)
    for item in problems:print(f"FAIL {item['path']}:{item['line']}: Korean is not allowed in game text")
    if problems:raise SystemExit(1)
    print('OK: game text contains no Korean; baked texture lettering requires rendered review')


if __name__ == '__main__':main()
