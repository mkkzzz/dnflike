"""Independent native byte fixtures plus optional exact-client integration."""
import os
from pathlib import Path
import struct
import unittest

from audit_dnf_native_strings import ENGINE_SHA, MAX_BYTES, engine_image, recover_string, scan


class NativeStringsTest(unittest.TestCase):
    # Bytes copied from the verified PE, not made by an inverse of this decoder.
    EXPERT = bytes.fromhex("00545a2a914c099a01f0284f4d2c707599e3d6f855190f1a8e34fe8759066290")
    WAVE = bytes.fromhex("00545d2abc4c309a10f0594fa52403672017b28f20e0")

    def test_real_word_fixture(self):
        self.assertEqual(recover_string(self.EXPERT, 0, 2), ("expertjob.etc", 28))

    def test_real_tail_fixture_and_offset(self):
        self.assertEqual(recover_string(b"padding"+self.WAVE, 7, 2), ("HADOUKEN", 18))

    def test_rejects_invalid_width_offset_header_and_length(self):
        for width, offset in [(0,0),(3,0),(2,-1),(2,len(self.WAVE)-3)]:
            with self.assertRaises(ValueError):recover_string(self.WAVE, offset, width)
        with self.assertRaises(ValueError):recover_string(b"bad!"+self.WAVE[4:], 0, 2)
        with self.assertRaises(ValueError):recover_string(self.WAVE[:-1], 0, 2)
        enormous = b"\0\x54"+struct.pack("<H", 0x2A54^(MAX_BYTES+1))
        with self.assertRaises(ValueError):recover_string(enormous, 0, 2)

    def test_rejects_corrupt_terminator_and_wrong_character_width(self):
        corrupt = self.WAVE[:-1]+bytes([self.WAVE[-1]^1])
        with self.assertRaises(ValueError):recover_string(corrupt, 0, 2)
        with self.assertRaises(ValueError):recover_string(self.WAVE, 0, 1)

    def test_unknown_executable_is_not_silently_accepted(self):
        with self.assertRaises(ValueError):engine_image(b"MZ"+b"\0"*100)

    def test_exact_original_client_if_present(self):
        path = Path(os.environ.get("DNF_CLIENT_EXE", "D:/纯60复古/情怀60复古/DNF.exe"))
        if not path.is_file():self.skipTest("User's original client is local-only")
        raw = path.read_bytes()
        doc = scan(raw)
        self.assertEqual(doc["source"]["engine_sha256"], ENGINE_SHA)
        entries = {e["text"]:e for e in doc["entries"]}
        self.assertEqual(entries["HADOUKEN"]["va"], "0x16f20b0")
        self.assertEqual(entries["CNSwordman::procAppend"]["va"], "0x16ef104")
        self.assertIn("sq_LoadSkillEffectAni", entries)
        self.assertEqual(doc["count"], 19869)
        self.assertEqual(path.read_bytes(), raw, "Read-only analysis changed the client")


if __name__ == "__main__":
    unittest.main()
