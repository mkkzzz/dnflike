"""Diagnostic crops/boards only. Preserve generated art and never upscale it."""
import hashlib
import json
import platform
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, __version__ as pillow_version

PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parents[5]
PREVIEW = ROOT / 'docs/previews/forest_10001_reference_redesign_v2/batch_01'


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rel(path):
    return path.relative_to(ROOT).as_posix()


def soil_transition(image):
    """Color-only preview guide, never a collision or aesthetic acceptance test."""
    pixels = image.load()
    for y in range(int(image.height * .2), int(image.height * .9)):
        rows = []
        for sample_y in range(y, min(y + 4, image.height)):
            warm = [pixels[x, sample_y][0] - pixels[x, sample_y][1] > 12
                    for x in range(int(image.width * .1), int(image.width * .9), 4)]
            rows.append(sum(warm) / len(warm))
        if min(rows) > .75:
            return y
    raise ValueError('No broad soil transition found; review manually')


def thumb(image, box):
    copy = image.convert('RGB')
    copy.thumbnail(box, Image.Resampling.LANCZOS)
    return copy


def main():
    manifest = json.loads((PACKAGE / 'manifest.json').read_text(encoding='utf-8'))
    generation = json.loads((PACKAGE / 'generation.json').read_text(encoding='utf-8'))
    PREVIEW.mkdir(parents=True, exist_ok=True)
    font = ImageFont.load_default(size=21)
    smaller = ImageFont.load_default(size=17)
    records = []
    for call in generation['calls']:
        source = ROOT / call['output']
        with Image.open(source) as im:
            im.verify()
        with Image.open(source) as im:
            size, mode = list(im.size), im.mode
        requested = call['requested_native_size_in_prompt']
        records.append({
            'candidate': call['candidate'], 'path': rel(source),
            'actual_size': size, 'requested_native_size': requested, 'mode': mode,
            'original_bytes_unchanged': sha256(source) == call['output_sha256'],
            'reference_files_unchanged': all((ROOT / ref['path']).is_file()
                and sha256(ROOT / ref['path']) == ref['sha256'] for ref in call['references']),
            'prompt_matches_record': (ROOT / call['prompt_file']).read_text(
                encoding='utf-8').strip() == call['prompt'].strip(),
            'native_size_met': size[0] >= requested[0] and size[1] >= requested[1],
        })
    view_board = Image.new('RGB', (1490, 1430), '#e8e5dc')
    view_draw = ImageDraw.Draw(view_board)
    view_draw.text((14, 10), '10001: approved baseline + five room viewport crops (design review)', fill='#25312c', font=font)
    view_draw.text((14, 40), 'Crops only; no upscale, color correction, actor or runtime rendering.', fill='#25312c', font=smaller)
    baseline = ROOT / generation['user_approval']['approved_candidate']
    views = [('Approved R01 c2 baseline', Image.open(baseline).convert('RGB'))]
    full_images = []
    cameras = []
    for room in manifest['rooms']:
        source = ROOT / room['design_candidate']
        with Image.open(source) as raw:
            im = raw.convert('RGB')
        width = round(im.width * 2560 / room['native_target'][0])
        height = round(im.height * 1440 / room['native_target'][1])
        soil_y = soil_transition(im)
        left = (im.width - width) // 2
        top = max(0, min(im.height - height, round(soil_y - .4 * height)))
        rect = [left, top, left + width, top + height]
        viewport = im.crop(tuple(rect))
        cameras.append({
            'module_id': room['module_id'], 'source': rel(source),
            'source_size': list(im.size), 'native_target': room['native_target'],
            'preview_rect_source_pixels': rect, 'viewport_native_target': [2560, 1440],
            'soil_transition_heuristic_y': soil_y,
            'soil_transition_ratio_in_view': round((soil_y - top) / height, 4),
            'guide_only_not_runtime_or_collision_data': True,
        })
        viewport.save(PREVIEW / (room['module_id'].lower() + '_viewport.png'))
        views.append((room['module_id'] + ' / same native viewport proportion', viewport))
        full_images.append((room['module_id'], im))
    scales = []
    for index, (label, im) in enumerate(views):
        x = 14 + (index % 2) * 745
        y = 82 + (index // 2) * 445
        view_draw.text((x, y), label, fill='#25312c', font=smaller)
        small = thumb(im, (720, 405))
        scales.append(small.width / im.width)
        view_board.paste(small, (x, y + 26))
    view_board.save(PREVIEW / 'gameplay_viewports.png')
    rows = []
    for module, im in full_images:
        small = thumb(im, (1400, 820))
        scales.append(small.width / im.width)
        rows.append((module, im.size, small))
    overview = Image.new('RGB', (1440, 65 + sum(row[2].height + 55 for row in rows)), '#e8e5dc')
    draw = ImageDraw.Draw(overview)
    draw.text((18, 14), '10001 full room designs - original proportions, unapproved candidates', fill='#25312c', font=font)
    y = 65
    for module, size, small in rows:
        draw.text((18, y), f'{module}: actual {size[0]}x{size[1]} / native 2K NOT met', fill='#25312c', font=smaller)
        overview.paste(small, ((1440 - small.width) // 2, y + 30))
        y += small.height + 55
    overview.save(PREVIEW / 'rooms_overview.png')
    boundary = Image.new('RGB', (1490, 470), '#e8e5dc')
    draw = ImageDraw.Draw(boundary)
    for index, (key, label) in enumerate([
            ('r01_c2', 'Approved c2: before boundary shrubs'),
            ('r01_c3', 'c3: requested low boundary shrubs / passage gaps')]):
        with Image.open(PACKAGE / 'candidates' / key / 'source.png') as im:
            small = thumb(im, (720, 405))
            scales.append(small.width / im.width)
        x = 14 + index * 745
        draw.text((x, 12), label, fill='#25312c', font=smaller)
        boundary.paste(small, (x, 45))
    boundary.save(PREVIEW / 'r01_boundary_revision.png')
    with Image.open(ROOT / manifest['selected_candidate']) as im:
        size_075 = (round(im.width * .75), round(im.height * .75))
        im.resize(size_075, Image.Resampling.LANCZOS).save(PREVIEW / 'r01_c3_075.png')
    integrity = all(record['original_bytes_unchanged'] and record['reference_files_unchanged']
                    and record['prompt_matches_record'] and record['mode'] == 'RGB'
                    for record in records) and max(scales) <= 1
    validation = {
        'software': {'python': platform.python_version(), 'pillow': pillow_version},
        'technical_integrity_passed': integrity, 'sources': records,
        'baseline_style_approved': True, 'new_room_artwork_user_approved': False,
        'room_design_candidates': len(manifest['rooms']),
        'production_exports': len(manifest['production_exports']),
        'native_2k_ready': all(record['native_size_met'] for record in records
            if record['path'] in {room['design_candidate'] for room in manifest['rooms']}),
        'upscaled': False, 'artwork_modified_by_review_script': False,
        'mirrored_or_tiled_extension': False, 'runtime_integrated': False,
        'viewport_review': cameras, 'review_thumbnail_scales': scales,
        'previews': [rel(PREVIEW / filename) for filename in [
            'gameplay_viewports.png', 'rooms_overview.png', 'r01_boundary_revision.png', 'r01_c3_075.png']],
        'limitations': [
            'All returned native room resolutions are lower than formal targets; no upscale performed.',
            'Room designs and requested edge-shrub revision have not received final user artwork approval.',
            'Camera windows and warm-soil color heuristic are preview guides, not runtime/collision data.',
            'R04 c2 failed its requested geometry edit; c1 retained with an explicit preview camera window.',
            'No layer exports, collision gates, characters or engine/runtime validation included.',
        ],
    }
    (PACKAGE / 'validation_batch_01.json').write_text(
        json.dumps(validation, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'integrity': integrity, 'selected_rooms': cameras,
                      'previews': validation['previews']}, ensure_ascii=False, indent=2))
    if not integrity:
        raise SystemExit('Source provenance/reference/prompt/no-upscale check failed')


if __name__ == '__main__':
    main()
