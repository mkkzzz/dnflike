import json
import struct
import unittest
from pathlib import Path, PurePosixPath
from tempfile import TemporaryDirectory

from export_dnf_skill_previews import (
    avi_hold_frame_indices,
    avi_video_info,
    decode_neople_video,
    frame_atlas,
    swordman_clips,
)


def chunk(tag: bytes, contents: bytes) -> bytes:
    return tag + struct.pack("<I", len(contents)) + contents + bytes(len(contents) % 2)


def indexed_avi(samples: list[bytes], index_offset_delta: int = 0) -> bytes:
    movie = bytearray(b"movi")
    index = bytearray()
    for sample in samples:
        index += struct.pack("<4sIII", b"00dc", 0, len(movie) + index_offset_delta, len(sample))
        movie += chunk(b"00dc", sample)
    return chunk(b"RIFF", b"AVI " + chunk(b"LIST", movie) + chunk(b"idx1", index))


class SkillPreviewExport(unittest.TestCase):
    def test_neople_chain_uses_the_previous_decoded_block(self):
        riff = b"AVI " + chunk(b"JUNK", bytes(range(256)) * 8 + b"end")
        avi = b"RIFF" + struct.pack("<I", len(riff) - 1) + riff[:-1]
        padded = avi.ljust(3072, b"\0")
        encoded = padded[:1024] + bytes(
            padded[i] ^ padded[i - 1024] for i in range(1024, len(padded))
        )
        wrapped = b"Neople Video Fil" + struct.pack("<4I", 1, 1, len(avi), len(encoded)) + encoded

        self.assertEqual(decode_neople_video(wrapped), avi)
        with self.assertRaisesRegex(ValueError, "segment length"):
            decode_neople_video(wrapped[:-1])
        with self.assertRaisesRegex(ValueError, "complete RIFF"):
            decode_neople_video(wrapped[:32] + bytes(len(encoded)))

    def test_avi_stream_geometry_and_exact_fraction(self):
        header = bytearray(56)
        header[:4] = b"vids"
        struct.pack_into("<4I", header, 20, 1001, 30000, 0, 49)
        struct.pack_into("<4h", header, 48, 0, 0, 160, 90)
        streams = chunk(b"JUNK", b"odd") + chunk(b"LIST", b"strl" + chunk(b"strh", header))
        avi = chunk(b"RIFF", b"AVI " + chunk(b"LIST", b"hdrl" + streams))
        self.assertEqual(avi_video_info(avi), (160, 90, 49, 1001, 30000))

    def test_atlas_keeps_frame_order_and_alpha(self):
        rgba = bytes((17, 43, 69, 29)) * 8 + bytes((0, 200, 40, 255))
        atlas = frame_atlas(rgba, 1, 1, 9)
        self.assertEqual(atlas.size, (8, 2))
        self.assertEqual(atlas.getpixel((7, 0)), (17, 43, 69, 29))
        self.assertEqual(atlas.getpixel((0, 1)), (0, 200, 40, 255))
        self.assertEqual(atlas.getpixel((1, 1)), (0, 0, 0, 0))
        with self.assertRaisesRegex(ValueError, "frame count"):
            frame_atlas(rgba[:-1], 1, 1, 9)

    def test_indexed_empty_samples_hold_the_previous_decoded_frame(self):
        avi = indexed_avi([b"a", b"", b"", b"b"])
        holds = avi_hold_frame_indices(avi, 4)
        self.assertEqual(holds, {1, 2})
        first, second = (17, 43, 69, 29), (0, 200, 40, 255)
        atlas = frame_atlas(bytes(first + second), 1, 1, 4, holds)
        self.assertEqual(list(atlas.get_flattened_data()), [first, first, first, second])
        with self.assertRaisesRegex(ValueError, "frame count"):
            frame_atlas(bytes(first), 1, 1, 4, holds)

    def test_unverified_empty_samples_cannot_repair_frame_count(self):
        with self.assertRaisesRegex(ValueError, "sample index disagree"):
            avi_hold_frame_indices(indexed_avi([b"a", b"", b"b"], index_offset_delta=4), 3)
        with self.assertRaisesRegex(ValueError, "sample index disagree"):
            avi_hold_frame_indices(indexed_avi([b"a", b"", b"b"]), 4)
        with self.assertRaisesRegex(ValueError, "no previous image"):
            avi_hold_frame_indices(indexed_avi([b"", b"b"]), 2)

    def test_optional_swordman_pack_uses_tracked_skill_paths(self):
        with TemporaryDirectory() as workspace:
            root = Path(workspace)
            catalog = root / "catalog.json"
            catalog.write_text(json.dumps({"skills": [
                {"path": "skill/swordman/upperslash.skl"},
                {"path": "skill/swordman/no_original_video.skl"},
                {"path": "skill/fighter/guard.skl"},
            ]}), encoding="utf-8")
            video = root / "Video" / "Swordman"
            video.mkdir(parents=True)
            for filename in ("UpperSlash.AVI", "BloodBoom.avi", "Guard.avi"):
                (video / filename).touch()

            self.assertEqual(swordman_clips(video.parent, catalog), [PurePosixPath("Swordman/UpperSlash.AVI")])


if __name__ == "__main__":
    unittest.main()
