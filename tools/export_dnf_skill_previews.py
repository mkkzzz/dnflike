"""Decode original Neople skill videos into lossless, timed PNG atlases."""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
from pathlib import Path, PurePosixPath
from tempfile import TemporaryDirectory

from PIL import Image

MAGIC = b"Neople Video Fil"
BLOCK_SIZE = 1024
ATLAS_COLUMNS = 8
GAME = Path(__file__).resolve().parents[1] / "game_dnf"
SWORDMAN_PREVIEW_DIR = GAME / "assets_local" / "skill_previews_swordman_v1"


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
    if start != end:
        raise ValueError("Truncated AVI chunk")


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


def avi_hold_frame_indices(avi: bytes, frames: int) -> set[int]:
    packets = None
    index = None
    for tag, start, end in riff_chunks(avi, 12, len(avi)):
        if tag == b"LIST" and avi[start:start + 4] == b"movi":
            if packets is not None:
                raise ValueError("Multiple AVI movie lists cannot verify empty samples")
            packets = [
                (kind, payload - 8 - start, limit - payload)
                for kind, payload, limit in riff_chunks(avi, start + 4, end)
            ]
        elif tag == b"idx1":
            if index is not None or (end - start) % 16:
                raise ValueError("Invalid AVI sample index")
            index = [(kind, offset, size) for kind, _, offset, size
                     in struct.iter_unpack("<4sIII", avi[start:end])]

    # Only accept the source's single-stream layout with matching chunk and index
    # offsets. A general timestamp gap is not evidence of an empty sample.
    if packets is None or packets != index or len(packets) != frames:
        raise ValueError("AVI movie chunks and sample index disagree with the stream header")
    if any(kind not in (b"00dc", b"00db") for kind, _, _ in packets):
        raise ValueError("Empty AVI samples require one indexed video stream")
    holds = {frame for frame, (_, _, size) in enumerate(packets) if size == 0}
    if 0 in holds:
        raise ValueError("The first AVI sample has no previous image to hold")
    return holds


def frame_atlas(
    rgba: bytes, width: int, height: int, frames: int, hold_frames: set[int] | None = None
) -> Image.Image:
    hold_frames = hold_frames or set()
    frame_bytes = width * height * 4
    if len(rgba) != (frames - len(hold_frames)) * frame_bytes:
        raise ValueError("Decoded frame count differs from the nonempty AVI samples")
    columns = min(frames, ATLAS_COLUMNS)
    rows = (frames + columns - 1) // columns
    atlas = Image.new("RGBA", (columns * width, rows * height))
    start = 0
    for frame in range(frames):
        # The client skips uploading when its decoder has no new frame (0x11C9770).
        if frame not in hold_frames:
            image = Image.frombytes("RGBA", (width, height), rgba[start:start + frame_bytes])
            start += frame_bytes
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
    hold_frames = set()
    if len(result.stdout) != frames * width * height * 4:
        hold_frames = avi_hold_frame_indices(avi, frames)
    atlas = frame_atlas(result.stdout, width, height, frames, hold_frames)
    stem = relative.with_suffix("").as_posix().lower()
    filename = stem.replace("/", "_") + ".png"
    path = output / filename
    atlas.save(path)
    entry = {
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
    if hold_frames:
        entry["source_hold_frame_indices"] = sorted(hold_frames)
    return "skill/" + stem + ".skl", entry


def swordman_clips(video_root: Path, catalog_path: Path) -> list[PurePosixPath]:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    expected = {
        PurePosixPath(skill["path"]).with_suffix(".avi").as_posix().lower().removeprefix("skill/")
        for skill in catalog["skills"]
        if skill["path"].lower().startswith("skill/swordman/") and skill["path"].lower().endswith(".skl")
    }
    matches = {}
    for source in sorted((video_root / "Swordman").iterdir()):
        relative = PurePosixPath(source.relative_to(video_root).as_posix())
        key = relative.as_posix().lower()
        if key not in expected or not source.is_file():
            continue
        if key in matches:
            raise ValueError(f"Multiple original Swordman videos match {key}")
        matches[key] = relative
    if not matches:
        raise ValueError("No original Swordman videos match the tracked skill catalog")
    return list(matches.values())


def export_pack(video_root: Path, paths: list[PurePosixPath], output: Path) -> None:
    clips = dict(export_clip(video_root, clip, output) for clip in paths)
    manifest = {"schema": "dnf_skill_previews/1", "clips": clips}
    (output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video-root", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--clip", action="append", type=PurePosixPath)
    selection.add_argument("--swordman", action="store_true",
                           help="Generate the optional local pack from tracked Swordman skills")
    args = parser.parse_args()
    if args.swordman:
        output = args.output or SWORDMAN_PREVIEW_DIR
        if output.exists():
            parser.error(f"Optional pack target already exists: {output}")
        paths = swordman_clips(args.video_root, GAME / "data" / "skill_catalog.json")
        output.parent.mkdir(parents=True, exist_ok=True)
        with TemporaryDirectory(prefix=".skill-previews-", dir=output.parent) as work:
            staged = Path(work) / "pack"
            staged.mkdir()
            export_pack(args.video_root, paths, staged)
            staged.rename(output)
        print(f"Exported {len(paths)} original skill previews to {output}")
    else:
        if args.output is None:
            parser.error("--clip requires --output")
        args.output.mkdir(parents=True, exist_ok=True)
        export_pack(args.video_root, args.clip, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
