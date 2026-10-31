"""Bake the original revival coin prompt and use-coin effects.

Sources are the 111 backup PVF frames used by ui/usecoin/usecoinwindow.ui:
Item/IconStackable.img frame 5, Common/Etc/UseCoin.img and
Common/Etc/UseCoinParticle.img. The runtime package is independent so the
small death prompt does not pull in the full combat atlas.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from build_dnf_combat_assets import Source  # noqa: E402

OUTPUT = ROOT / 'game_dnf/assets_local/revive_v1'

COIN_ICON = ('sprite/Item/IconStackable.img', 5)
EFFECTS = {
    'coin': 'common/etc/animation/usecoin.ani',
    'spark': 'common/etc/animation/usecoinparticle.ani',
}
AUDIO = {'coin_in': 'sounds/ui/coin_in.ogg'}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cropped(image: Image.Image, meta: dict) -> tuple[Image.Image, list[int]]:
    box = image.getbbox()
    if not box:
        return Image.new('RGBA', (1, 1)), [meta['x'], meta['y']]
    return image.crop(box), [meta['x'] + box[0], meta['y'] + box[1]]


class Atlas:
    def __init__(self, name: str, output: Path):
        self.name = name
        self.output = output
        self.items: dict[str, dict] = {}
        self.images: list[tuple[Image.Image, int, int]] = []
        self.x = 2
        self.y = 2
        self.row_h = 0

    def add(self, key: str, image: Image.Image, offset: list[int]) -> None:
        width, height = image.size
        if self.x + width + 2 > 2048:
            self.x = 2
            self.y += self.row_h + 4
            self.row_h = 0
        self.items[key] = {'rect': [self.x, self.y, width, height], 'offset': offset}
        self.images.append((image, self.x, self.y))
        self.x += width + 4
        self.row_h = max(self.row_h, height)

    def save(self) -> dict:
        canvas = Image.new('RGBA', (2048, self.y + self.row_h + 2))
        for image, x, y in self.images:
            canvas.paste(image, (x, y))
        canvas.save(self.output / (self.name + '.png'))
        return {
            'texture': 'res://assets_local/revive_v1/' + self.name + '.png',
            'items': self.items,
        }


def effect_bank(src: Source, key: str, ani_path: str, output: Path) -> dict:
    animation = src.animation(ani_path)
    atlas = Atlas(key, output)
    frames: list[dict] = []
    for index, frame in enumerate(animation['frames']):
        frame = dict(frame)
        image_path = frame.get('img')
        if image_path:
            image, meta = src.frame(str(image_path), int(frame['img_frame']))
            image, offset = cropped(image, meta)
            x, y = offset[0] + int(frame['pos'][0]), offset[1] + int(frame['pos'][1])
            atlas.add(str(index), image, [x, y])
            frame['sprite'] = str(index)
        frames.append(frame)
    return {
        'atlas': atlas.save(),
        'frames': frames,
        'duration_ms': animation['duration_ms'],
        'source': ani_path,
    }


def build(output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    src = Source(None)
    try:
        icon_image, icon_meta = src.frame(*COIN_ICON)
        icon_image, icon_offset = cropped(icon_image, icon_meta)
        icon_image.save(output / 'coin_icon.png')
        effects = {key: effect_bank(src, key, path, output) for key, path in EFFECTS.items()}
        audio: dict[str, dict] = {}
        for key, path in AUDIO.items():
            found = src.audio(path)
            if found is None:
                raise FileNotFoundError('Missing original audio: ' + path)
            source, source_sha = found
            target = output / (key + '.ogg')
            shutil.copyfile(source, target)
            audio[key] = {
                'file': target.name,
                'source': path,
                'source_sha256': source_sha,
                'sha256': digest(target),
            }
        manifest = {
            'schema': 'dnf_revive_assets/1',
            'source': {
                'asset_version': src.lib.asset_version,
                'config_role': '111Script backup; effective original runtime unconfirmed',
                'prompt_ui': 'ui/usecoin/usecoinwindow.ui',
            },
            'pixel_policy': 'IMG native RGBA, no resize or substitute images',
            'ui': {
                'coin_icon': {
                    'file': 'coin_icon.png',
                    'source': COIN_ICON[0],
                    'img_frame': COIN_ICON[1],
                    'offset': icon_offset,
                    'sha256': digest(output / 'coin_icon.png'),
                },
            },
            'effects': effects,
            'audio': audio,
            'sources': dict(sorted(src.sources.items())),
        }
        (output / 'manifest.json').write_text(
            json.dumps(manifest, ensure_ascii=False, indent=1) + '\n',
            encoding='utf-8',
        )
        return manifest
    finally:
        src.lib.close()


def check(output: Path) -> bool:
    expected = json.loads((output / 'manifest.json').read_text(encoding='utf-8'))
    with tempfile.TemporaryDirectory(dir=ROOT / 'temp', prefix='revive-check-') as folder:
        fresh = Path(folder)
        actual = build(fresh)
        if expected != actual:
            print('[REVIVE] manifest differs from a fresh bake')
            return False
        for path in sorted(fresh.iterdir()):
            if not path.is_file():
                continue
            current = output / path.name
            if not current.is_file() or digest(current) != digest(path):
                print('[REVIVE] file differs from a fresh bake: ' + path.name)
                return False
    print('[REVIVE] manifest and files verified')
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=OUTPUT)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    if not any(output.is_relative_to(p.resolve()) for p in [ROOT / 'temp', ROOT / 'game_dnf/assets_local']):
        parser.error('Output must be inside temp/ or assets_local/')
    if args.check:
        return 0 if check(output) else 1
    manifest = build(output)
    print('[REVIVE] wrote %s effects=%d audio=%d' % (output, len(manifest['effects']), len(manifest['audio'])))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
