"""Capture the implemented native-wave phases on a private Windows desktop."""
import argparse
import json
from pathlib import Path

from start_dnf_mcp_background import run_isolated

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output=args.output.resolve()
    marker=output/'capture_complete.json'
    marker.unlink(missing_ok=True)
    code=run_isolated([
        str(ROOT/'tools/godot/Godot_v4.7.2-stable_win64_console.exe'),
        '--path', str(ROOT/'game_dnf'), '--rendering-method', 'gl_compatibility',
        '--quit-after', '600', '--script', 'res://debug/export_native_wave.gd',
        '--', str(output),
    ], ROOT)
    if code:return code
    return 0 if marker.is_file() and json.loads(marker.read_text(encoding='utf8'))=={'frames':18} else 1


if __name__ == '__main__':
    raise SystemExit(main())
