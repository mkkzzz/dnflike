"""Render an offline layout preview from the real Godot panel, always headless.

This is a software composition of exported UI controls, not a live screenshot.
Usage: python tools/preview_dnf_skill_panel.py --job weaponmaster --output temp/skill_ui_v2.png
"""
import argparse
import json
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]


def tint(image, color):
    channels = image.convert('RGBA').split()
    return Image.merge('RGBA', tuple(channel.point(lambda value: round(min(255, value * factor)))
                                     for channel, factor in zip(channels, color)))


def patch(image, size, margins):
    left, top, right, bottom = (int(value) for value in margins)
    width, height = size
    left, right = min(left, width // 2), min(right, width // 2)
    top, bottom = min(top, height // 2), min(bottom, height // 2)
    result = Image.new('RGBA', size)
    xs = [0, left, image.width - right, image.width]
    ys = [0, top, image.height - bottom, image.height]
    dx = [0, left, width - right, width]
    dy = [0, top, height - bottom, height]
    for y in range(3):
        for x in range(3):
            cell = image.crop((xs[x], ys[y], xs[x + 1], ys[y + 1]))
            target = (dx[x + 1] - dx[x], dy[y + 1] - dy[y])
            if min(cell.size + target) > 0:
                result.paste(cell.resize(target, Image.Resampling.NEAREST), (dx[x], dy[y]))
    return result


def render(layout, directory, output):
    canvas = Image.new('RGBA', tuple(layout['size']), (0, 0, 0, 255))
    fonts = {}
    font_path = Path('C:/Windows/Fonts/msyh.ttc')
    for command in layout['commands']:
        layer = Image.new('RGBA', canvas.size)
        kind = command['kind']
        color = tuple(round(min(1, value) * 255) for value in command['color'])
        if kind in ('image', 'patch'):
            x, y, width, height = (round(value) for value in command['rect'])
            if min(width, height) <= 0:
                continue
            image = Image.open(directory / command['texture']).convert('RGBA')
            image = patch(image, (width, height), command['margins']) if kind == 'patch' else image.resize((width, height), Image.Resampling.NEAREST)
            layer.paste(tint(image, command['color']), (x, y))
        elif kind == 'line':
            points = [tuple(round(value) for value in point) for point in command['points']]
            ImageDraw.Draw(layer).line(points, fill=color, width=max(1, round(command['width'])))
        elif kind == 'text':
            x, y, width, height = command['rect']
            size = command['font_size']
            font = fonts.setdefault(size, ImageFont.truetype(str(font_path), size))
            lines = []
            for paragraph in command['text'].split('\n'):
                line = ''
                for character in paragraph:
                    if command['wrap'] and line and font.getlength(line + character) > width - 10:
                        lines.append(line)
                        line = ''
                    line += character
                lines.append(line)
            line_height = command['line_height'] or size + 3
            if command['vertical'] == 1:
                y += max(0, (height - len(lines) * line_height) / 2)
            draw = ImageDraw.Draw(layer)
            for index, line in enumerate(lines):
                tx = x
                if command['align'] == 1:
                    tx += (width - font.getlength(line)) / 2
                elif command['align'] == 2:
                    tx += width - font.getlength(line)
                ty = y + index * line_height
                draw.text((round(tx + 1), round(ty + 1)), line, font=font, fill=(0, 0, 0, color[3]), anchor='lt')
                draw.text((round(tx), round(ty)), line, font=font, fill=color, anchor='lt')
        clip_x, clip_y, clip_w, clip_h = (round(value) for value in command['clip'])
        clip = (max(0, clip_x), max(0, clip_y), min(canvas.width, clip_x + clip_w), min(canvas.height, clip_y + clip_h))
        if clip[2] > clip[0] and clip[3] > clip[1]:
            canvas.alpha_composite(layer.crop(clip), clip[:2])
    canvas.convert('RGB').save(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job', choices=['swordman', 'weaponmaster', 'soulbringer', 'berserker', 'asura'], default='weaponmaster')
    parser.add_argument('--scroll', type=int, default=0)
    parser.add_argument('--skill', default='upperslash')
    parser.add_argument('--output', type=Path, default=ROOT / 'temp/skill_ui_v2.png')
    args = parser.parse_args()
    output = args.output.resolve()
    temp_root = (ROOT / 'temp').resolve()
    if not output.is_relative_to(temp_root):
        parser.error('Previews must stay under temp/')
    directory = output.parent / (output.stem + '_controls')
    directory.mkdir(parents=True, exist_ok=True)
    engine = ROOT / 'tools/godot/Godot_v4.7.2-stable_win64_console.exe'
    version = subprocess.run([str(engine), '--headless', '--version'], capture_output=True, text=True, check=True).stdout
    if not version.startswith('4.7.2.'):
        raise RuntimeError('Godot 4.7.2 is required')
    result = subprocess.run([str(engine), '--headless', '--path', str(ROOT / 'game_dnf'),
                             '--script', 'res://debug/export_skill_panel.gd', '--', str(directory),
                             args.job, str(args.scroll), args.skill], capture_output=True, text=True,
                            encoding='utf-8', errors='replace', timeout=30)
    if result.returncode or 'SCRIPT ERROR' in result.stderr or 'ERROR:' in result.stderr:
        raise RuntimeError(result.stdout + result.stderr)
    render(json.loads((directory / 'layout.json').read_text(encoding='utf-8')), directory, output)
    print(result.stdout.strip())
    print('[SKILL_PREVIEW] offline layout: ' + str(output))


if __name__ == '__main__':
    main()
