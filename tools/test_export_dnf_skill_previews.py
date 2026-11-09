import struct
import unittest

from export_dnf_skill_previews import avi_video_info, decode_neople_video, frame_atlas


def chunk(tag: bytes, contents: bytes) -> bytes:
    return tag + struct.pack("<I", len(contents)) + contents + bytes(len(contents) % 2)


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


if __name__ == "__main__":
    unittest.main()
