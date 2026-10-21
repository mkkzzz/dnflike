"""Replay the actual whole-person C9 run drawings before any interpolation or installation."""
from pathlib import Path
import hashlib
import json
import subprocess
import imageio_ffmpeg
from PIL import Image, ImageDraw
from check_actor_proportions import preflight

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'art/animations/players/swordsman/v7/sources/whole_body_gait_c9/run_cycle_c4'
KEYS = ROOT / 'art/animations/players/swordsman/v7/exports/whole_body_run_c9_cycle_c4_keys'
VIEW = ROOT / 'docs/previews/v7_c9_whole_body'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def read(path):
    return json.loads(path.read_text(encoding='utf-8'))

def main():
    config = read(SOURCE / 'body_config.json')
    gate = preflight(SOURCE / 'body_config.json', config)
    manifest = read(KEYS / 'manifest.json')
    if manifest['config_sha256'] != sha(SOURCE / 'body_config.json'):
        raise ValueError('Re-export changed key config first')
    clip = manifest['clips']['run']
    frames = []
    panels = []
    for record in clip['frames']:
        image = Image.open(KEYS / record['file']).convert('RGBA')
        cut = image.crop((0, 470, 700, 880))
        bounds = image.getchannel('A').point(lambda a: 255 if a > 16 else 0).getbbox()
        if not bounds or not (0 <= bounds[0] and 470 <= bounds[1] and bounds[2] <= 700 and bounds[3] <= 880):
            raise ValueError('Preview would crop a whole-body key')
        panel = Image.new('RGB', cut.size, '#222a31')
        panel.paste(cut, (0, 0), cut)
        draw = ImageDraw.Draw(panel)
        draw.line((0, 370, 700, 370), fill='#596875')
        draw.text((12, 10), record['source_pose'], fill='white')
        panels.append(panel)
        frames.extend([panel] * record['duration_ticks'])
    sheet = Image.new('RGB', (2800, 820), '#222a31')
    for i, panel in enumerate(panels):
        sheet.paste(panel, (i % 4 * 700, i // 4 * 410))
    sheet.save(VIEW / 'run_cycle_c4_keys.png')
    path = VIEW / 'run_cycle_c4_keys.mp4'
    process = subprocess.Popen([imageio_ffmpeg.get_ffmpeg_exe(), '-y', '-f', 'rawvideo', '-vcodec', 'rawvideo', '-pix_fmt', 'rgb24', '-s', '700x410', '-r', '60', '-i', '-', '-an', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '16', str(path)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    for _ in range(4):
        for frame in frames:
            process.stdin.write(frame.tobytes())
    process.stdin.close()
    error = process.stderr.read()
    if process.wait():
        raise RuntimeError(error.decode(errors='replace'))
    report = {'status': 'painted_key_timing_diagnostic', 'runtime_installed': False,
              'complete_motion_approved': False, 'includes_painted_weapon': True,
              'weapon_switching_delivery': False, 'painted_keys': len(panels),
              'fps': 60, 'duration_ticks': len(frames), 'interpolated_frames': 0,
              'native_preview_size': [700, 410], 'raster_upscaled': False,
              'key_manifest_sha256': sha(KEYS / 'manifest.json'), 'source_G1': gate,
              'recipe_sha256': sha(Path(__file__)),
              'media': {p.name: sha(p) for p in [path, VIEW / 'run_cycle_c4_keys.png']}}
    (SOURCE / 'key_review.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(path)

if __name__ == '__main__':
    main()
