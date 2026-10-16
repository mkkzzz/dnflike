"""Rebuild diagnostic thumbnails and pixel/provenance checks; never edit source art."""
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parents[5]
PREVIEW = ROOT / 'docs/previews/forest_10001_reference_redesign_v2'


def relative(path):
    return path.relative_to(ROOT).as_posix()


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    manifest = json.loads((PACKAGE / 'manifest.json').read_text(encoding='utf-8'))
    generation = json.loads((PACKAGE / 'generation.json').read_text(encoding='utf-8'))
    PREVIEW.mkdir(parents=True, exist_ok=True)
    records = []
    for call in generation['calls']:
        path = ROOT / call['output']
        with Image.open(path) as check:
            check.verify()
        with Image.open(path) as im:
            records.append({
                'candidate': call['candidate'], 'path': relative(path),
                'size': list(im.size), 'mode': im.mode,
                'sha256': sha256(path),
                'original_bytes_unchanged': sha256(path) == call['output_sha256'],
                'requested_2k_met': im.width >= 2560 and im.height >= 1440,
                'reference_files_exist_and_unchanged': all(
                    (ROOT / ref['path']).is_file()
                    and sha256(ROOT / ref['path']) == ref['sha256']
                    for ref in call['references']),
                'prompt_matches_record': (ROOT / call['prompt_file']).read_text(
                    encoding='utf-8').strip() == call['prompt'].strip(),
            })
    board = Image.new('RGB', (1024, 1855), '#e8e5dc')
    draw = ImageDraw.Draw(board)
    font = ImageFont.load_default(size=22)
    inputs = [
        ('Approved concept: style / palette / camera', ROOT / manifest['reference']),
        ('R01 c1: ground too shallow (internal review)', ROOT / generation['calls'][0]['output']),
        ('R01 c2: proposed style baseline - awaiting user review', ROOT / generation['calls'][1]['output']),
    ]
    board_scales = []
    for index, (label, path) in enumerate(inputs):
        with Image.open(path) as original:
            thumb = original.convert('RGB')
            thumb.thumbnail((1000, 563), Image.Resampling.LANCZOS)
            top = index * 615
            draw.text((12, top + 9), label, fill='#25312c', font=font)
            board.paste(thumb, (12, top + 43))
            board_scales.append(thumb.width / original.width)
    board.save(PREVIEW / 'review_board.png')
    with Image.open(ROOT / manifest['selected_candidate']) as selected:
        size_075 = (round(selected.width * .75), round(selected.height * .75))
        selected.resize(size_075, Image.Resampling.LANCZOS).save(PREVIEW / 'r01_c2_075.png')
    checks_passed = all(r['original_bytes_unchanged']
                        and r['reference_files_exist_and_unchanged']
                        and r['prompt_matches_record'] and r['mode'] == 'RGB'
                        for r in records) and max(board_scales) <= 1
    result = {
        'technical_integrity_passed': checks_passed,
        'sources': records, 'review_board_scales': board_scales,
        'selected_075_size': list(size_075), 'upscaled': False,
        'artwork_modified': False, 'user_approved': False,
        'native_2k_ready': all(r['requested_2k_met'] for r in records),
        'full_room_canvases_delivered': 0,
        'production_ready': False, 'runtime_integrated': False,
        'limitations': [
            'Actual tool output is smaller than requested native 2K.',
            'R01 is a one-screen representative sample, not a complete room.',
            'Other four rooms, layer exports, seams and runtime remain unmade.',
            '0.75 preview refers to actual sample size, not 1080p validation.',
            'Visual observations and integrity checks do not imply user approval.',
        ],
    }
    (PACKAGE / 'validation.json').write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if not checks_passed:
        raise SystemExit('Source integrity/reference/prompt check failed')


if __name__ == '__main__':
    main()
