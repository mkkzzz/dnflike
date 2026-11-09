"""Build the shared G.S.D. APC appearance from AIC → EQU → LAY/ANI → original IMG."""
from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
from tempfile import TemporaryDirectory

from build_dnf_combat_assets import Atlas, Source, sha
from build_dnf_companion_programs import IDS, INDEX
from build_dnf_weapon_appearance import LAY_PATH, bind_image
from dnf_locomotion import MOTION_DIR, compose
from dnf_pvf import first_values, resolve


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'game_dnf/assets_local/companions_v1'
TEXTURE_ROOT = 'res://assets_local/companions_v1/'
EQUIPMENT_LIST = 'equipment/equipment.lst'
SWORDMAN = 'character/swordman/swordman.chr'
POSES = ('stay', 'move', 'dash', 'attack1', 'attack2', 'attack3', 'hitback',
         'upperslashafter', 'wave', 'damage1', 'damage2', 'overturn', 'down',
         'sit', 'guard', 'summon2', 'dashattack', 'jump', 'jumpattack', 'hardattack')


def original(src, path):
    record = src.lib.script(path)
    if record is None:
        raise ValueError('Missing companion source: ' + path)
    src.sources[path] = record['sha256']
    return record['fields']


def equipment_layers(src, equipment):
    listing = src.lib.listing(EQUIPMENT_LIST)
    src.sources[EQUIPMENT_LIST] = src.lib.raw(EQUIPMENT_LIST)[1]
    records, layers = [], []
    for item_id, arg1, arg2 in zip(equipment[::3], equipment[1::3], equipment[2::3], strict=True):
        path = resolve(EQUIPMENT_LIST, listing[item_id])
        fields = original(src, path)
        slot = first_values(fields, '[equipment type]')[0]
        records.append({'id': item_id, 'args': [arg1, arg2], 'path': path, 'slot': slot})
        active = False
        variation = None
        layer = None
        for field in fields:
            tag, values = field['tag'], field['values']
            if tag == '[animation job]':
                active = values == ['[swordman]']
            elif active and tag == '[variation]':
                variation = values
                if slot == '[skin avatar]':
                    if len(variation) != 2 or variation[0] != 0:
                        raise ValueError('Unexpected Swordman skin variation: ' + path)
                    # Base body goes between the rear apparel (up to 850)
                    # and the front apparel (from 1200). No default clothing.
                    layers.append({'order': 1000, 'item_id': item_id, 'variation': variation,
                                   'folder': MOTION_DIR.rstrip('/')})
            elif active and tag == '[layer variation]':
                layer = values
            elif active and tag == '[equipment ani script]':
                if values != [LAY_PATH] or layer is None or variation is None:
                    raise ValueError('Unsupported companion equipment layout: ' + path)
                order, folder = layer
                layers.append({'order': order, 'item_id': item_id, 'variation': variation,
                               'folder': str(PurePosixPath(path).parent / folder.lower())})
                layer = None
    if len(layers) != 15 or len({layer['order'] for layer in layers}) != len(layers):
        raise ValueError('Unexpected companion layer inventory')
    return records, sorted(layers, key=lambda layer: layer['order'])


def build(src, output):
    listing = src.lib.listing(INDEX)
    src.sources[INDEX] = src.lib.raw(INDEX)[1]
    original(src, SWORDMAN)
    layout = original(src, LAY_PATH)
    animations = {value.lower().removeprefix('%s/') for node in layout for value in node['values']
                  if isinstance(value, str) and value.lower().startswith('%s/')}
    if any(pose + '.ani' not in animations for pose in POSES):
        raise ValueError('Missing pose binding in original Swordman LAY')
    actors = {}
    equipment = None
    for apc_id in IDS:
        path = resolve(INDEX, listing[apc_id])
        items = first_values(original(src, path), '[equipment]')
        if equipment is not None and items != equipment:
            raise ValueError('G.S.D. APCs have different source outfits')
        equipment = items
        actors[str(apc_id)] = {'source': path}
    records, layers = equipment_layers(src, equipment)
    atlas = Atlas('gsd', TEXTURE_ROOT, output)
    variants = {}
    clips = {}
    for pose in POSES:
        source_ani = MOTION_DIR + pose + '.ani'
        body = src.animation(source_ani)
        layer_frames = [src.animation(layer['folder'] + '/' + pose + '.ani')['frames'] for layer in layers]
        frames = []
        for body_frame, *parts in zip(body['frames'], *layer_frames, strict=True):
            index = body_frame['img_frame']
            paths, colors = [], {}
            for layer, part in zip(layers, parts, strict=True):
                if (part.get('img_frame') != index or part.get('pos') != body_frame.get('pos')
                        or part['items'].get('8') != body_frame['items'].get('8')):
                    raise ValueError('Unsynchronized companion equipment ANI: ' + source_ani)
                template = part['img']
                if not template:
                    continue
                variation = layer['variation']
                if layer['folder'] == MOTION_DIR.rstrip('/'):
                    if template.lower() != 'character/swordman/equipment/avatar/skin/sm_body%04d.img':
                        raise ValueError('Unsupported Swordman skin template: ' + template)
                    path = 'sprite/' + (template % variation[1]).lower()
                else:
                    path = bind_image(template, variation)
                paths.append(path)
                blend = part['items'].get('11')
                if set(part['items']) - {'8', '11', '12', '13', '23'} or (blend and blend['type'] != 5):
                    raise ValueError('Unsupported companion layer draw mode: ' + source_ani)
                if blend:
                    colors[path] = tuple(blend['color'])
            key = (index, tuple(paths), tuple(colors.items()))
            if key not in variants:
                frame_id = len(variants)
                image, offset = compose(src, paths, index, colors=colors)
                atlas.add(frame_id, image, offset)
                atlas.items[str(frame_id)]['rgba_sha256'] = sha(image.tobytes())
                variants[key] = frame_id
            frames.append({**body_frame, 'img_frame': variants[key], 'source_img_frame': index})
        clips[pose] = {**body, 'frames': frames, 'source_ani': source_ani}
    clips['upper'] = clips['hitback']
    bank = atlas.save()
    for actor in actors.values():
        actor.update(atlas=bank, clips=clips)
    return {
        'schema': 'dnf_companion_appearance/1',
        'actors': actors,
        'equipment': records,
        'layers': layers,
        'sources': dict(sorted(src.sources.items())),
        'files': {'gsd.png': sha((output / 'gsd.png').read_bytes())},
        'policy': 'Original AIC outfit, Swordman body clock, ordered native crop layers. '
                  'Base skin between rear and front apparel; ANI type 5 uses the original monochrome RGB. '
                  'No animation scaling, frame removal, or default player clothing.',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    src = Source(args.library)
    try:
        if args.check:
            with TemporaryDirectory(prefix='dnf-gsd-') as temporary:
                generated = build(src, Path(temporary))
            if json.loads((OUT / 'manifest.json').read_text(encoding='utf-8')) != generated:
                raise ValueError('Stale companion manifest')
            if sha((OUT / 'gsd.png').read_bytes()) != generated['files']['gsd.png']:
                raise ValueError('Stale companion atlas')
        else:
            generated = build(src, OUT)
            (OUT / 'manifest.json').write_text(json.dumps(generated, ensure_ascii=False, separators=(',', ':')) + '\n',
                                               encoding='utf-8', newline='\n')
    finally:
        src.lib.close()
        src.cat.close()
    bank = generated['actors']['201']['atlas']
    print(f"G.S.D. {len(bank['items'])} frames, {len(generated['actors']['201']['clips'])} pose keys, two original APCs")


if __name__ == '__main__':
    main()
