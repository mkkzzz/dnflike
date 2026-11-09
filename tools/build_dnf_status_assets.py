"""Bake the original monster blind status art and native head anchors."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import build_dnf_combat_assets as combat

OUT = combat.ROOT / 'game_dnf/assets_local/status_v1'
TEXTURE_ROOT = 'res://assets_local/status_v1/'
SCHEMA = 'dnf_status_assets/1'
BLIND_ANIS = {
    'blind_back': 'common/activestatus/animation/blind1.ani',
    'blind_front': 'common/activestatus/animation/blind2.ani',
}


def monster_heights(source: combat.Source) -> tuple[dict, list]:
    heights, unresolved = {}, []
    for mob, record in sorted(source.pack_records.items()):
        if not mob.endswith('.mob'):
            continue
        data = record['decoded']
        actions = data.get('waiting_actions', [])
        motions = data.get('waiting_motion', [])
        if actions:
            path = source.pack_records.get(actions[0], {}).get('decoded', {}).get('base_ani', '')
        else:
            path = motions[0] if motions else ''
        try:
            frame = source.animation(path)['frames'][0]
            _, image = source.frame(frame['img'], frame['img_frame'])
        except (KeyError, IndexError) as error:
            unresolved.append({'mob': mob, 'ani': path, 'reason': str(error)})
            continue
        # 829ED5 -> 1097C60 -> 10861F0 mode 2: the base ANI's first
        # untrimmed sprite edge in scaled native pixels, cached by the actor.
        scale_y = frame['items'].get('7', [1, 1])[1]
        pixels = int(-(frame['pos'][1] + image['y']) * scale_y)
        if pixels <= 0:
            unresolved.append({'mob': mob, 'ani': path, 'reason': 'nonpositive default ANI height'})
            continue
        heights[mob] = {'pixels': pixels, 'ani': path}
    return heights, unresolved


def build(library: Path | None, out: Path) -> dict:
    source = combat.Source(library)
    missing = []
    original_out = combat.ACTIVE_OUT
    combat.ACTIVE_OUT = out
    try:
        effects = {
            key: combat.effect_bank(source, key, path, missing)
            for key, path in BLIND_ANIS.items()
        }
    finally:
        combat.ACTIVE_OUT = original_out
    if missing:
        raise ValueError(f'Missing required status images: {missing}')
    for bank in effects.values():
        filename = bank['atlas']['texture'].rsplit('/', 1)[1]
        bank['atlas']['texture'] = TEXTURE_ROOT + filename
    heights, unresolved = monster_heights(source)
    return {
        'schema': SCHEMA,
        'effects': effects,
        'monster_heights': heights,
        'unresolved_monster_heights': unresolved,
        'sources': source.sources,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--output', type=Path, default=OUT)
    args = parser.parse_args()
    manifest = build(args.library, args.output)
    (args.output / 'manifest.json').write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + '\n', encoding='utf-8'
    )
    print(f"blind layers={len(manifest['effects'])} "
          f"monster head anchors={len(manifest['monster_heights'])} "
          f"unresolved={len(manifest['unresolved_monster_heights'])}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
