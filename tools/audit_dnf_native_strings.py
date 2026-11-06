"""Read-only string recovery for the exact user-supplied native client.

Implements the observed decoder at VA 0x01194610, called by 0x01194E70
and the char/wchar wrappers 0x01194FA0/0x01194FC0. Never executes the PE.
Only the verified embedded SHA and observed 00 54 headers are accepted.
Printable ASCII strings (including UTF-16 storage) are indexed; this is not
a complete text decoder, source-code recovery, or behaviour certification.
The output and optional disassembly aids stay in temp, not in the game.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import struct

from audit_dnf_client_code import embedded_resources, pe_inventory

ROOT = Path(__file__).resolve().parents[1]
ENGINE_SHA = "187ad34ab6bfff040d9b12bb145bdda0bba29f82aaa41183280b0ae42e914b84"
IMAGE_BASE = 0x400000
DECODER_VA = 0x1194610
MAX_BYTES = 8192


def recover_string(data: bytes, offset: int, width: int) -> tuple[str, int]:
    """Decode one observed header; validate bounds, terminator and text strictly.

    Header length and seed are from 0x1194F2D..0x1194F5E. Each full word
    updates the key using recovered plaintext; the tail uses a byte recurrence.
    This is Python translation of arithmetic, not emulation/execution of code.
    """
    if width not in (1, 2) or offset < 0 or offset+4 > len(data):
        raise ValueError("Invalid string span or unit width")
    if data[offset:offset+2] != b"\x00\x54":
        raise ValueError("Unverified native string header")
    tag = data[offset+1] & 0xFE
    units = struct.unpack_from("<H", data, offset+2)[0] ^ ((tag << 7) | tag)
    size = units * width
    if size < width*2 or size > MAX_BYTES or offset+4+size > len(data):
        raise ValueError("Native string length outside bounded payload")
    key = tag | 0x9A714CA0
    payload = memoryview(data)[offset+4:offset+4+size]
    out = bytearray()
    aligned = size//4*4
    for index in range(0, aligned, 4):
        word = struct.unpack_from("<I", payload, index)[0] ^ key
        out.extend(struct.pack("<I", word))
        key = (key*0x1003F+word) & 0xFFFFFFFF
    for byte in payload[aligned:]:
        plain = byte ^ (key & 0xFF)
        out.append(plain)
        key = (key*0x107+plain) & 0xFFFFFFFF
    text = out.decode("utf-16le" if width == 2 else "ascii", errors="strict")
    if not text.endswith("\0") or "\0" in text[:-1]:
        raise ValueError("Native string has no unique terminal NUL")
    text = text[:-1]
    if not all(32 <= ord(char) < 127 or char in "\r\n\t" for char in text):
        raise ValueError("Outside the deliberately limited ASCII text index")
    return text, size


def engine_image(raw: bytes) -> tuple[bytes, dict]:
    """Locate the checked resource payload without writing/executing either PE."""
    outer_sha = hashlib.sha256(raw).hexdigest()
    if outer_sha == ENGINE_SHA:
        return raw, {"input_sha256": outer_sha, "embedded": False}
    inventory = embedded_resources(raw)
    found = [r for r in inventory.get("embedded_pe_resources", []) if r["sha256"] == ENGINE_SHA]
    if len(found) != 1:
        raise ValueError("No uniquely verified native engine payload; do not apply decoder to another client")
    entry = found[0]
    body = raw[entry["offset"]:entry["offset"]+entry["bytes"]]
    return body, {"input_sha256": outer_sha, "embedded": True,
                  "resource": entry["resource"], "resource_offset": entry["offset"]}


def scan(raw: bytes) -> dict:
    engine, source = engine_image(raw)
    meta = pe_inventory(engine)
    # These exact file-backed regions contain original native rdata/data. The
    # wrapper's section flags mark them executable too; don't infer role by flags.
    regions = [s for s in meta["sections"] if s["rva"] in (0x114E000, 0x15CA000)]
    if len(regions) != 2:
        raise ValueError("Verified image region layout changed")
    entries = []
    for section in regions:
        start, size = section["offset"], section["bytes"]
        region = engine[start:start+size]
        for match in re.finditer(b"\x00\x54", region):
            local = match.start()
            for width in (1, 2):
                try:
                    text, byte_length = recover_string(region, local, width)
                except (ValueError, UnicodeError):
                    continue
                rva = section["rva"]+local
                entries.append({"offset": start+local, "rva": rva,
                                "va": hex(IMAGE_BASE+rva), "width": width,
                                "byte_length": byte_length, "text": text})
    return {"schema": "dnf_native_strings/1", "source": {**source, "engine_sha256": ENGINE_SHA},
            "decoder": {"body_va": hex(DECODER_VA), "header_va": "0x1194e70",
                        "char_va": "0x1194fa0", "wchar_va": "0x1194fc0"},
            "scope": "Observed header in two native regions; ASCII output only. Static text recovery, not full decompilation.",
            "count": len(entries), "width_counts": dict(Counter(e["width"] for e in entries)),
            "entries": entries}


def references(engine: bytes, address: int) -> list[dict]:
    """Raw original-code pointer candidates; instruction boundaries not asserted."""
    section = pe_inventory(engine)["sections"][0]
    start = section["offset"]
    code = engine[start:start+section["bytes"]]
    return [{"offset": start+m.start(), "va": hex(IMAGE_BASE+section["rva"]+m.start())}
            for m in re.finditer(re.escape(struct.pack("<I", address)), code)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client-exe", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=ROOT/"temp/skill_logic_audit/native_strings_verified.json")
    parser.add_argument("--query", action="append", default=[], help="Print matching recovered strings and code-pointer candidates")
    args = parser.parse_args()
    if args.output.resolve() == args.client_exe.resolve():
        raise ValueError("Output cannot replace the source executable")
    raw = args.client_exe.read_bytes()
    doc = scan(raw)
    if args.query:
        engine, _ = engine_image(raw)
        doc["matches"] = [{**entry, "pointer_candidates": references(engine, int(entry["va"], 16))}
                          for entry in doc["entries"] if any(q.lower() in entry["text"].lower() for q in args.query)]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(doc, ensure_ascii=False, indent=1)+"\n", encoding="utf8")
    print(json.dumps({"count": doc["count"], "width_counts": doc["width_counts"],
                      "output": str(args.output), "matches": doc.get("matches", [])}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
