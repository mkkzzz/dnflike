from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image


def validate(root: Path) -> dict:
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    assert all(manifest["technical_checks"].values()), "Packaging checks failed"
    assert not manifest["upscale"] and not manifest["native_2k"]
    rejected = manifest.get("status") == "scenes_rejected_stopped"
    if rejected:
        assert not manifest["rooms"], "Rejected rooms must not remain active"
        assert not list((root / "exports/rooms").glob("*.png")), "Rejected room files remain"
        assert not list((root / "previews").glob("*.png")), "Rejected scene previews remain"
        assert all(not list((root / "sources" / f"r{number:02}").glob("*.png")) for number in range(2, 6)), "Rejected room sources remain"
    state_count = shadow_count = 0
    for room_id, room in manifest["rooms"].items():
        with Image.open(root / room["file"]) as image:
            image.load()
            assert list(image.size) == room["size"], room_id
            x, y, w, h = room["walkable_rect"]
            assert 0 <= x and 0 <= y and x + w <= image.width and y + h <= image.height, room_id
            assert all(x <= p[0] <= x + w and y <= p[1] <= y + h for p in room["door_anchors"].values()), room_id
        if "source" in room:
            digest = hashlib.sha256((root / room["source"]).read_bytes()).hexdigest()
            assert digest == room["source_sha256"], room_id
    for name, entity in manifest["entities"].items():
        anchor = entity["anchor"]
        for state, entry in entity["states"].items():
            with Image.open(root / entry["file"]) as source:
                image = source.convert("RGBA")
                assert list(image.size) == entity["size"], (name, state)
                assert image.getchannel("A").getextrema() == (0, 255), (name, state)
                assert 0 <= anchor[0] < image.width and 0 <= anchor[1] < image.height, (name, state)
            state_count += 1
            shadow = entry.get("shadow", entity.get("shadow"))
            assert shadow is not None, (name, state)
            with Image.open(root / shadow["file"]) as source:
                image = source.convert("RGBA")
                assert list(image.size) == shadow["size"]
                minimum, maximum = image.getchannel("A").getextrema()
                assert minimum == 0 and maximum > 0, (name, state)
                assert 0 <= shadow["anchor"][0] < image.width and 0 <= shadow["anchor"][1] < image.height
            shadow_count += 1
    complete = not any(manifest["missing"].values())
    result = {
        "result": "SCENE_REJECTION_CLEANUP_OK" if rejected else "ASSET_PACKAGE_CHECK_OK",
        "scene_exports_usable": not rejected,
        "production_stopped": rejected,
        "rooms": len(manifest["rooms"]),
        "entity_types": len(manifest["entities"]),
        "static_states": state_count,
        "shadow_exports": shadow_count,
        "complete_environment_package": complete,
        "missing": manifest["missing"],
        "art_and_runtime_approved": False,
    }
    (root / "validation.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    print(json.dumps(validate(parser.parse_args().root.resolve()), ensure_ascii=False))
