"""Render the original tree PTL/ANI display probe on a private Windows desktop."""
import argparse
import json
from pathlib import Path

from start_dnf_mcp_background import run_isolated

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    marker = output / 'capture_complete.json'
    marker.unlink(missing_ok=True)
    code = run_isolated([
        str(ROOT / 'tools/godot/Godot_v4.7.2-stable_win64_console.exe'),
        '--path', str(ROOT / 'game_dnf'), '--rendering-method', 'gl_compatibility',
        '--quit-after', '600', '--script', 'res://debug/export_native_particles.gd',
        '--', str(output),
    ], ROOT)
    if code:
        return code
    if not marker.is_file():
        return 1
    result = json.loads(marker.read_text(encoding='utf8'))
    return 0 if result.get('frames') == 7 and all(
        (output / f'particles_{row["time_ms"]:04d}.png').is_file() for row in result['samples']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
