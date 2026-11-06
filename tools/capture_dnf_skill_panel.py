"""Capture real skill UI/font pixels on a private Windows desktop (no visible window)."""
import argparse
from pathlib import Path

from start_dnf_mcp_background import run_isolated

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='Output directory for actual.png')
    parser.add_argument('--job', choices=['swordman', 'weaponmaster', 'soulbringer', 'berserker', 'asura'], default='swordman')
    parser.add_argument('--scroll', type=float, default=0)
    parser.add_argument('--skill', default='upperslash')
    args = parser.parse_args()
    godot = ROOT / 'tools/godot/Godot_v4.7.2-stable_win64_console.exe'
    return run_isolated([
        str(godot.resolve(strict=True)), '--path', str(ROOT / 'game_dnf'),
        '--rendering-method', 'gl_compatibility', '--script', 'res://debug/export_skill_panel.gd',
        '--', str(args.output.resolve()), args.job, str(args.scroll), args.skill, '--capture',
    ], ROOT)


if __name__ == '__main__':
    raise SystemExit(main())
