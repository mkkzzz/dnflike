#!/usr/bin/env python3
"""V5 art-polish preview: render horizontal/vertical cuts, slash light and hit FX.

Nothing here touches the Godot project. Output is review media only:
  python tools/preview_v5.py                  # all clips -> temp/v5_preview/
  python tools/preview_v5.py --clip combo     # one clip
  python tools/preview_v5.py --keyframes      # stills only (fast iteration)
  python tools/preview_v5.py --publish        # also copy review media to docs/previews/v5_art/
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))

from art_v5.moves import MOVES  # noqa: E402
from art_v5.scene import Scene  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'temp' / 'v5_preview'
PUBLISH = ROOT / 'docs' / 'previews' / 'v5_art'

CLIPS = {
    # view = (x, y, w, h) in game pixels of the 1280x720 battle field
    'combo': {'view': (312, 256, 600, 340), 'schedule': [(12, 'attack1'), (34, 'attack2'), (60, 'attack3')],
              'player_x': 440, 'target_x': 596, 'zoom': (320, 296, 440, 300), 'tail': 46},
    'quick_draw': {'view': (290, 256, 600, 340), 'schedule': [(12, 'quick_draw')],
                   'player_x': 410, 'target_x': 640, 'zoom': (300, 296, 480, 300), 'tail': 40},
}


def font(size: int):
    for name in ('msyh.ttc', 'msyhbd.ttc', 'simhei.ttf'):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def label(img: Image.Image, text: str, size=16) -> Image.Image:
    img = img.copy()
    d = ImageDraw.Draw(img)
    f = font(size)
    d.rectangle((0, 0, img.width, size + 10), fill=(10, 12, 18))
    d.text((8, 4), text, fill=(235, 236, 242), font=f)
    return img


def run(name: str, debug=False, only=None):
    spec = CLIPS[name]
    sc = Scene(spec['view'], spec['schedule'], spec['player_x'], spec['target_x'], scale=2.0,
               debug=debug, tail=spec['tail'])
    frames, marks = [], []
    t0 = time.time()
    for i in range(sc.length):
        sc.step()
        frames.append(sc.render() if only is None or i in only else None)
        cur = sc.player.current()
        marks.append(MOVES[cur[2]]['label'] if cur else '')
    for c in sc.contacts:
        c['contact'] = [float(v) for v in c['contact']]
    print(f'{name}: {len(frames)} ticks in {time.time() - t0:.1f}s, contacts={sc.contacts}')
    return sc, frames, marks


def _ffmpeg() -> str:
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


def encode(images: list[Image.Image], in_fps: int, gif: Path | None, mp4: Path | None,
           gif_fps: int | None = None, gif_scale: float = 1.0):
    """Palette-optimised GIF (ffmpeg palettegen/paletteuse) plus an H.264 MP4."""
    import subprocess
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        for i, im in enumerate(images):
            im.convert('RGB').save(Path(tmp) / f'{i:04d}.png', compress_level=1)
        src = ['-framerate', str(in_fps), '-i', str(Path(tmp) / '%04d.png')]
        if mp4 is not None:
            subprocess.run([_ffmpeg(), '-y', '-loglevel', 'error', *src, '-c:v', 'libx264', '-crf', '17',
                            '-preset', 'slow', '-pix_fmt', 'yuv420p', str(mp4)], check=True)
        if gif is not None:
            fps = gif_fps or in_fps
            scale = '' if gif_scale == 1.0 else f'scale=iw*{gif_scale}:-1:flags=lanczos,'
            vf = (f'fps={fps},{scale}split[a][b];[a]palettegen=max_colors=220:stats_mode=diff[p];'
                  f'[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle')
            subprocess.run([_ffmpeg(), '-y', '-loglevel', 'error', *src, '-vf', vf, '-loop', '0', str(gif)],
                           check=True)


def export(name: str, sc: Scene, frames: list[np.ndarray], marks: list[str]):
    spec = CLIPS[name]
    OUT.mkdir(parents=True, exist_ok=True)
    full = [Image.fromarray(f) for f in frames]
    game = [im.resize((im.width // 2, im.height // 2), Image.Resampling.LANCZOS) for im in full]
    # 1x game scale in real time: 60 fps MP4, 30 fps GIF.
    tagged = [label(im, f'V5 预览 · 游戏 1:1 · 实时   {marks[i]}', 14) for i, im in enumerate(game)]
    encode(tagged, 60, OUT / f'{name}_realtime.gif', OUT / f'{name}_realtime_60fps.mp4', gif_fps=30)
    # 2x zoom crop played at 24 fps (= 0.4x slow motion) for judging detail.
    zx, zy, zw, zh = spec['zoom']
    vx, vy = spec['view'][:2]
    box = ((zx - vx) * 2, (zy - vy) * 2, (zx - vx + zw) * 2, (zy - vy + zh) * 2)
    zoom = [label(im.crop(box), f'V5 预览 · 2 倍放大 · 0.4 倍慢放   {marks[i]}', 18) for i, im in enumerate(full)]
    encode(zoom, 24, OUT / f'{name}_zoom_slow.gif', OUT / f'{name}_zoom_slow.mp4', gif_scale=0.75)
    (OUT / f'{name}_contacts.json').write_text(json.dumps(sc.contacts, ensure_ascii=False, indent=2), encoding='utf-8')
    return full, game


def keyframes(name: str, full: list[Image.Image], sc: Scene, picks: list[tuple[int, str]]):
    spec = CLIPS[name]
    OUT.mkdir(parents=True, exist_ok=True)
    zx, zy, zw, zh = spec['zoom']
    vx, vy = spec['view'][:2]
    box = ((zx - vx) * 2, (zy - vy) * 2, (zx - vx + zw) * 2, (zy - vy + zh) * 2)
    tiles = [label(full[i].crop(box), t, 18) for i, t in picks]
    cols = 4
    rows = (len(tiles) + cols - 1) // cols
    w, h = tiles[0].size
    sheet = Image.new('RGB', (w * cols, h * rows), (12, 14, 20))
    for k, t in enumerate(tiles):
        sheet.paste(t, ((k % cols) * w, (k // cols) * h))
    sheet = sheet.resize((sheet.width // 2 * 1, sheet.height // 2 * 1), Image.Resampling.LANCZOS) if sheet.width > 3000 else sheet
    sheet.save(OUT / f'{name}_keyframes.png')
    return sheet


def pick_frames(sc: Scene, marks: list[str]):
    picks = []
    hits = [c['tick'] for c in sc.contacts]
    # Real ticks are 1-based in step(); frame index = tick - 1 after the step that rendered it.
    seen = []
    for i, m in enumerate(marks):
        if m and m not in seen:
            seen.append(m)
            picks.append((i + 3, f'{m} · 起手'))
    for c in sc.contacts:
        h, hs = c['tick'], MOVES[c['move']]['hit']['hitstop']
        picks += [(h - 2, '出刀'), (h, '命中帧（停帧）'), (h + hs // 2 + 1, '停帧中'), (h + hs + 3, '停帧结束'),
                  (h + hs + 10, '命中后')]
    picks = sorted({i: t for i, t in picks if 0 <= i < len(marks)}.items())
    return picks[:20]


def palette_sheet():
    """Same frames rendered with each slash palette, for the colour decision."""
    picks = [(27, '一段横斩'), (88, '三段竖劈')]
    options = [('steel', '银白（基础普攻·默认）'), ('crimson', '血红（狂战士系）'), ('azure', '青蓝（剑魂系）')]
    spec = CLIPS['combo']
    zx, zy, zw, zh = spec['zoom']
    vx, vy = spec['view'][:2]
    box = ((zx - vx) * 2, (zy - vy) * 2, (zx - vx + zw) * 2, (zy - vy + zh) * 2)
    tiles = []
    for pal, title in options:
        saved = {n: MOVES[n]['trail']['palette'] for n in ('attack1', 'attack2', 'attack3')}
        for n in saved:
            MOVES[n]['trail']['palette'] = pal
        _, frames, _ = run('combo', only={i for i, _ in picks})
        for n, v in saved.items():
            MOVES[n]['trail']['palette'] = v
        for i, what in picks:
            tiles.append(label(Image.fromarray(frames[i]).crop(box).resize((zw, zh), Image.Resampling.LANCZOS),
                               f'{title} · {what}', 14))
    w, h = tiles[0].size
    sheet = Image.new('RGB', (w * len(picks), h * len(options)), (12, 14, 20))
    for k, t in enumerate(tiles):
        sheet.paste(t, ((k % len(picks)) * w, (k // len(picks)) * h))
    OUT.mkdir(parents=True, exist_ok=True)
    sheet.save(OUT / 'slash_palette_options.png')


def compare_sheet():
    """V4 showcase frames (top) vs V5 preview frames (bottom), same 1x game scale."""
    import subprocess
    import tempfile
    v4 = ROOT / 'docs' / 'previews' / 'combat_v4_showcase.mp4'
    # Frame n of the V4 showcase resampled at 20 fps from t=3 s.
    v4_times = [(12, 'V4 · 一段：竖向月牙 + 整体白剪影', (480, 280)),
                (81, 'V4 · 二段：仍是竖向刀光', (400, 280)),
                (142, 'V4 · 受击：白剪影，与刀位无关', (400, 280))]
    v5_picks = [(24, 'V5 · 一段右横斩：横向刀光贴合刀身'), (53, 'V5 · 二段反手横斩：反向斜横'),
                (86, 'V5 · 三段竖劈：落点斩痕 + 地裂')]
    W, H = 500, 300
    tiles = []
    with tempfile.TemporaryDirectory() as tmp:
        for k, (n, title, (cx, cy)) in enumerate(v4_times):
            out = Path(tmp) / f'v4_{k}.png'
            subprocess.run([_ffmpeg(), '-y', '-loglevel', 'error', '-ss', '3', '-t', '12', '-i', str(v4),
                            '-vf', f'fps=20,select=eq(n\\,{n})', '-frames:v', '1', str(out)], check=True)
            tiles.append(label(Image.open(out).convert('RGB').crop((cx, cy, cx + W, cy + H)), title, 14))
    _, frames, _ = run('combo', only={i for i, _ in v5_picks})
    vx, vy = CLIPS['combo']['view'][:2]
    for i, title in v5_picks:
        im = Image.fromarray(frames[i])
        im = im.resize((im.width // 2, im.height // 2), Image.Resampling.LANCZOS)
        x0, y0 = 330 - vx, 296 - vy
        tiles.append(label(im.crop((x0, y0, x0 + W, y0 + H)), title, 14))
    sheet = Image.new('RGB', (W * 3, H * 2), (12, 14, 20))
    for k, t in enumerate(tiles):
        sheet.paste(t, ((k % 3) * W, (k // 3) * H))
    OUT.mkdir(parents=True, exist_ok=True)
    sheet.save(OUT / 'compare_v4_v5.png')


def alignment_sheet():
    """Debug overlay at each contact frame: blade samples (yellow), contact (magenta), target bounds (red)."""
    tiles = []
    for name in CLIPS:
        sc, _, _ = run(name, only=set())
        ticks = [c['tick'] for c in sc.contacts]
        sc, frames, _ = run(name, debug=True, only=set(ticks))
        spec = CLIPS[name]
        zx, zy, zw, zh = spec['zoom']
        vx, vy = spec['view'][:2]
        box = ((zx - vx) * 2, (zy - vy) * 2, (zx - vx + zw) * 2, (zy - vy + zh) * 2)
        for c in sc.contacts:
            tiles.append(label(Image.fromarray(frames[c['tick']]).crop(box).resize((zw, zh), Image.Resampling.LANCZOS),
                               f"{MOVES[c['move']]['label']} 命中帧 · 接触点 ({c['contact'][0]:.0f},{c['contact'][1]:.0f})", 13))
    cols = 2
    w, h = tiles[0].size
    sheet = Image.new('RGB', (w * cols, h * ((len(tiles) + cols - 1) // cols)), (12, 14, 20))
    for k, t in enumerate(tiles):
        sheet.paste(t, ((k % cols) * w, (k // cols) * h))
    OUT.mkdir(parents=True, exist_ok=True)
    sheet.save(OUT / 'hit_alignment_debug.png')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--clip', choices=list(CLIPS), action='append')
    ap.add_argument('--debug', action='store_true')
    ap.add_argument('--keyframes', action='store_true', help='only render key stills')
    ap.add_argument('--publish', action='store_true')
    ap.add_argument('--strip', help='start:end:step real-tick range rendered as a zoom contact sheet')
    ap.add_argument('--palettes', action='store_true', help='render the slash palette options sheet')
    ap.add_argument('--align', action='store_true', help='render the hit-point alignment debug sheet')
    ap.add_argument('--compare', action='store_true', help='V4 showcase vs V5 preview comparison sheet')
    args = ap.parse_args()
    names = args.clip or list(CLIPS)
    if args.palettes:
        palette_sheet()
        return
    if args.align:
        alignment_sheet()
        return
    if args.compare:
        compare_sheet()
        return
    if args.strip:
        a, b, s = (int(v) for v in args.strip.split(':'))
        for name in names:
            idx = list(range(a, b, s))
            sc, frames, marks = run(name, debug=args.debug, only=set(idx))
            full = [Image.fromarray(f) if f is not None else None for f in frames]
            keyframes(name, full, sc, [(i, f'tick {i}  {marks[i]}') for i in idx if i < len(full)])
            (OUT / f'{name}_keyframes.png').replace(OUT / f'{name}_strip_{a}_{b}.png')
            if len(idx) <= 3:
                spec = CLIPS[name]
                zx, zy, zw, zh = spec['zoom']
                vx, vy = spec['view'][:2]
                for i in idx:
                    full[i].crop(((zx - vx) * 2, (zy - vy) * 2, (zx - vx + zw) * 2, (zy - vy + zh) * 2)).save(
                        OUT / f'{name}_tick{i}.png')
        return
    for name in names:
        if args.keyframes:
            sc, _, marks = run(name, debug=args.debug, only=set())
            picks = pick_frames(sc, marks)
            sc, frames, marks = run(name, debug=args.debug, only={i for i, _ in picks})
        else:
            sc, frames, marks = run(name, debug=args.debug)
            export(name, sc, frames, marks)
            picks = pick_frames(sc, marks)
        full = [Image.fromarray(f) if f is not None else None for f in frames]
        keyframes(name, full, sc, picks)
    if args.publish:
        PUBLISH.mkdir(parents=True, exist_ok=True)
        keep = [f'{n}_{k}' for n in CLIPS for k in ('realtime.gif', 'realtime_60fps.mp4', 'zoom_slow.gif',
                                                   'zoom_slow.mp4', 'keyframes.png', 'contacts.json')]
        keep += ['slash_palette_options.png', 'hit_alignment_debug.png', 'compare_v4_v5.png']
        for name in keep:
            if (OUT / name).exists():
                shutil.copy2(OUT / name, PUBLISH / name)
        print('published ->', PUBLISH)


if __name__ == '__main__':
    main()
