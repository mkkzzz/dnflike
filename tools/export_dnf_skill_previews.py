"""Decode original Neople skill videos into lossless, timed PNG atlases."""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
from pathlib import Path, PurePosixPath

from PIL import Image

MAGIC = b"Neople Video Fil"
BLOCK_SIZE = 1024
ATLAS_COLUMNS = 8


def decode_neople_video(data: bytes) -> bytes:
    """Reproduce the client reader at 0x11C9A00 and 0x11C9630."""
    if len(data) < 32 or data[:16] != MAGIC:
        raise ValueError("Expected a Neople Video File header")
    version, segments, logical_size, stored_size = struct.unpack_from("<4I", data, 16)
    if version != 1 or segments != 1:
        raise ValueError("Expected a version-1 video with one segment")
    if (not 12 <= logical_size <= stored_size or stored_size % BLOCK_SIZE
            or len(data) != 32 + stored_size):
        raise ValueError("Invalid Neople video segment length")

    decoded = bytearray(data[32:])
    for offset in range(BLOCK_SIZE, stored_size):
        decoded[offset] ^= decoded[offset - BLOCK_SIZE]
    if (decoded[:4] != b"RIFF" or decoded[8:12] != b"AVI "
            or struct.unpack_from("<I", decoded, 4)[0] + 8 != logical_size):
        raise ValueError("Decoded segment is not a complete RIFF AVI")
    return bytes(decoded[:logical_size])


def riff_chunks(data: bytes, start: int, end: int):
    while start + 8 <= end:
        tag, size = struct.unpack_from("<4sI", data, start)
        start += 8
        if start + size > end:
            raise ValueError("Truncated AVI chunk")
        yield tag, start, start + size
        start += size + size % 2


def avi_video_info(avi: bytes) -> tuple[int, int, int, int, int]:
    for tag, start, end in riff_chunks(avi, 12, len(avi)):
        if tag != b"LIST" or avi[start:start + 4] != b"hdrl":
            continue
        for child, start, end in riff_chunks(avi, start + 4, end):
            if child != b"LIST" or avi[start:start + 4] != b"strl":
                continue
            for field, start, end in riff_chunks(avi, start + 4, end):
                if field == b"strh" and end - start >= 56 and avi[start:start + 4] == b"vids":
                    scale, rate, _, frames = struct.unpack_from("<4I", avi, start + 20)
                    left, top, right, bottom = struct.unpack_from("<4h", avi, start + 48)
                    width, height = right - left, bottom - top
                    if min(width, height, frames, scale, rate) > 0:
                        return width, height, frames, scale, rate
    raise ValueError("Missing AVI video size, frame count or time base")


def frame_atlas(rgba: bytes, width: int, height: int, frames: int) -> Image.Image:
    frame_bytes = width * height * 4
    if len(rgba) != frames * frame_bytes:
        raise ValueError("Decoded frame count differs from AVI stream header")
    columns = min(frames, ATLAS_COLUMNS)
    rows = (frames + columns - 1) // columns
    atlas = Image.new("RGBA", (columns * width, rows * height))
    for frame in range(frames):
        start = frame * frame_bytes
        image = Image.frombytes("RGBA", (width, height), rgba[start:start + frame_bytes])
        atlas.paste(image, (frame % columns * width, frame // columns * height))
    return atlas


def export_clip(video_root: Path, relative: PurePosixPath, output: Path) -> tuple[str, dict]:
    import imageio_ffmpeg

    if relative.is_absolute() or ".." in relative.parts or relative.suffix.lower() != ".avi":
        raise ValueError(f"Expected a path relative to the original Video directory: {relative}")
    source = (video_root / relative).read_bytes()
    avi = decode_neople_video(source)
    width, height, frames, scale, rate = avi_video_info(avi)
    command = [
        imageio_ffmpeg.get_ffmpeg_exe(), "-nostdin", "-hide_banner", "-v", "error", "-xerror",
        "-f", "avi", "-i", "pipe:0", "-map", "0:v:0", "-fps_mode", "passthrough",
        "-f", "rawvideo", "-pix_fmt", "rgba", "pipe:1",
    ]
    result = subprocess.run(command, input=avi, capture_output=True, check=True)
    atlas = frame_atlas(result.stdout, width, height, frames)
    stem = relative.with_suffix("").as_posix().lower()
    filename = stem.replace("/", "_") + ".png"
    path = output / filename
    atlas.save(path)
    return "skill/" + stem + ".skl", {
        "source": "Video/" + relative.as_posix(),
        "source_sha256": hashlib.sha256(source).hexdigest(),
        "avi_sha256": hashlib.sha256(avi).hexdigest(),
        "image": filename,
        "image_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "size": [width, height],
        "frame_count": frames,
        "columns": atlas.width // width,
        "time_base": [scale, rate],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--clip", action="append", required=True, type=PurePosixPath)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    clips = dict(export_clip(args.video_root, clip, args.output) for clip in args.clip)
    manifest = {"schema": "dnf_skill_previews/1", "clips": clips}
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
